defmodule Apiary.Adapters do
  # Adapters holds the instance's adapters: nodes of kind `:adapter` (`na_…`,
  # `Apiary.Nodes.Node`), each a separate service through which an external system reaches
  # Qory Apiary under an access key of the adapter's node. An adapter is the instance's,
  # with no organisation and no workspace, and is made, renamed and deleted here alone:
  # `Apiary.Nodes` refuses one.
  #
  # An instance admin makes, renames and deletes one (`adapter.create`, `adapter.edit`,
  # `adapter.delete`, which no role takes): each change asks `authorize_instance/2`, an
  # instance admin (`Apiary.Access.instance_admin?/1`) on an instance with the feature
  # `factory`, and, to make one, a recent sign-in, as `Apiary.InstanceConfig.save/3` asks.
  # Each leaves its entry, in its transaction, in the trail of the instance's organisation
  # (`instance_scope/1`). Its access keys are `Apiary.AccessKeys`'s: enrolled with a code
  # an instance admin makes, never made in a browser, never with stored secrets.
  #
  # The people of an organisation read the instance's adapters in use (`adapter.read`,
  # members) where they are shown the feature, and their organisation's connections to
  # them (`Apiary.Adapters.Connections`); an instance admin reads them where the feature
  # is on; anyone else reads none. An owner or an admin of an organisation connects one
  # (`adapter.connect`, `connect/2`), which makes the organisation's connection to it
  # (`Apiary.Adapters.Connection`, `ac_…`), pending until the adapter reports it, and which
  # the organisation's trail records.
  #
  # A node pool may name the adapter that serves it (`served_by_id`, `Apiary.Nodes`): one of
  # `serving_choices/1`, an adapter the pool's organisation is connected to. The database
  # holds a pool to such an adapter (`nodes_served_by_is_an_adapter`), holding the
  # connection `FOR SHARE`. Deleting an adapter revokes its keys, cancels its codes, ends
  # its connections and clears every pool it served, in one transaction, with the
  # adapter's row `FOR NO KEY UPDATE`: the lock order is the adapter's row, then its
  # connections, then the pools (`Apiary.Adapters.Connections`).
  #
  # At the server contract an adapter's key acts as the role `adapter_key`
  # (`Apiary.Access.role/1`), with a scope of no organisation and no workspace
  # (`Apiary.Accounts.Scope.for_access_key/1`): `for_key/2` is the adapter such a scope
  # stands for, once the action is allowed. It acts for an organisation only through a
  # connection (`Apiary.Adapters.Connections.connection_for_key/3`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Accounts, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{ConnectPass, Connection, Connections}
  alias Apiary.Contract.Ed25519
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  ## Who may

  @doc false
  # Whether the person of `scope` may change the instance's adapters, their keys and their
  # codes: `:ok` for an instance admin (`Apiary.Access.instance_admin?/1`) shown the
  # feature `factory` (`Apiary.Features.visible?/2`, of the scope read again with
  # `Apiary.Access.reload/2`); `{:error, :not_found}` where the feature is off, or hidden
  # from the person, whoever asks; `{:error, :forbidden}` for anyone else. With
  # `sudo: true`, an instance admin who did not sign in recently
  # (`Apiary.Accounts.sudo_mode?/2`) is `{:error, :sudo}`, and signs in again first.
  @spec authorize_instance(Scope.t() | nil, keyword) ::
          :ok | {:error, :not_found | :forbidden | :sudo}
  def authorize_instance(scope, opts \\ []) do
    cond do
      not Features.visible?(Access.reload(scope), :factory) -> {:error, :not_found}
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      Keyword.get(opts, :sudo, false) and not signed_in_recently?(scope) -> {:error, :sudo}
      true -> :ok
    end
  end

  defp signed_in_recently?(%Scope{user: user}), do: Accounts.sudo_mode?(user)

  @doc false
  # The scope an instance admin's change of an adapter, its keys or its codes is recorded
  # with: theirs, in the instance's organisation (`Apiary.Accounts.Scope.in_organisation/2`),
  # whose trail holds the entry, as `Apiary.InstanceConfig.save/3` records a change of the
  # instance's settings. `{:error, :forbidden}` on an instance without that organisation.
  @spec instance_scope(Scope.t()) :: {:ok, Scope.t()} | {:error, :forbidden}
  def instance_scope(%Scope{} = scope) do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, Scope.in_organisation(scope, organisation)}
    else
      _none -> {:error, :forbidden}
    end
  end

  ## Reads

  @doc false
  # The instance's adapters in use, by name, to whoever may read them (`readable?/1`);
  # none to anyone else.
  @spec list_adapters(Scope.t()) :: [Node.t()]
  def list_adapters(%Scope{} = scope) do
    if readable?(scope),
      do: live_query() |> order_by([n], asc: n.name, asc: n.id) |> Repo.all(),
      else: []
  end

  @doc false
  # The instance's adapter in use whose public id is `public_id`, with the account that
  # made it, to whoever may read it (`readable?/1`); nil for one deleted, a node of another
  # kind, none, or anyone else.
  @spec get_adapter(Scope.t(), term) :: Node.t() | nil
  def get_adapter(%Scope{} = scope, public_id) when is_binary(public_id) do
    if readable?(scope) do
      live_query()
      |> where([n], n.public_id == ^public_id)
      |> preload(:created_by)
      |> Repo.one()
    end
  end

  def get_adapter(%Scope{}, _public_id), do: nil

  # The instance's adapters are read by a person of an organisation who may read them
  # there (`adapter.read`, where they are shown the feature), and by an instance admin
  # shown it.
  defp readable?(scope),
    do:
      Access.can?(scope, :"adapter.read", scope.organisation) or
        authorize_instance(scope) == :ok

  @doc false
  # The adapters a node pool of the scope's organisation may name as the one that serves
  # it: the instance's adapters in use the organisation is connected to (a connection in
  # state `connected`), by name. A pending one does not count.
  @spec serving_choices(Scope.t()) :: [Node.t()]
  def serving_choices(%Scope{organisation: %Organisation{id: organisation_id}} = scope) do
    if Features.visible?(scope, :factory), do: connected_to(organisation_id), else: []
  end

  def serving_choices(%Scope{}), do: []

  defp connected_to(organisation_id) do
    live_query()
    |> join(:inner, [n], c in Connection,
      on:
        c.adapter_id == n.id and c.organisation_id == ^organisation_id and
          c.state == :connected
    )
    |> order_by([n], asc: n.name, asc: n.id)
    |> Repo.all()
  end

  @doc false
  # Inside the transaction of a change of a pool, before the pool's row is locked: the
  # connection the change names, held as the lock order wants it
  # (`Apiary.Adapters.Connections.lock_serving/2`).
  @spec lock_serving(Scope.t(), map) :: :ok
  defdelegate lock_serving(scope, attrs), to: Connections

  @doc false
  # The node pools in use of the scope's organisation, in any of its workspaces, that
  # `adapter` serves, by name.
  @spec served_pools(Scope.t(), Node.t()) :: [Node.t()]
  def served_pools(
        %Scope{organisation: %Organisation{id: organisation_id}},
        %Node{kind: :adapter, id: id}
      ) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.served_by_id == ^id,
      where: n.kind == :pool and is_nil(n.deleted_at),
      order_by: [asc: n.name, asc: n.id]
    )
    |> Repo.all()
  end

  def served_pools(%Scope{}, %Node{}), do: []

  # The instance's adapters in use: of no organisation and no workspace.
  defp live_query do
    from n in Node,
      where: is_nil(n.organisation_id) and is_nil(n.workspace_id),
      where: n.kind == :adapter and is_nil(n.deleted_at)
  end

  ## Changes

  @doc false
  # The changeset of an adapter's name, for the form that makes or renames one.
  @spec change_adapter(Node.t(), map) :: Ecto.Changeset.t()
  def change_adapter(adapter \\ %Node{kind: :adapter}, attrs \\ %{})

  def change_adapter(%Node{kind: :adapter} = adapter, attrs),
    do: Node.adapter_changeset(adapter, attrs)

  @doc false
  # Makes an adapter of the instance (`adapter.create`, an instance admin after a recent
  # sign-in, `authorize_instance/2`), from `attrs`, its `name`, unique among the
  # instance's adapters in use. `{:ok, adapter}`, `{:error, changeset}`,
  # `{:error, :forbidden}`, `{:error, :sudo}`, or `{:error, :not_found}` where the feature
  # is off.
  @spec create_adapter(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason() | :sudo}
  def create_adapter(%Scope{} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- authorize_instance(scope, sudo: true),
           {:ok, recorder} <- instance_scope(scope),
           changeset =
             Node.adapter_changeset(
               %Node{
                 kind: :adapter,
                 organisation_id: nil,
                 workspace_id: nil,
                 created_by_id: scope.user.id,
                 instance_limit: nil,
                 gateway_choice: :direct
               },
               attrs
             ),
           {:ok, adapter} <- Repo.insert(changeset),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"adapter.create", adapter, %{
               after: Map.take(adapter, [:name, :kind, :public_id])
             }) do
        {:ok, adapter}
      end
    end)
  end

  @doc false
  # Renames `adapter` (`adapter.edit`, an instance admin) from `attrs`, its `name`.
  # `{:ok, adapter}`, unchanged and with no entry when the name is the same;
  # `{:error, changeset}`; `{:error, :forbidden}`; or `{:error, :not_found}`.
  @spec rename_adapter(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def rename_adapter(%Scope{} = scope, %Node{} = adapter, attrs) do
    mutate(scope, adapter, fn recorder, current ->
      with {:ok, renamed} <- current |> Node.adapter_changeset(attrs) |> Repo.update(),
           :ok <- record_rename(recorder, current, renamed) do
        {:ok, renamed}
      end
    end)
  end

  defp record_rename(scope, old, new) do
    case Audit.changed(old, new, [:name]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"adapter.edit", new, changes), do: :ok
    end
  end

  @doc false
  # Starts the connection of `adapter` to the scope's organisation (`adapter.connect`,
  # owners and admins, asked of the organisation), with `adapter` as it is now, in use and
  # held `FOR SHARE`: the organisation's pending connection to it, made or taken
  # (`Apiary.Adapters.Connections.start/3`, which ends a connected one no listing has
  # named yet and makes a new one in its place), with a new connect pass for it
  # (`Apiary.Adapters.ConnectPass`), whose nonce the connection keeps as its latest pass's.
  # `{:ok, url, session}`: `url`, the address the adapter declared (`connect_url`) with
  # the pass as its query parameter `state`, where the page sends the person; `session`,
  # `{connection_public_id, nonce}`, the nonce in base64url, which the person's session
  # keeps (`ApiaryWeb.ConnectSession`), so the return comes back in their browser. The
  # entry is the organisation's, about the organisation, naming the adapter and the
  # connection, never the pass or its nonce.
  #
  # `{:error, :connected}` while the organisation is connected to it and a listing named
  # the connection;
  # `{:error, :no_connect_url}` while the adapter declared no address; `{:error, :no_key}`
  # while it holds no access key in use; `{:error, :forbidden}`; `{:error, :not_found}`;
  # none of them changes anything or leaves an entry.
  @spec connect(Scope.t(), Node.t()) ::
          {:ok, String.t(), {String.t(), String.t()}}
          | {:error,
             :connected | :no_connect_url | :no_key | :invalid | :too_long | Access.reason()}
  def connect(%Scope{} = scope, %Node{id: id}) do
    result =
      Repo.transact(fn ->
        with :ok <- Access.authorize(scope, :"adapter.connect", scope.organisation),
             %Node{} = current <-
               live_query() |> where([n], n.id == ^id) |> lock("FOR SHARE") |> Repo.one() ||
                 {:error, :not_found},
             :ok <- connectable(current),
             nonce = ConnectPass.new_nonce(),
             {:ok, connection} <- Connections.start(scope, current, nonce),
             {:ok, pass} <-
               ConnectPass.issue(current.public_id, connection.public_id, nonce: nonce),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"adapter.connect", scope.organisation, %{
                 details:
                   current
                   |> Map.take([:name, :public_id])
                   |> Map.put(:connection_id, connection.public_id)
               }) do
          {:ok,
           {with_state(current.connect_url, pass), {connection.public_id, Ed25519.encode(nonce)}}}
        end
      end)

    case result do
      {:ok, {url, session}} -> {:ok, url, session}
      {:error, _reason} = error -> error
    end
  end

  defp connectable(%Node{connect_url: nil}), do: {:error, :no_connect_url}

  defp connectable(%Node{} = adapter),
    do: if(AccessKeys.active_key?(adapter), do: :ok, else: {:error, :no_key})

  # The connect address with the pass as the query parameter `state`, before any fragment:
  # `?state=` when the address has no query, `&state=` after one. A pass is base64url and
  # a dot, which a query carries as they are.
  defp with_state(url, pass) do
    {base, fragment} =
      case String.split(url, "#", parts: 2) do
        [base, fragment] -> {base, "#" <> fragment}
        [base] -> {base, ""}
      end

    separator =
      cond do
        not String.contains?(base, "?") -> "?"
        String.ends_with?(base, ["?", "&"]) -> ""
        true -> "&"
      end

    base <> separator <> "state=" <> pass <> fragment
  end

  @doc false
  # Deletes `adapter` (`adapter.delete`, an instance admin): it leaves every page, its name
  # is free again, and its row stays for what names it. In the same transaction, under its
  # row held `FOR NO KEY UPDATE` (`mutate/3`), its keys in use are revoked and its
  # outstanding codes cancelled (`Apiary.AccessKeys.revoke_node_keys/3`, each key with
  # its entry of `access_key.revoke`), every connection to it that has not ended ends
  # (`integration_deleted`), and then every pool it served is served by none, which the
  # entry records (`ended_connection_ids` and `unserved_pool_ids`, their public ids).
  # `{:ok, adapter}`, `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec delete_adapter(Scope.t(), Node.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def delete_adapter(%Scope{} = scope, %Node{} = adapter) do
    mutate(scope, adapter, fn recorder, current ->
      now = DateTime.utc_now()

      with {:ok, key_ids} <- AccessKeys.revoke_node_keys(recorder, current, :node_deleted),
           connection_ids = Connections.end_for_adapter(current, now),
           pool_ids = unserve_pools(current, now),
           {:ok, deleted} <-
             current
             |> Ecto.Changeset.change(deleted_at: now, deleted_by_id: scope.user.id)
             |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"adapter.delete", deleted, %{
               before: %{deleted_at: nil},
               after: %{deleted_at: deleted.deleted_at},
               details:
                 deleted
                 |> Map.take([:name, :kind, :public_id])
                 |> Map.put(:revoked_key_ids, key_ids)
                 |> Map.put(:ended_connection_ids, connection_ids)
                 |> Map.put(:unserved_pool_ids, pool_ids)
             }) do
        {:ok, deleted}
      end
    end)
  end

  # Every pool `adapter` serves, of any organisation, deleted ones too, is served by none
  # from now on: the public ids of those in use, in order.
  defp unserve_pools(%Node{id: id}, now) do
    {_count, pools} =
      Repo.update_all(
        from(n in Node, where: n.served_by_id == ^id, select: {n.public_id, n.deleted_at}),
        set: [served_by_id: nil, updated_at: now]
      )

    for({public_id, nil} <- pools, do: public_id) |> Enum.sort()
  end

  # Asks `authorize_instance/2` of the person as they are now, then hands `fun` the scope
  # the change is recorded with (`instance_scope/1`) and the adapter as it is now, in use,
  # locked for the rest of the transaction.
  #
  # `FOR NO KEY UPDATE`, not `FOR UPDATE`: a rename and a deletion change no column a
  # reference names (`id`, `public_id`, `organisation_id`, `workspace_id`), so they need
  # not wait on, or keep out, the `FOR KEY SHARE` that Postgres takes on the adapter's row
  # to check a pool's `served_by_id`. A change of a pool holds the connection
  # `FOR SHARE` before that check; were the deletion to hold the adapter `FOR UPDATE`
  # while it waits to end that connection, the two would wait on each other. It still
  # keeps out a connect, which holds the row `FOR SHARE`, and a change of the adapter's
  # keys (`Apiary.AccessKeys`), which holds it `FOR UPDATE`.
  defp mutate(scope, %Node{id: id}, fun) do
    Repo.transact(fn ->
      with :ok <- authorize_instance(scope),
           {:ok, recorder} <- instance_scope(scope),
           %Node{} = current <-
             live_query()
             |> where([n], n.id == ^id)
             |> lock("FOR NO KEY UPDATE")
             |> Repo.one() ||
               {:error, :not_found} do
        fun.(recorder, current)
      end
    end)
  end

  ## At the server contract

  @doc false
  # The adapter an access key's scope stands for, once `action` is allowed to it
  # (`Apiary.Access.authorize/3`, asked of the adapter): `{:ok, adapter}`, or `{:error,
  # :not_found}` for a scope of no key, a key with an organisation or a workspace, a key
  # whose node is no adapter in use, or an action the key may not take there,
  # `{:error, :forbidden}` for one its role does not hold.
  @spec for_key(Scope.t(), Access.action()) :: {:ok, Node.t()} | {:error, Access.reason()}
  def for_key(
        %Scope{
          access_key: %AccessKey{node_id: node_id, organisation_id: nil, workspace_id: nil}
        } = scope,
        action
      )
      when is_binary(node_id) do
    adapter = live_query() |> where([n], n.id == ^node_id) |> Repo.one()

    with %Node{} <- adapter || {:error, :not_found},
         :ok <- Access.authorize(scope, action, adapter) do
      {:ok, adapter}
    end
  end

  def for_key(%Scope{}, _action), do: {:error, :not_found}
end
