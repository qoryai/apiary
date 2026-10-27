defmodule Apiary.Adapters.Grants do
  # The grants of an organisation's connections to the instance's adapters
  # (`Apiary.Adapters.Grant`, `ag_…`), as the integration contract has them
  # (`grant.schema.json`, `grants.schema.json`): one per external account a connection
  # reaches.
  #
  # A grant is added when Qory Apiary accepts the adapter's report of it (`report/2`,
  # `POST /v1/grants`), and at no other step. The report names the nonce of a connect
  # pass of the connection whose return came back `linked`
  # (`Apiary.Adapters.LinkedPass`), so a grant is added only under a pass whose return the
  # person who started it brought back in the browser they started it in
  # (`Apiary.Adapters.Connections.complete_return/4`): an adapter's report alone cannot add
  # an external account to an organisation. Each such nonce is accepted once. The grant
  # keeps the report's external account, its id at the source and its display name. A
  # report of a ref the connection has a grant for replaces that grant in place, its
  # account included. The pass check
  # (`pass_unknown`) runs first. Then a report is refused (`grant_taken`) when the adapter
  # has a grant with the same ref that has not ended under any other connection of the
  # adapter, of any organisation, a connection made but with no accepted listing yet
  # included: an external account is linked to one connection of the adapter at a time.
  #
  # A grant ends with its connection (`end_for_connections/2`), or alone when the adapter
  # reports that the source no longer covers it (`end_grant/2`, `POST /v1/grants/end`),
  # which ends the collections the grant covers, those whose latest listing had that
  # grant (`Apiary.Adapters.Collections.end_for_grant/2`), and leaves the connection
  # connected. The connection stays connected when it has no grant. Each report
  # accepted writes the feed's grant entry, `linked`, and each grant that ends writes
  # one, `unlinked` (`Apiary.Adapters.Feed`). The adapter reads Qory Apiary's copy of every grant of its
  # connections that have not ended (`list_for_adapter/1`, `GET /v1/grants`).
  #
  # The lock order: the connection, then its linked passes, then the grants, then the
  # collections (`Apiary.Adapters.Collections`), then the adapter's feed counter. A
  # report holds the connection `FOR UPDATE`, so two reports for one connection run one
  # after the other; an end holds the connection, ends its grants, then its collections,
  # then writes the grants' entries. A grant end locks the connection `FOR UPDATE`, so it
  # runs one at a time with the connection's reports and the parts of its listings.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Audit, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collections, Connection, Connections, Feed, Grant, LinkedPass}
  alias Apiary.Nodes.Node

  @typedoc "A grant report, as `Apiary.Adapters.Wire.grant_report/1` reads it."
  @type report :: %{
          required(:connection_id) => String.t(),
          required(:grant_ref) => String.t(),
          required(:account) => %{ref: String.t(), title: String.t()},
          required(:pass_nonce) => <<_::128>>,
          optional(atom) => term
        }

  @typedoc "A grant end, as `Apiary.Adapters.Wire.grant_end/1` reads it."
  @type grant_end :: %{
          required(:connection_id) => String.t(),
          required(:grant_ref) => String.t(),
          optional(atom) => term
        }

  @typedoc "Why a report is refused, in the contract's order."
  @type refusal ::
          :forbidden | :unknown | :ended | :suspended | :pass_unknown | :grant_taken

  @doc false
  # report/2 takes the grant report of the adapter's key of `key_scope`
  # (`adapter.report_grant`). Every check is made before any change, in this order:
  #
  #   * `{:error, :forbidden | :unknown | :ended | :suspended}` for the connection, as
  #     `Apiary.Adapters.Connections.connection_for_key/3` answers (`connection_unknown`
  #     for one pending);
  #   * `{:error, :pass_unknown}` when `pass_nonce` is not the nonce of a pass of that
  #     connection whose return came back linked, or a report under it was accepted
  #     already;
  #   * `{:error, :grant_taken}`, checked after `pass_unknown`, when the adapter has a
  #     grant with `grant_ref` that has not ended under any other connection of the
  #     adapter, of any organisation, a connection made but with no accepted listing yet
  #     included.
  #
  # Then, in one transaction, the grant is added with the report's account, or the
  # connection's live grant with that ref takes the pass's nonce, the account and the
  # time; the pass is marked reported; the feed's grant
  # entry, `linked`, is written; and the entry `adapter.report_grant` goes into the trail
  # the key records in, the instance organisation's, about the adapter, with the key as
  # its actor and the connection's and the grant's public ids, without the nonce or the
  # ref. `{:ok, grant}`. None of the refusals changes anything or leaves an entry.
  @spec report(Scope.t() | nil, report) :: {:ok, Grant.t()} | {:error, refusal}
  def report(
        key_scope,
        %{connection_id: public_id, grant_ref: ref, account: account, pass_nonce: nonce} =
          _report
      )
      when is_binary(ref) and is_binary(nonce) and byte_size(nonce) == 16 do
    Repo.transact(fn ->
      with {:ok, connection, _scope} <-
             Connections.connection_for_key(key_scope, public_id, :"adapter.report_grant"),
           {:ok, connection} <- lock_connected(connection),
           {:ok, pass} <- lock_pass(connection, nonce),
           now = DateTime.utc_now(),
           {:ok, grant, replaced} <- put_grant(connection, ref, account, nonce, now),
           {1, _} <-
             Repo.update_all(from(p in LinkedPass, where: p.id == ^pass.id),
               set: [reported_at: now]
             ),
           adapter = Repo.get!(Node, connection.adapter_id),
           {:ok, _seq} <- tell(adapter, connection, [grant], "linked"),
           {:ok, _entry} <-
             Audit.record(Repo, key_scope, :"adapter.report_grant", adapter, %{
               details: %{
                 connection_id: connection.public_id,
                 grant_id: grant.public_id,
                 replaced: replaced
               }
             }) do
        {:ok, grant}
      end
    end)
  end

  # The connection, found for the key, held `FOR UPDATE` and still connected: an end
  # that committed after the key's check is `{:error, :ended}`.
  defp lock_connected(%Connection{id: id, organisation: organisation}) do
    case Repo.one(from c in Connection, where: c.id == ^id, lock: "FOR UPDATE") do
      %Connection{state: :connected} = connection ->
        {:ok, %{connection | organisation: organisation}}

      _ended ->
        {:error, :ended}
    end
  end

  # The linked pass of `connection` with `nonce`, not reported under yet, held
  # `FOR UPDATE`.
  defp lock_pass(%Connection{id: connection_id}, nonce) do
    case Repo.one(
           from p in LinkedPass,
             where: p.connection_id == ^connection_id and p.nonce == ^nonce,
             lock: "FOR UPDATE"
         ) do
      %LinkedPass{reported_at: nil} = pass -> {:ok, pass}
      _other -> {:error, :pass_unknown}
    end
  end

  # The grant of the adapter with `ref` that has not ended, held `FOR UPDATE`; it runs
  # after `lock_pass/2`, so `pass_unknown` comes first. The connection's grant takes the
  # new nonce, account and time; a grant under any other connection of the adapter, of any
  # organisation, a connection made but with no accepted listing yet included, refuses
  # the report (`grant_taken`); with none, a grant is added. Two connections' reports of
  # one ref at once: the second's insert waits on the live index for the first's to
  # commit, and is refused then.
  defp put_grant(%Connection{} = connection, ref, account, nonce, now) do
    live =
      Repo.one(
        from g in Grant,
          where: g.adapter_id == ^connection.adapter_id and g.grant_ref == ^ref,
          where: is_nil(g.ended_at),
          lock: "FOR UPDATE"
      )

    case live do
      %Grant{connection_id: id} = grant when id == connection.id ->
        with {:ok, grant} <-
               grant
               |> Ecto.Changeset.change(
                 pass_nonce: nonce,
                 account_ref: account.ref,
                 account_title: account.title,
                 granted_at: now,
                 updated_at: now
               )
               |> Repo.update(),
             do: {:ok, grant, true}

      %Grant{} ->
        {:error, :grant_taken}

      nil ->
        insert(connection, ref, account, nonce, now)
    end
  end

  defp insert(connection, ref, account, nonce, now) do
    %Grant{
      public_id: PublicId.generate(Grant.prefix()),
      organisation_id: connection.organisation_id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      grant_ref: ref,
      account_ref: account.ref,
      account_title: account.title,
      state: :live,
      pass_nonce: nonce,
      granted_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:public_id)
    |> Ecto.Changeset.unique_constraint(:grant_ref, name: :adapter_grants_live_index)
    |> PublicId.Insert.insert()
    |> case do
      {:ok, grant} -> {:ok, grant, false}
      {:error, %Ecto.Changeset{}} -> {:error, :grant_taken}
    end
  end

  @doc false
  # list_for_adapter/1 is Qory Apiary's copy of the grants of the connections of the
  # adapter whose key `key_scope` carries that have not ended (`adapter.read_grants`), as
  # `GET /v1/grants` answers it: `{:ok, [{connection_id, grant_ref}]}`, by connection id,
  # then ref, a connection whose organisation is out of use included.
  # `{:error, :forbidden}` for a request outside the key's rights.
  @spec list_for_adapter(Scope.t() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :forbidden}
  def list_for_adapter(key_scope) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, :"adapter.read_grants") do
      {:ok,
       Repo.all(
         from g in Grant,
           join: c in Connection,
           on: c.id == g.connection_id,
           where: g.adapter_id == ^adapter_id and is_nil(g.ended_at) and is_nil(c.ended_at),
           order_by: [c.public_id, g.grant_ref],
           select: {c.public_id, g.grant_ref}
       )}
    end
  end

  @doc false
  # live_for_organisation/3 is the live grant of the adapter `adapter_id` with
  # `grant_ref` under a connected connection of the organisation `organisation_id`, as a
  # resolve answer names it (`resolve-answer.schema.json`), or nil: a ref the adapter
  # names under another organisation's connection, or under none, is not the
  # organisation's.
  @spec live_for_organisation(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: Grant.t() | nil
  def live_for_organisation(adapter_id, grant_ref, organisation_id)
      when is_binary(adapter_id) and is_binary(grant_ref) and is_binary(organisation_id) do
    Repo.one(
      from g in Grant,
        join: c in Connection,
        on: c.id == g.connection_id,
        where: g.adapter_id == ^adapter_id and g.grant_ref == ^grant_ref,
        where: g.organisation_id == ^organisation_id and is_nil(g.ended_at),
        where: c.state == :connected
    )
  end

  @doc false
  # end_grant/2 takes the grant end of the adapter's key of `key_scope`
  # (`adapter.end_grant`): the source no longer covers the grant `grant_ref` of the
  # connection `connection_id`. Every check is made before any change, in this order:
  #
  #   * `{:error, :forbidden}` for a request outside the key's rights, decided from the
  #     key and the action alone, before any connection is looked up
  #     (`Apiary.Adapters.Connections.key_rights/2`);
  #   * `{:error, :unknown}` (`connection_unknown`) for an id of no connection of
  #     the key's adapter, a connection of another adapter, of any organisation, and one
  #     pending, which has no grant: one answer for all;
  #   * `{:error, :ended}` for a connection that ended;
  #   * `{:error, :grant_unknown}` when the connection has no live grant with
  #     `grant_ref`: one that ended, by an earlier grant end among others, or one never
  #     reported.
  #
  # The organisation's state is not asked: a grant end of a connection whose
  # organisation is out of use goes on, as in the contract. Then, in one transaction
  # that locks the connection `FOR UPDATE`, then the grant: the grant ends
  # (`adapter_reported`); the live collections whose grant it is end as a disconnect
  # ends them, with the feed's `unlinked` entry for each that was linked
  # (`Apiary.Adapters.Collections.end_for_grant/2`); the feed's grant entry, `unlinked`,
  # is written; and the entry `adapter.end_grant` goes into the trail the key records in,
  # the instance organisation's, about the adapter, with the key as its actor, the
  # connection's and the grant's public ids and the number of collections ended, without
  # the ref. The connection stays connected, with its other grants and their collections.
  # Once it commits, the collections ended are broadcast to the organisation.
  # `{:ok, grant}`, ended. None of the refusals changes anything or leaves an entry.
  @spec end_grant(Scope.t() | nil, grant_end) ::
          {:ok, Grant.t()} | {:error, :forbidden | :unknown | :ended | :grant_unknown}
  def end_grant(key_scope, %{connection_id: public_id, grant_ref: ref} = _grant_end)
      when is_binary(ref) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, :"adapter.end_grant") do
      Repo.transact(fn ->
        with {:ok, connection} <- lock_for_end(adapter_id, public_id),
             {:ok, grant} <- lock_live_grant(connection, ref) do
          now = DateTime.utc_now()

          {1, [ended]} =
            Repo.update_all(
              from(g in Grant, where: g.id == ^grant.id, select: g),
              set: [
                state: :ended,
                ended_at: now,
                ended_reason: :adapter_reported,
                updated_at: now
              ]
            )

          collections = Collections.end_for_grant(ended, now)
          adapter = Repo.get!(Node, adapter_id)
          {:ok, _seq} = tell(adapter, connection, [ended], "unlinked")

          {:ok, _entry} =
            Audit.record(Repo, key_scope, :"adapter.end_grant", adapter, %{
              details: %{
                connection_id: connection.public_id,
                grant_id: ended.public_id,
                collections: length(collections)
              }
            })

          {:ok, {connection, ended, collections}}
        end
      end)
      |> case do
        {:ok, {connection, ended, collections}} ->
          :ok = Collections.broadcast_ended(connection, collections)
          {:ok, ended}

        {:error, _reason} = refused ->
          refused
      end
    end
  end

  # The connection `public_id` of the adapter `adapter_id`, of any organisation, locked
  # `FOR UPDATE`: `{:ok, connection}` while it is connected; `{:error, :ended}` once it
  # ended; `{:error, :unknown}` for an id that matches none of the adapter's connections,
  # or one pending.
  defp lock_for_end(adapter_id, public_id) do
    with true <- Connection.public_id?(public_id),
         %Connection{} = connection <-
           Repo.one(
             from c in Connection,
               where: c.public_id == ^public_id and c.adapter_id == ^adapter_id,
               lock: "FOR UPDATE"
           ) do
      case connection.state do
        :connected -> {:ok, connection}
        :ended -> {:error, :ended}
        :pending -> {:error, :unknown}
      end
    else
      _ -> {:error, :unknown}
    end
  end

  # The live grant of `connection` with `ref`, locked `FOR UPDATE`, or
  # `{:error, :grant_unknown}`.
  defp lock_live_grant(%Connection{id: connection_id}, ref) do
    case Repo.one(
           from g in Grant,
             where: g.connection_id == ^connection_id and g.grant_ref == ^ref,
             where: is_nil(g.ended_at),
             lock: "FOR UPDATE"
         ) do
      %Grant{} = grant -> {:ok, grant}
      nil -> {:error, :grant_unknown}
    end
  end

  @doc false
  # live_refs/2, inside a transaction that locks `connection` `FOR UPDATE`, as the
  # transaction of a listing's part does: the ids of its live grants with the refs
  # `refs`, by ref. A ref with no live grant of the connection is not a key.
  @spec live_refs(Connection.t(), [String.t()]) :: %{String.t() => Ecto.UUID.t()}
  def live_refs(%Connection{id: connection_id}, refs) when is_list(refs) do
    Repo.all(
      from g in Grant,
        where: g.connection_id == ^connection_id and g.grant_ref in ^Enum.uniq(refs),
        where: is_nil(g.ended_at),
        select: {g.grant_ref, g.id}
    )
    |> Map.new()
  end

  @doc false
  # Inside the transaction that ends the connections `connection_ids`, which holds them:
  # ends their live grants (`connection_ended`) at `now`, before their collections end.
  # The grants ended, which `tell_unlinked/1` writes to the feed after the collections.
  @spec end_for_connections([Ecto.UUID.t()], DateTime.t()) :: [Grant.t()]
  def end_for_connections([], _now), do: []

  def end_for_connections(connection_ids, %DateTime{} = now) when is_list(connection_ids) do
    {_count, ended} =
      Repo.update_all(
        from(g in Grant,
          where: g.connection_id in ^connection_ids and is_nil(g.ended_at),
          select: g
        ),
        set: [state: :ended, ended_at: now, ended_reason: :connection_ended, updated_at: now]
      )

    ended
  end

  @doc false
  # The feed's grant entry, `unlinked`, for each of `grants`, by adapter, then by
  # connection and ref, inside the transaction that ended them. `:ok`.
  @spec tell_unlinked([Grant.t()]) :: :ok
  def tell_unlinked(grants) do
    grants
    |> Repo.preload(:connection)
    |> Enum.group_by(& &1.connection)
    |> Enum.sort_by(fn {connection, _grants} -> {connection.adapter_id, connection.public_id} end)
    |> Enum.each(fn {connection, told} ->
      {:ok, _seq} = tell(Repo.get!(Node, connection.adapter_id), connection, told, "unlinked")
    end)
  end

  # The feed's grant entry of `status` for each of `grants` of `connection`, in the feed
  # of `adapter`, by ref.
  # `{:ok, seq}` of the last; `{:ok, nil}` for none.
  defp tell(%Node{} = adapter, %Connection{public_id: public_id}, grants, status) do
    grants
    |> Enum.sort_by(& &1.grant_ref)
    |> Enum.reduce({:ok, nil}, fn %Grant{grant_ref: ref}, {:ok, _seq} ->
      Feed.append(adapter, %{
        kind: "grant",
        connection_id: public_id,
        grant_ref: ref,
        status: status
      })
    end)
  end
end
