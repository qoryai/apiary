defmodule Apiary.Adapters.Connections do
  # An organisation's connections to the instance's adapters (`Apiary.Adapters.Connection`,
  # `ac_…`): how a connection is started, activated by the return the person brings back
  # from the adapter, found for the adapter's key at the server contract, marked
  # connected, and ended.
  #
  # Starting one is `Apiary.Adapters.connect/2`'s: an owner or an admin of the organisation
  # (`adapter.connect`) makes the pending connection, or takes the one pending, with a
  # new connect pass whose nonce it keeps. The person comes back with a return
  # (`Apiary.Adapters.ReturnToken`), which `complete_return/4` checks, every check before
  # any change; a return that says the adapter linked activates the connection, which
  # stays pending until the adapter's first listing names it (`mark_connected/1`). An
  # activated connection takes no new pass: its pass, the person who started it and its
  # activation stay as they are. Until that first listing, a new press of Install ends it
  # (`replaced`) and starts a new connection in its place, which needs a return of its
  # own pass; once connected, a press is refused.
  #
  # At the server contract an adapter's key acts for an organisation only through a
  # connection of its adapter (`connection_for_key/3`), with its scope narrowed to that
  # organisation (`Apiary.Accounts.Scope.for_connection/2`).
  #
  # A connection ends for good: when the adapter says it is gone (`end_connection/2`),
  # when a press of Install replaces it while activated and not yet listed (`start/3`),
  # when the adapter is deleted (`end_for_adapter/2`, `Apiary.Adapters.delete_adapter/2`),
  # and when the organisation's purge starts (`end_for_organisation/1`,
  # `Apiary.Deletion`). While the organisation is marked for deletion, or out of use, its
  # connections are suspended instead, and come back with it. Every end clears the pools
  # of that organisation the adapter served.
  #
  # The lock order: the adapter's row, then its connections, then the pools.
  #
  #   * A deletion of the adapter (`Apiary.Adapters.delete_adapter/2`) holds its row
  #     `FOR NO KEY UPDATE`, ends its connections, then clears the pools.
  #   * A connect (`Apiary.Adapters.connect/2`) holds the adapter's row `FOR SHARE`, then
  #     takes its connection `FOR UPDATE`; one it replaces it ends as the other ends do,
  #     then clears the pools; a connection it makes takes the adapter's row `FOR SHARE`
  #     again (the trigger `adapter_connections_adapter_check`) and `FOR KEY SHARE` (its
  #     reference), which it holds already, and nobody else sees it until it commits.
  #   * A change of a pool (`Apiary.Nodes.update_node/3`) that names the adapter that
  #     serves it holds that connection `FOR SHARE` (`lock_serving/2`) before it locks the
  #     pool's row; a pool made with one (`Apiary.Nodes.create_node/2`) takes the
  #     connection `FOR SHARE` in the trigger `nodes_served_by_is_an_adapter` as it is
  #     inserted. Both take the locks of `Apiary.Gateways.lock/1` first, which none of
  #     the others here takes.
  #   * The return (`complete_return/4`) and `mark_connected/1` hold the connection
  #     `FOR UPDATE`, and nothing else. An end (`end_connection/2`,
  #     `end_for_organisation/1`) holds the connection, or all of the organisation's,
  #     then clears the pools.
  #
  # One lock goes against the order: as a pool is made or changed to name an adapter,
  # Postgres checks the reference `served_by_id`, which takes the adapter's row
  # `FOR KEY SHARE`, after the connection. So whatever holds the adapter's row while it
  # waits on a connection holds it in a mode that lets `FOR KEY SHARE` through: the
  # deletion's `FOR NO KEY UPDATE`. A change of the adapter's keys
  # (`Apiary.AccessKeys`) holds the row `FOR UPDATE`, which keeps that check waiting,
  # but it takes no connection and no pool, so it ends first. So no two of them wait on
  # each other.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Features, Organisations, PublicId, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{Connection, ReturnToken}
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
  # to `adapter`, made, or the one pending and not activated taken, `FOR UPDATE`, now with
  # `nonce` as the nonce of its latest pass, unused, and the scope's person as the one who
  # started it. One pending and activated (`complete_return/4`), which no listing has
  # named yet, is ended (`replaced`), as `end_connection/2` ends one, with its pass, its
  # person and its activation as they were, and a new pending connection is made in its
  # place, as above. `{:ok, connection}`, or `{:error, :connected}` while the organisation
  # is connected to it, which changes nothing.
  #
  # Two at once make one connection: the second's insert waits for the first's and does
  # nothing, and it then takes the first's row, with the new nonce in it. Should the live
  # row its lock waited on end meanwhile (replaced by another press, or ended by the
  # adapter), the lock finds no live row, and it tries again: its insert now makes a
  # connection, or finds the one that replaced it. Each try after the first follows a
  # commit of another transaction that ended the live row.
  @spec start(Scope.t(), Node.t(), <<_::128>>) ::
          {:ok, Connection.t()} | {:error, :connected}
  def start(
        %Scope{user: %User{id: user_id}, organisation: %Organisation{id: organisation_id}},
        %Node{kind: :adapter, id: adapter_id},
        <<_::128>> = nonce
      ) do
    take_live(organisation_id, adapter_id, user_id, nonce, DateTime.utc_now())
  end

  defp take_live(organisation_id, adapter_id, user_id, nonce, now) do
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
        take_live(organisation_id, adapter_id, user_id, nonce, now)

      %Connection{state: :pending, activated_at: nil} = pending ->
        pending
        |> Ecto.Changeset.change(
          pass_nonce: nonce,
          pass_nonce_used_at: nil,
          created_by_id: user_id,
          updated_at: now
        )
        |> Repo.update()

      # Activated, and no listing has named it: it takes no new pass, so it ends with its
      # activation, its nonce and the person who started it as they are, and a new one
      # takes its place.
      %Connection{state: :pending} = unlisted ->
        with {:ok, _ended} <- end_live(unlisted, :replaced, now) do
          Connection
          |> struct!(new_pending(organisation_id, adapter_id, user_id, nonce, now))
          |> Repo.insert()
        end

      %Connection{state: :connected} ->
        {:error, :connected}
    end
  end

  defp new_pending(organisation_id, adapter_id, user_id, nonce, now) do
    %{
      id: Ecto.UUID.generate(),
      public_id: PublicId.generate(Connection.prefix()),
      organisation_id: organisation_id,
      adapter_id: adapter_id,
      created_by_id: user_id,
      state: :pending,
      pass_nonce: nonce,
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
  #   3. the connection is pending and not activated (it is the adapter's: its keys
  #      signed);
  #   4. its nonce is the connection's latest pass's;
  #   5. no return under that nonce came back yet;
  #   6. it has not expired (`Apiary.Adapters.ReturnToken.good_at?/2`);
  #   7. the person is the one who started the connection, in the browser they started it
  #      in: the session's nonce is the return's;
  #   8. they may still connect an adapter to the connection's organisation
  #      (`adapter.connect`).
  #
  # Then a return that says `linked` activates the connection, which stays pending until
  # the adapter's first listing names it; `refused` and `cancelled` change nothing but the
  # nonce, which is used either way. `{:ok, :linked}`, `{:ok, {:refused, reason}}`,
  # `{:ok, :cancelled}`; `{:error, :wrong_person}` for 7; `{:error, :not_found}` for every
  # other refusal, one answer for a token that is bad, expired or used.
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
           true <- connection.state == :pending and is_nil(connection.activated_at),
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
    with {:ok, _activated} <-
           connection
           |> Ecto.Changeset.change(
             activated_at: now,
             pass_nonce_used_at: now,
             updated_at: now
           )
           |> Repo.update(),
         do: {:ok, :linked}
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
  #   * `{:error, :forbidden}` for a scope of no adapter's key, an id that names no
  #     connection, a connection of another adapter, one that was never activated
  #     (`complete_return/4`), where the feature is off, and for an action the key's role
  #     does not take on its adapter: one answer for all;
  #   * `{:error, :ended}` for one that ended;
  #   * `{:error, :suspended}` while its organisation is out of use: marked for deletion
  #     or held out of use (`Apiary.AccessKeys.organisation_in_use?/1`), or refused by
  #     the edition, which `Apiary.Access.check/3` asks on the narrowed scope of `action`
  #     on the organisation;
  #   * `{:ok, connection, scope}`, the connection with its organisation, and the narrowed
  #     scope.
  @spec connection_for_key(Scope.t() | nil, term, Access.action()) ::
          {:ok, Connection.t(), Scope.t()} | {:error, :forbidden | :ended | :suspended}
  def connection_for_key(key_scope, public_id, action) do
    with {:ok, connection} <- key_connection(key_scope, public_id, false),
         :ok <- key_may(key_scope, action),
         :ok <- not_ended(connection),
         scope = Scope.for_connection(key_scope, connection),
         :ok <- in_use(scope, connection, action) do
      {:ok, connection, scope}
    end
  end

  # The activated connection `public_id` of the adapter whose key `key_scope` carries,
  # with its organisation, `FOR UPDATE` when `lock?`; `{:error, :forbidden}` for anything
  # else.
  defp key_connection(
         %Scope{
           access_key: %AccessKey{
             node_id: adapter_id,
             organisation_id: nil,
             workspace_id: nil,
             node: %Node{kind: :adapter, organisation_id: nil, workspace_id: nil}
           }
         },
         public_id,
         lock?
       )
       when is_binary(adapter_id) do
    with true <- Features.on?(:factory),
         true <- Connection.public_id?(public_id),
         %Connection{} = connection <- Repo.one(key_query(public_id, adapter_id, lock?)) do
      {:ok, connection}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp key_connection(_scope, _public_id, _lock?), do: {:error, :forbidden}

  defp key_query(public_id, adapter_id, lock?) do
    query =
      from c in Connection,
        where: c.public_id == ^public_id and c.adapter_id == ^adapter_id,
        where: not is_nil(c.activated_at),
        preload: :organisation

    if lock?, do: lock(query, "FOR UPDATE"), else: query
  end

  # The key's role holds `action` on its adapter (`Apiary.Access.check/3`, asked of the
  # adapter as `Apiary.Adapters.for_key/2` asks it).
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
  defp in_use(scope, %Connection{organisation: organisation} = connection, action) do
    if AccessKeys.organisation_in_use?(connection.organisation_id) and
         Access.check(scope, action, organisation) == :ok,
       do: :ok,
       else: {:error, :suspended}
  end

  @doc false
  # mark_connected/1 makes `connection`, activated and pending, connected now: for the
  # adapter's first listing that names it, once `connection_for_key/3` found it. One
  # connected already stays as it is. `{:ok, connection}`; `{:error, :ended}` for one that
  # ended meanwhile; `{:error, :forbidden}` for one not activated or not there.
  @spec mark_connected(Connection.t()) ::
          {:ok, Connection.t()} | {:error, :ended | :forbidden}
  def mark_connected(%Connection{id: id}) do
    Repo.transact(fn ->
      case Repo.one(from c in Connection, where: c.id == ^id, lock: "FOR UPDATE") do
        %Connection{state: :pending, activated_at: %DateTime{}} = pending ->
          now = DateTime.utc_now()

          pending
          |> Ecto.Changeset.change(state: :connected, connected_at: now, updated_at: now)
          |> Repo.update()

        %Connection{state: :connected} = connected ->
          {:ok, connected}

        %Connection{state: :ended} ->
          {:error, :ended}

        _other ->
          {:error, :forbidden}
      end
    end)
  end

  ## Ending

  @doc false
  # end_connection/2 ends the connection `public_id` (`ac_…`) of the adapter whose key
  # `key_scope` carries, as the adapter reports it gone (`adapter_reported`), whatever
  # its organisation's state, and clears the pools of that organisation the adapter
  # served, in one transaction, the connection's row first. `{:ok, connection}`, ended;
  # `{:error, :forbidden}` as `connection_for_key/3` answers it; `{:error, :ended}` for
  # one ended already.
  @spec end_connection(Scope.t() | nil, term) ::
          {:ok, Connection.t()} | {:error, :forbidden | :ended}
  def end_connection(key_scope, public_id) do
    Repo.transact(fn ->
      with {:ok, connection} <- key_connection(key_scope, public_id, true),
           :ok <- not_ended(connection) do
        end_live(connection, :adapter_reported, DateTime.utc_now())
      end
    end)
  end

  # Ends `connection`, held `FOR UPDATE` and live, for `reason`, and then clears the pools
  # of its organisation its adapter served: the connection's row first, then the pools.
  # `{:ok, connection}`, ended.
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
      _pools = unserve(connection.organisation_id, connection.adapter_id, now)
      {:ok, ended}
    end
  end

  @doc false
  # Inside `Apiary.Adapters.delete_adapter/2`'s transaction, which holds the adapter's row
  # `FOR NO KEY UPDATE`: ends every connection of `adapter` that has not ended
  # (`integration_deleted`). The public ids of those ended, in order. The caller clears
  # the pools it served, after.
  @spec end_for_adapter(Node.t(), DateTime.t()) :: [String.t()]
  def end_for_adapter(%Node{kind: :adapter, id: adapter_id}, %DateTime{} = now) do
    {_count, ids} =
      Repo.update_all(
        from(c in Connection,
          where: c.adapter_id == ^adapter_id and is_nil(c.ended_at),
          select: c.public_id
        ),
        set: [state: :ended, ended_at: now, ended_reason: :integration_deleted, updated_at: now]
      )

    Enum.sort(ids)
  end

  @doc false
  # end_for_organisation/1 ends every connection of the organisation `organisation_id`
  # that has not ended (`organisation_deleted`), and clears the pools of the organisation
  # that name an adapter: once the organisation's purge has claimed it, and its deletion
  # can no longer be cancelled (`Apiary.Deletion`). The number of connections ended.
  @spec end_for_organisation(Ecto.UUID.t()) :: non_neg_integer
  def end_for_organisation(organisation_id) do
    {:ok, count} =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        {count, _} =
          Repo.update_all(
            from(c in Connection,
              where: c.organisation_id == ^organisation_id and is_nil(c.ended_at)
            ),
            set: [
              state: :ended,
              ended_at: now,
              ended_reason: :organisation_deleted,
              updated_at: now
            ]
          )

        _pools = unserve(organisation_id, :any, now)
        {:ok, count}
      end)

    count
  end

  # The pools of the organisation that name `adapter_id` (any adapter, for `:any`) as the
  # one that serves them, deleted ones too, served by none from now on: the public ids of
  # those in use, in order.
  defp unserve(organisation_id, adapter_id, now) do
    query =
      from n in Node,
        where: n.organisation_id == ^organisation_id and not is_nil(n.served_by_id),
        select: {n.public_id, n.deleted_at}

    query =
      if adapter_id == :any, do: query, else: where(query, [n], n.served_by_id == ^adapter_id)

    {_count, pools} = Repo.update_all(query, set: [served_by_id: nil, updated_at: now])
    for({public_id, nil} <- pools, do: public_id) |> Enum.sort()
  end

  ## A pool's adapter

  @doc false
  # Inside the transaction of a change of a pool, before the pool's row is locked: the
  # connection of the scope's organisation to the adapter `attrs` name as the one that
  # serves the pool (`served_by_id`), connected, held `FOR SHARE`, as the trigger
  # `nodes_served_by_is_an_adapter` holds it after, so the change takes the connection
  # before the pool, in the lock order above. `:ok` whatever it finds: the change checks
  # what it names.
  @spec lock_serving(Scope.t(), map) :: :ok
  def lock_serving(%Scope{organisation: %Organisation{id: organisation_id}}, attrs)
      when is_map(attrs) do
    with id when is_binary(id) <- Map.get(attrs, :served_by_id, Map.get(attrs, "served_by_id")),
         {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.all(
        from c in Connection,
          where: c.organisation_id == ^organisation_id and c.adapter_id == ^id,
          where: c.state == :connected,
          lock: "FOR SHARE",
          select: c.id
      )
    end

    :ok
  end

  def lock_serving(%Scope{}, _attrs), do: :ok
end
