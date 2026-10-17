defmodule Apiary.Adapters.Connections do
  # An organisation's connections to the instance's adapters (`Apiary.Adapters.Connection`,
  # `ac_…`): how a connection is started, connected by the return the person brings back
  # from the adapter, found for the adapter's key at the server contract, marked listed,
  # and ended.
  #
  # Starting one is `Apiary.Adapters.connect/2`'s: an owner or an admin of the organisation
  # (`adapter.connect`) makes the pending connection, or takes the one pending, with a
  # new connect pass whose nonce and expiry it keeps (`start/3`), each pass expiring
  # strictly later than the one before it. Should that take the pass more than
  # `Apiary.Adapters.ConnectPass.validity/0` seconds ahead, where it can reach the adapter
  # more than that ahead of its clock, which the adapter refuses (`pass_expired`), the
  # press ends the pending connection (`replaced`) and starts a new one in its place,
  # whose pass is its first. The person comes back with a return
  # (`Apiary.Adapters.ReturnToken`), which `complete_return/4` checks, every check before
  # any change; a return that says the adapter linked makes the connection connected.
  # The adapter's first listing that names it is recorded as it is accepted
  # (`mark_listed/1`, `listed_at`). A connected connection takes no new pass: its pass,
  # the person who started it and the time it connected stay as they are. Until that first
  # listing, a new press of Install ends it (`replaced`) and starts a new connection in
  # its place, which needs a return under the new pass; once listed, a press is refused.
  #
  # At the server contract an adapter's key acts for an organisation only through a
  # connection of its adapter (`connection_for_key/3`), with its scope narrowed to that
  # organisation (`Apiary.Accounts.Scope.for_connection/2`).
  #
  # A connection ends for good: when the adapter says it is gone (`end_connection/2`),
  # when a press of Install replaces it (`start/3`), while connected and not yet listed,
  # or while pending when its next pass would expire too far ahead,
  # when the adapter is deleted (`end_for_adapter/2`, `Apiary.Adapters.delete_adapter/2`),
  # and when the organisation's purge starts (`end_for_organisation/1`,
  # `Apiary.Deletion`). While the organisation is marked for deletion, or out of use, its
  # connections are suspended instead, and come back with it. Each end ends the
  # connection's live collections in the same transaction
  # (`Apiary.Adapters.Collections.end_for_connections/2`), with the feed's `unlinked`
  # entry for each one linked to a workspace.
  #
  # The lock order: the adapter's row, then its connections.
  #
  #   * A deletion of the adapter (`Apiary.Adapters.delete_adapter/2`) holds its row
  #     `FOR NO KEY UPDATE`, then ends its connections.
  #   * A connect (`Apiary.Adapters.connect/2`) holds the adapter's row `FOR SHARE`, then
  #     takes its connection `FOR UPDATE`; one it replaces it ends as the other ends do;
  #     a connection it makes takes the adapter's row `FOR SHARE` again (the trigger
  #     `adapter_connections_adapter_check`) and `FOR KEY SHARE` (its reference), which
  #     it holds already, and nobody else sees it until it commits. It
  #     also takes the organisation's and the person's rows `FOR KEY SHARE` (its
  #     references); `Apiary.Access.authorize/3` locks neither, and only a deletion of
  #     either row, or a change of its key, waits on that lock or keeps it waiting.
  #   * The return (`complete_return/4`) holds the connection `FOR UPDATE`, and nothing
  #     else. `mark_listed/1` holds it `FOR UPDATE` inside the transaction of a listing's
  #     part, which goes on to hold the organisation's only workspace `FOR SHARE`, the
  #     collections the part names, then the adapter's feed counter
  #     (`Apiary.Adapters.Collections.post_listing/2`). An assign holds the connection
  #     `FOR SHARE`, then the workspace, the collections and the feed counter
  #     (`Apiary.Adapters.Collections.assign_collections/4`). An end (`end_connection/2`,
  #     `end_for_organisation/1`) holds the connection, or all of the organisation's,
  #     then its collections, then the adapter's feed counter.
  #
  # Once each change commits, the organisation hears of it on its topic
  # (`Apiary.Adapters.Collections.broadcast_connection/1`): a press of Install, the return
  # that connects, and each end.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Features, Organisations, PublicId, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{Collections, ConnectPass, Connection, ReturnToken}
  alias Apiary.Contract.Ed25519
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  @live_index "(organisation_id, adapter_id) WHERE ended_at IS NULL"

  ## Reads, for people

  @doc false
  # The connections of the scope's organisation that have not ended, by their adapter's
  # id, to a person who may read the instance's adapters there (`adapter.read`, members);
  # none to anyone else.
  @spec live_by_adapter(Scope.t()) :: %{Ecto.UUID.t() => Connection.t()}
  def live_by_adapter(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope
      ) do
    if Access.can?(scope, :"adapter.read", organisation) do
      from(c in Connection, where: c.organisation_id == ^organisation_id and is_nil(c.ended_at))
      |> Repo.all()
      |> Map.new(&{&1.adapter_id, &1})
    else
      %{}
    end
  end

  def live_by_adapter(%Scope{}), do: %{}

  @doc false
  # The scope's organisation's connection to `adapter` that ended last, to a person who may
  # read the instance's adapters there (`adapter.read`); nil for none, or anyone else.
  @spec latest_ended(Scope.t(), Node.t()) :: Connection.t() | nil
  def latest_ended(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
        %Node{kind: :adapter, id: adapter_id}
      ) do
    if Access.can?(scope, :"adapter.read", organisation) do
      Repo.one(
        from c in Connection,
          where: c.organisation_id == ^organisation_id and c.adapter_id == ^adapter_id,
          where: not is_nil(c.ended_at),
          order_by: [desc: c.ended_at, desc: c.id],
          limit: 1
      )
    end
  end

  def latest_ended(%Scope{}, %Node{}), do: nil

  @doc false
  # The connection whose public id is `public_id`, of an adapter in use, with its
  # organisation and its adapter, and the person's scope in that organisation, for a
  # person who reaches it (`Apiary.Organisations.resolve_scope/4`) and may read the
  # instance's adapters there (`adapter.read`): `{:ok, connection, scope}`. `:error` for
  # anything else, one answer for all, so the id does not tell whether it exists.
  @spec locate(Scope.t() | nil, term) :: {:ok, Connection.t(), Scope.t()} | :error
  def locate(%Scope{user: %User{}} = scope, public_id) do
    with true <- Connection.public_id?(public_id),
         %Connection{} = connection <-
           Repo.one(
             from c in Connection,
               join: a in assoc(c, :adapter),
               where: c.public_id == ^public_id,
               where: a.kind == :adapter and is_nil(a.deleted_at),
               preload: [:organisation, adapter: a]
           ),
         {:ok, scope} <- Organisations.resolve_scope(scope, connection.organisation.slug),
         true <- Access.can?(scope, :"adapter.read", scope.organisation) do
      {:ok, connection, scope}
    else
      _ -> :error
    end
  end

  def locate(_scope, _public_id), do: :error

  ## Starting one

  @doc false
  # Inside `Apiary.Adapters.connect/2`'s transaction, which asked `adapter.connect` and
  # holds `adapter`'s row `FOR SHARE`: the pending connection of the scope's organisation
  # to `adapter`, made, or the one pending taken, `FOR UPDATE`, with a new connect pass
  # for it (`Apiary.Adapters.ConnectPass.issue/3`), made under that lock, now with
  # `nonce` as the nonce of its latest pass, unused, the pass's expiry as
  # `pass_expires_at`, and the scope's person as the one who started it. One connected
  # (`complete_return/4`), which no listing has named yet (`mark_listed/1`), is ended
  # (`replaced`), as `end_connection/2` ends one, with its pass, its person and the time
  # it connected as they were, and a new pending connection is made in its place, with a
  # new public id, as above. One pending is replaced so too when its next pass would
  # expire too far ahead, below.
  # `{:ok, connection, pass}`;
  # `{:error, :connected}` while the organisation is connected to it and a listing named
  # the connection, which changes nothing; `{:error, :invalid | :too_long}` when the pass
  # cannot be made, which the caller's transaction rolls back.
  #
  # The pass expires `Apiary.Adapters.ConnectPass.validity/0` seconds after now, to the
  # second, which is strictly later than the pass the connection had before, so long as
  # one second after that pass's expiry is no later than that time: read, and the new
  # time written with the new nonce in the same update, under the connection's row held
  # `FOR UPDATE`, so two presses never read the same previous time. When it is later
  # (`Apiary.Adapters.ConnectPass.beyond_validity?/2`), as for two presses in the same
  # second, or after the clock stepped back, a pass that expires after the previous one
  # would expire more than `validity/0` seconds ahead, and could reach the adapter more
  # than that ahead of its clock, which the adapter refuses (`pass_expired`): the
  # pending connection is ended (`replaced`) instead, in the same transaction and under
  # the same lock, with its nonce, its pass's expiry and its person as they were, and a
  # new pending connection is made in its place, as for one connected. A return under
  # the ended one's pass is not found after, and the adapter's key finds it ended. A new
  # connection, the first press's or one made in place of a replaced one, has no previous
  # pass, nor has one made before its pass's expiry was kept: its pass expires
  # `validity/0` seconds after now. So each new pass of a connection expires strictly
  # later than the one before it, and no pass expires more than `validity/0` seconds after
  # now. `opts[:now]`, the current time unless given, is for tests only.
  #
  # Two at once make one live connection: the second's insert waits for the first's and
  # does nothing, and it then takes the first's row, with the new nonce in it, or, in the
  # same second, replaces it with a new one, as above. Should the live
  # row its lock waited on end meanwhile (replaced by another press, or ended by the
  # adapter), the lock finds no live row, and it tries again: its insert now makes a
  # connection, or finds the one that replaced it. Each try after the first follows a
  # commit of another transaction that ended the live row.
  @spec start(Scope.t(), Node.t(), <<_::128>>, keyword) ::
          {:ok, Connection.t(), String.t()} | {:error, :connected | :invalid | :too_long}
  def start(
        %Scope{user: %User{id: user_id}, organisation: %Organisation{id: organisation_id}},
        %Node{kind: :adapter} = adapter,
        <<_::128>> = nonce,
        opts \\ []
      ) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    take_live(organisation_id, adapter, user_id, nonce, now)
  end

  defp take_live(organisation_id, %Node{id: adapter_id} = adapter, user_id, nonce, now) do
    {_count, _rows} =
      Repo.insert_all(
        Connection,
        [new_pending(organisation_id, adapter_id, user_id, nonce, now)],
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, @live_index}
      )

    case lock_live(organisation_id, adapter_id) do
      # The live row it waited on ended meanwhile.
      nil ->
        take_live(organisation_id, adapter, user_id, nonce, now)

      # Its pass is made here, under the row's lock: the previous pass's expiry is read and
      # the new one written in the same update. Should the new pass have to expire more
      # than `validity/0` seconds ahead to expire after the previous one, the connection
      # ends and a new one takes its place, whose pass is its first.
      %Connection{state: :pending} = pending ->
        not_before = after_previous(pending.pass_expires_at)

        if ConnectPass.beyond_validity?(now, not_before) do
          replace(pending, organisation_id, adapter, user_id, nonce, now)
        else
          with {:ok, pass, expires_at} <-
                 issue(adapter, pending.public_id, nonce, now, not_before),
               {:ok, connection} <-
                 pending
                 |> Ecto.Changeset.change(
                   pass_nonce: nonce,
                   pass_nonce_used_at: nil,
                   pass_expires_at: expires_at,
                   created_by_id: user_id,
                   updated_at: now
                 )
                 |> Repo.update() do
            {:ok, connection, pass}
          end
        end

      # Connected, and no listing has named it: it takes no new pass, so it ends, and a new
      # one takes its place, whose pass is its first.
      %Connection{state: :connected, listed_at: nil} = unlisted ->
        replace(unlisted, organisation_id, adapter, user_id, nonce, now)

      %Connection{state: :connected} ->
        {:error, :connected}
    end
  end

  # Ends `live`, held `FOR UPDATE`, as `replaced`, with its nonce, its pass's expiry, the
  # person who started it and the time it connected as they are; then makes a new pending
  # connection in its place, with a new public id, started by the person who pressed,
  # whose pass, with `nonce`, is its first and expires `validity/0` seconds after now.
  defp replace(live, organisation_id, %Node{id: adapter_id} = adapter, user_id, nonce, now) do
    fields = new_pending(organisation_id, adapter_id, user_id, nonce, now)

    with {:ok, pass, expires_at} <- issue(adapter, fields.public_id, nonce, now, nil),
         {:ok, _ended} <- end_live(live, :replaced, now),
         {:ok, connection} <-
           Connection
           |> struct!(%{fields | pass_expires_at: expires_at})
           |> Repo.insert() do
      {:ok, connection, pass}
    end
  end

  # One second after `previous`, the expiry of the connection's previous pass; `nil` for
  # none, a connection's first pass.
  defp after_previous(nil), do: nil
  defp after_previous(%DateTime{} = previous), do: DateTime.add(previous, 1, :second)

  # The connect pass of `adapter` for the connection `public_id`, made at `now`, and when
  # it expires (`Apiary.Adapters.ConnectPass.expires_at/2` of now and `not_before`), the
  # same time the pass says.
  defp issue(%Node{public_id: adapter_public_id}, public_id, nonce, now, not_before) do
    with {:ok, pass} <-
           ConnectPass.issue(adapter_public_id, public_id,
             nonce: nonce,
             now: now,
             not_before: not_before
           ) do
      {:ok, pass, ConnectPass.expires_at(now, not_before)}
    end
  end

  # A pending connection, as it is made. A connection made by the insert that does
  # nothing on a conflict has no pass expiry yet: its pass is made, and its expiry
  # written, once its row is locked.
  defp new_pending(organisation_id, adapter_id, user_id, nonce, now) do
    %{
      id: Ecto.UUID.generate(),
      public_id: PublicId.generate(Connection.prefix()),
      organisation_id: organisation_id,
      adapter_id: adapter_id,
      created_by_id: user_id,
      state: :pending,
      pass_nonce: nonce,
      pass_expires_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp lock_live(organisation_id, adapter_id) do
    Repo.one(
      from c in Connection,
        where: c.organisation_id == ^organisation_id and c.adapter_id == ^adapter_id,
        where: is_nil(c.ended_at),
        lock: "FOR UPDATE"
    )
  end

  ## The return

  @doc false
  # complete_return/4 takes the return `token` an adapter handed back on the link to the
  # connection `public_id` (`ac_…`), brought by the person of `scope` with
  # `session_nonce`, the nonce their session kept when they pressed Install
  # (`ApiaryWeb.ConnectSession`), in base64url. Every check is made before any change,
  # under the connection's row held `FOR UPDATE`, in this order:
  #
  #   1. the token is a return (`Apiary.Adapters.ReturnToken.verify/2`) signed under one
  #      of the access keys in use of the adapter of the connection the link names, an
  #      adapter in use;
  #   2. its `connection_id` is the link's;
  #   3. the connection is pending (it is the adapter's: its keys signed);
  #   4. its nonce is the connection's latest pass's;
  #   5. no return under that nonce came back yet;
  #   6. it has not expired (`Apiary.Adapters.ReturnToken.good_at?/2`);
  #   7. the person is the one who started the connection, in the browser they started it
  #      in: the session's nonce is the return's;
  #      Adapters rely on this check: an adapter cannot tell whose pass it holds, so a
  #      return brought through a browser the starter did not use must never connect.
  #   8. they may still connect an adapter to the connection's organisation
  #      (`adapter.connect`).
  #
  # Then a return that says `linked` makes the connection connected, now; `refused` and
  # `cancelled` change nothing but the nonce, which is used either way. `{:ok, :linked}`,
  # `{:ok, {:refused, reason}}`, `{:ok, :cancelled}`; `{:error, :wrong_person}` for 7;
  # `{:error, :not_found}` for every other refusal, one answer for a token that is bad,
  # expired or used.
  @spec complete_return(Scope.t() | nil, term, term, term) ::
          {:ok, :linked | :cancelled | {:refused, ReturnToken.reason()}}
          | {:error, :wrong_person | :not_found}
  def complete_return(%Scope{user: %User{}} = scope, public_id, token, session_nonce) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with true <- Connection.public_id?(public_id),
           %Connection{} = connection <- lock_by_public_id(public_id),
           %Node{} = adapter <- live_adapter(connection.adapter_id),
           {:ok, return} <- ReturnToken.verify(token, public_keys(adapter)),
           true <- return.connection_id == connection.public_id,
           true <- connection.state == :pending,
           true <- Plug.Crypto.secure_compare(return.nonce, connection.pass_nonce),
           true <- is_nil(connection.pass_nonce_used_at),
           true <- ReturnToken.good_at?(return, now),
           :ok <- same_person(scope, connection, session_nonce, return.nonce),
           :ok <- may_connect(scope, connection) do
        returned(connection, return, now)
      else
        {:error, :wrong_person} = wrong -> wrong
        _refused -> {:error, :not_found}
      end
    end)
    |> case do
      {:ok, {:linked, connected}} ->
        :ok = Collections.broadcast_connection(connected)
        {:ok, :linked}

      answer ->
        answer
    end
  end

  def complete_return(_scope, _public_id, _token, _session_nonce), do: {:error, :not_found}

  defp lock_by_public_id(public_id) do
    Repo.one(
      from c in Connection,
        where: c.public_id == ^public_id,
        lock: "FOR UPDATE",
        preload: :organisation
    )
  end

  defp live_adapter(adapter_id) do
    Repo.one(
      from n in Node,
        where: n.id == ^adapter_id and n.kind == :adapter and is_nil(n.deleted_at),
        where: is_nil(n.organisation_id) and is_nil(n.workspace_id)
    )
  end

  defp public_keys(adapter),
    do:
      for(
        %AccessKey{public_key: <<_::binary-size(32)>> = key} <- AccessKeys.active_keys(adapter),
        do: key
      )

  # The person is the one who started the connection, and their session kept the nonce of
  # the return, so they come back in the browser they started in.
  # Adapters rely on this check: an adapter cannot tell whose pass it holds, so a return
  # brought through a browser the starter did not use must never connect.
  defp same_person(
         %Scope{user: %User{id: user_id}},
         %Connection{created_by_id: user_id},
         session_nonce,
         nonce
       )
       when is_binary(user_id) do
    case Ed25519.decode(session_nonce, 16) do
      {:ok, kept} -> if Plug.Crypto.secure_compare(kept, nonce), do: :ok, else: wrong_person()
      :error -> wrong_person()
    end
  end

  defp same_person(_scope, _connection, _session_nonce, _nonce), do: wrong_person()

  defp wrong_person, do: {:error, :wrong_person}

  # The person may still connect an adapter to the connection's organisation: they reach
  # it, it is in use, and their level holds `adapter.connect` there.
  defp may_connect(scope, %Connection{organisation: %Organisation{} = organisation}) do
    with {:ok, scope} <- Organisations.put_reach(scope, organisation),
         :ok <- Access.authorize(scope, :"adapter.connect", organisation) do
      :ok
    else
      _ -> :error
    end
  end

  defp returned(connection, %{outcome: :linked}, now) do
    with {:ok, connected} <-
           connection
           |> Ecto.Changeset.change(
             state: :connected,
             connected_at: now,
             pass_nonce_used_at: now,
             updated_at: now
           )
           |> Repo.update(),
         do: {:ok, {:linked, connected}}
  end

  defp returned(connection, %{outcome: outcome, reason: reason}, now) do
    with {:ok, _used} <-
           connection
           |> Ecto.Changeset.change(pass_nonce_used_at: now, updated_at: now)
           |> Repo.update() do
      case outcome do
        :refused -> {:ok, {:refused, reason}}
        :cancelled -> {:ok, :cancelled}
      end
    end
  end

  ## At the server contract

  @doc false
  # connection_for_key/3 is the connection `public_id` (`ac_…`) for the adapter's key of
  # `key_scope` (`Apiary.Accounts.Scope.for_access_key/1`), to take `action` for its
  # organisation, with the key's scope narrowed to that organisation
  # (`Apiary.Accounts.Scope.for_connection/2`), in this order:
  #
  #   * `{:error, :forbidden}` for a request outside the key's rights: a scope of no
  #     adapter's key, where the feature is off, and an action the key's role does not
  #     take on its adapter. It is decided from the key and `action` alone, before any
  #     connection is looked up, so it is the same answer whatever `public_id` names: a
  #     key whose rights do not hold `action` cannot tell an id that names a connection
  #     from one that names none;
  #   * `{:error, :unknown}` (`connection_unknown` in the contract) for a connection the
  #     core does not hold for the key's adapter: an id that names no connection, a
  #     connection of another adapter, and one pending (no linked return has connected
  #     it yet, `complete_return/4`): one answer for all;
  #   * `{:error, :ended}` for one of the adapter that ended, connected before or not, and
  #     for nothing else: no narrowed scope is made for it, and its organisation is not
  #     asked about;
  #   * `{:error, :suspended}` while its organisation is out of use: marked for deletion
  #     or held out of use (`Apiary.AccessKeys.organisation_in_use?/1`), or refused by
  #     the edition, which `Apiary.Access.check/3` asks on the narrowed scope of `action`
  #     on the organisation;
  #   * `{:ok, connection, scope}`, the connection with its organisation, and the narrowed
  #     scope.
  @spec connection_for_key(Scope.t() | nil, term, Access.action()) ::
          {:ok, Connection.t(), Scope.t()}
          | {:error, :forbidden | :unknown | :ended | :suspended}
  def connection_for_key(key_scope, public_id, action) do
    with {:ok, adapter_id} <- key_adapter(key_scope),
         :ok <- key_may(key_scope, action),
         {:ok, connection} <- key_connection(adapter_id, public_id, :find),
         :ok <- not_ended(connection),
         {:ok, scope} <- in_use(key_scope, connection, action) do
      {:ok, connection, scope}
    end
  end

  # The id of the adapter whose key `key_scope` carries, where the feature is on:
  # `{:ok, adapter_id}`. `{:error, :forbidden}` for a scope of no adapter's key, and where
  # the feature is off. It looks up no connection.
  defp key_adapter(%Scope{
         access_key: %AccessKey{
           node_id: adapter_id,
           organisation_id: nil,
           workspace_id: nil,
           node: %Node{kind: :adapter, organisation_id: nil, workspace_id: nil}
         }
       })
       when is_binary(adapter_id) do
    if Features.on?(:factory), do: {:ok, adapter_id}, else: {:error, :forbidden}
  end

  defp key_adapter(_scope), do: {:error, :forbidden}

  @doc false
  # key_rights/2 is the first check of every request of an adapter's key, from the key and
  # `action` alone, before any connection or collection is looked up: `{:ok, adapter_id}`,
  # the id of the key's adapter, when the key's role takes `action` on it where the
  # feature is on; `{:error, :forbidden}` otherwise, as `connection_for_key/3` decides it.
  @spec key_rights(Scope.t() | nil, Access.action()) ::
          {:ok, Ecto.UUID.t()} | {:error, :forbidden}
  def key_rights(key_scope, action) do
    with {:ok, adapter_id} <- key_adapter(key_scope),
         :ok <- key_may(key_scope, action),
         do: {:ok, adapter_id}
  end

  @doc false
  # in_use/3 is the key's scope narrowed to the organisation of `connection` (preloaded),
  # once `key_rights/2` let `action`: `{:ok, scope}` while the organisation is in use;
  # `{:error, :suspended}` while it is out of use, as `connection_for_key/3` decides it.
  @spec in_use(Scope.t(), Connection.t(), Access.action()) ::
          {:ok, Scope.t()} | {:error, :suspended}
  def in_use(key_scope, %Connection{} = connection, action) do
    scope = Scope.for_connection(key_scope, connection)

    with :ok <- organisation_in_use(scope, connection, action), do: {:ok, scope}
  end

  # The connection `public_id` of the adapter `adapter_id`, with its organisation: for
  # `:find`, one that is not pending (connected, or ended from either state, which
  # `connection_for_key/3` answers `{:error, :ended}`); for `:end`, one in any state, held
  # `FOR UPDATE`. `{:error, :unknown}` for anything else: an id that names no connection,
  # a connection of another adapter, and, for `:find`, one pending.
  defp key_connection(adapter_id, public_id, mode) do
    with true <- Connection.public_id?(public_id),
         %Connection{} = connection <- Repo.one(key_query(public_id, adapter_id, mode)) do
      {:ok, connection}
    else
      _ -> {:error, :unknown}
    end
  end

  defp key_query(public_id, adapter_id, mode) do
    query =
      from c in Connection,
        where: c.public_id == ^public_id and c.adapter_id == ^adapter_id,
        preload: :organisation

    case mode do
      :find -> where(query, [c], c.state != :pending)
      :end -> lock(query, "FOR UPDATE")
    end
  end

  # The key's role holds `action` on its adapter (`Apiary.Access.check/3`, asked of the
  # adapter as `Apiary.Adapters.for_key/2` asks it), from the key and `action` alone,
  # before any connection is looked up. The key's scope carries no organisation here, so
  # an edition's refusal for the organisation shows only in `in_use/3`, after the
  # connection is found. Rights therefore stay first: a disconnect of a connection, which
  # never asks `in_use/3`, is not refused while its organisation is out of use.
  defp key_may(%Scope{access_key: %AccessKey{node: %Node{} = adapter}} = key_scope, action) do
    case Access.check(key_scope, action, adapter) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp not_ended(%Connection{state: :ended}), do: {:error, :ended}
  defp not_ended(%Connection{}), do: :ok

  # The organisation is in use, as the core holds it and as the edition answers for it.
  # The narrowed scope is the key's at its organisation, whose role holds `action` there,
  # so a refusal can only be the organisation's state, which the edition holds.
  defp organisation_in_use(scope, %Connection{organisation: organisation} = connection, action) do
    if AccessKeys.organisation_in_use?(connection.organisation_id) and
         Access.check(scope, action, organisation) == :ok,
       do: :ok,
       else: {:error, :suspended}
  end

  @doc false
  # mark_listed/1 records the adapter's first listing that names `connection`, connected,
  # once `connection_for_key/3` found it: `listed_at`, now. From then on a press of
  # Install is refused (`start/3`). One listed already stays as it is. `{:ok, connection}`;
  # `{:error, :ended}` for one that ended meanwhile; `{:error, :unknown}` for one pending
  # or not there, as `connection_for_key/3` answers for them (`connection_unknown` in the
  # contract: a listing of a pending connection is refused so).
  @spec mark_listed(Connection.t()) ::
          {:ok, Connection.t()} | {:error, :ended | :unknown}
  def mark_listed(%Connection{id: id}) do
    Repo.transact(fn ->
      case Repo.one(from c in Connection, where: c.id == ^id, lock: "FOR UPDATE") do
        %Connection{state: :connected, listed_at: nil} = unlisted ->
          now = DateTime.utc_now()

          unlisted
          |> Ecto.Changeset.change(listed_at: now, updated_at: now)
          |> Repo.update()

        %Connection{state: :connected} = listed ->
          {:ok, listed}

        %Connection{state: :ended} ->
          {:error, :ended}

        _other ->
          {:error, :unknown}
      end
    end)
  end

  ## Ending

  @doc false
  # end_connection/2 ends the connection `public_id` (`ac_…`) of the adapter whose key
  # `key_scope` carries, pending or connected, as the adapter reports it gone
  # (`adapter_reported`), whatever its organisation's state, in one transaction. A
  # return for a pending one it ended is not found after (`complete_return/4`). The
  # answers, in this order:
  #
  #   * `{:error, :forbidden}` for a request outside the key's rights: a scope of no
  #     adapter's key, where the feature is off, and a key whose role does not take
  #     `adapter.disconnect` on its adapter. It is decided from the key and that action
  #     alone, before any connection is looked up, so it is the same answer whatever
  #     `public_id` names, as `connection_for_key/3` decides it;
  #   * `{:error, :unknown}` (`connection_unknown` in the contract) for an id that names
  #     no connection, and a connection of another adapter: one answer for both;
  #   * `{:error, :ended}` for one ended already, connected before or not;
  #   * `{:ok, connection}`, ended, for one pending or connected.
  @spec end_connection(Scope.t() | nil, term) ::
          {:ok, Connection.t()} | {:error, :forbidden | :unknown | :ended}
  def end_connection(key_scope, public_id) do
    Repo.transact(fn ->
      with {:ok, adapter_id} <- key_adapter(key_scope),
           :ok <- key_may(key_scope, :"adapter.disconnect"),
           {:ok, connection} <- key_connection(adapter_id, public_id, :end),
           :ok <- not_ended(connection) do
        end_live(connection, :adapter_reported, DateTime.utc_now())
      end
    end)
    |> tap(fn
      {:ok, ended} -> :ok = Collections.broadcast_connection(ended)
      _refused -> :ok
    end)
  end

  # Ends `connection`, held `FOR UPDATE` and live, for `reason`, and its collections with
  # it. `{:ok, connection}`, ended.
  defp end_live(%Connection{} = connection, reason, now) do
    with {:ok, ended} <-
           connection
           |> Ecto.Changeset.change(
             state: :ended,
             ended_at: now,
             ended_reason: reason,
             updated_at: now
           )
           |> Repo.update() do
      _count = Collections.end_for_connections([ended.id], now)
      {:ok, ended}
    end
  end

  @doc false
  # Inside `Apiary.Adapters.delete_adapter/2`'s transaction, which holds the adapter's row
  # `FOR NO KEY UPDATE`: ends every connection of `adapter` that has not ended
  # (`integration_deleted`), and their collections. The public ids of those ended, in
  # order. `broadcast_ended_with/1` tells their organisations once that commits.
  @spec end_for_adapter(Node.t(), DateTime.t()) :: [String.t()]
  def end_for_adapter(%Node{kind: :adapter, id: adapter_id}, %DateTime{} = now) do
    {_count, ended} =
      Repo.update_all(
        from(c in Connection,
          where: c.adapter_id == ^adapter_id and is_nil(c.ended_at),
          select: {c.id, c.public_id}
        ),
        set: [state: :ended, ended_at: now, ended_reason: :integration_deleted, updated_at: now]
      )

    _count = Collections.end_for_connections(Enum.map(ended, &elem(&1, 0)), now)
    ended |> Enum.map(&elem(&1, 1)) |> Enum.sort()
  end

  @doc false
  # After the deletion of `adapter` commits (`end_for_adapter/2`): tells the organisation
  # of each connection that ended with it (`integration_deleted`) that it changed. An
  # adapter is deleted once, so these are the ones its deletion ended.
  @spec broadcast_ended_with(Node.t()) :: :ok
  def broadcast_ended_with(%Node{kind: :adapter, id: adapter_id}) do
    from(c in Connection,
      where: c.adapter_id == ^adapter_id and c.ended_reason == :integration_deleted
    )
    |> Repo.all()
    |> Enum.each(&(:ok = Collections.broadcast_connection(&1)))
  end

  @doc false
  # end_for_organisation/1 ends every connection of the organisation `organisation_id`
  # that has not ended (`organisation_deleted`), and their collections, in one
  # transaction: once the organisation's purge has claimed it, and its deletion can no
  # longer be cancelled (`Apiary.Deletion`). The number of connections ended.
  @spec end_for_organisation(Ecto.UUID.t()) :: non_neg_integer
  def end_for_organisation(organisation_id) do
    now = DateTime.utc_now()

    {:ok, ended} =
      Repo.transact(fn ->
        {_count, ended} =
          Repo.update_all(
            from(c in Connection,
              where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
              select: c
            ),
            set: [
              state: :ended,
              ended_at: now,
              ended_reason: :organisation_deleted,
              updated_at: now
            ]
          )

        _collections = Collections.end_for_connections(Enum.map(ended, & &1.id), now)
        {:ok, ended}
      end)

    Enum.each(ended, &(:ok = Collections.broadcast_connection(&1)))
    length(ended)
  end
end
