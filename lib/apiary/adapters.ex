defmodule Apiary.Adapters do
  # Adapters holds an organisation's adapters: nodes of kind `:adapter` (`na_…`,
  # `Apiary.Nodes.Node`), each a separate service through which an external system reaches
  # Qory Apiary under an access key of the adapter's node. An adapter lives at its organisation,
  # with no workspace, and is made, renamed, connected and deleted here alone:
  # `Apiary.Nodes` refuses one.
  #
  # Every function a page calls takes a scope of the organisation and reads or changes only
  # its adapters in use; an adapter of another organisation, a deleted one, or a node of
  # another kind is not found. Each change asks `Apiary.Access` first, `adapter.create`,
  # `adapter.edit`, `adapter.connect` or `adapter.delete` (owners and admins), all of the
  # feature `factory`, so a change where the feature is off or hidden from the person is
  # not found; and leaves its audit entry in its transaction. Its access keys are
  # `Apiary.AccessKeys`'s: enrolled with a code (`access_key.create_code`), never made in a
  # browser, never with stored secrets.
  #
  # A node pool may name the adapter that serves it (`served_by_id`, `Apiary.Nodes`): one of
  # `serving_choices/1`. Deleting an adapter revokes its keys, cancels its codes and clears
  # every pool it served, in one transaction, under the organisation's lock that a change
  # of a pool takes too (`Apiary.Gateways.lock/1`), with the adapter's row `FOR UPDATE`.
  #
  # At the server contract an adapter's key acts as the role `adapter_key`
  # (`Apiary.Access.role/1`), with a scope of its organisation and no workspace
  # (`Apiary.Accounts.Scope.for_access_key/1`): `for_key/2` is the adapter such a scope
  # stands for, once the action is allowed.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Audit, Gateways, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  ## Reads

  @doc false
  # The scope's organisation's adapters in use, by name.
  @spec list_adapters(Scope.t()) :: [Node.t()]
  def list_adapters(%Scope{} = scope) do
    scope
    |> live_query()
    |> order_by([n], asc: n.name, asc: n.id)
    |> Repo.all()
  end

  @doc false
  # The scope's organisation's adapter in use whose public id is `public_id`, with the
  # account that made it; nil for one deleted, of another organisation, a node of another
  # kind, or none.
  @spec get_adapter(Scope.t(), term) :: Node.t() | nil
  def get_adapter(%Scope{} = scope, public_id) when is_binary(public_id) do
    scope
    |> live_query()
    |> where([n], n.public_id == ^public_id)
    |> preload(:created_by)
    |> Repo.one()
  end

  def get_adapter(%Scope{}, _public_id), do: nil

  @doc false
  # The adapters a node pool of the scope's organisation may name as the one that serves
  # it: the organisation's adapters in use, by name.
  @spec serving_choices(Scope.t()) :: [Node.t()]
  def serving_choices(%Scope{} = scope), do: list_adapters(scope)

  @doc false
  # The node pools in use of the scope's organisation, in any of its workspaces, that
  # `adapter` serves, by name.
  @spec served_pools(Scope.t(), Node.t()) :: [Node.t()]
  def served_pools(
        %Scope{organisation: %Organisation{id: organisation_id}},
        %Node{kind: :adapter, id: id, organisation_id: organisation_id}
      ) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.served_by_id == ^id,
      where: n.kind == :pool and is_nil(n.deleted_at),
      order_by: [asc: n.name, asc: n.id]
    )
    |> Repo.all()
  end

  def served_pools(%Scope{}, %Node{}), do: []

  # The scope's organisation's adapters in use.
  defp live_query(%Scope{organisation: %Organisation{id: organisation_id}}) do
    from n in Node,
      where: n.organisation_id == ^organisation_id and is_nil(n.workspace_id),
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
  # Makes an adapter of the scope's organisation (`adapter.create`, owners and admins),
  # from `attrs`, its `name`. `{:ok, adapter}`, `{:error, changeset}`, `{:error,
  # :forbidden}`, or `{:error, :not_found}` where the feature is off or hidden from the
  # person, or the organisation out of their reach.
  @spec create_adapter(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_adapter(
        %Scope{user: user, organisation: %Organisation{id: organisation_id} = organisation} =
          scope,
        attrs
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"adapter.create", organisation),
           changeset =
             Node.adapter_changeset(
               %Node{
                 kind: :adapter,
                 organisation_id: organisation_id,
                 workspace_id: nil,
                 created_by_id: user.id,
                 instance_limit: nil,
                 gateway_choice: :direct
               },
               attrs
             ),
           {:ok, adapter} <- Repo.insert(changeset),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"adapter.create", adapter, %{
               after: Map.take(adapter, [:name, :kind, :public_id])
             }) do
        {:ok, adapter}
      end
    end)
  end

  @doc false
  # Renames `adapter` (`adapter.edit`, owners and admins) from `attrs`, its `name`.
  # `{:ok, adapter}`, unchanged and with no entry when the name is the same;
  # `{:error, changeset}`; `{:error, :forbidden}`; or `{:error, :not_found}`.
  @spec rename_adapter(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def rename_adapter(%Scope{} = scope, %Node{} = adapter, attrs) do
    mutate(scope, :"adapter.edit", adapter, fn current ->
      with {:ok, renamed} <- current |> Node.adapter_changeset(attrs) |> Repo.update(),
           :ok <- record_rename(scope, current, renamed) do
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
  # Starts the connection of `adapter` (`adapter.connect`, owners and admins): `issue`,
  # given the adapter as it is now, makes what the person is sent to the adapter with,
  # `{:ok, pass}`, which the entry never holds. `{:ok, pass}`, `{:error, :forbidden}`,
  # `{:error, :not_found}`, or the `{:error, reason}` of `issue`, with no entry.
  @spec connect(Scope.t(), Node.t(), (Node.t() -> {:ok, term} | {:error, term})) ::
          {:ok, term} | {:error, term}
  def connect(%Scope{} = scope, %Node{} = adapter, issue) when is_function(issue, 1) do
    mutate(scope, :"adapter.connect", adapter, fn current ->
      with {:ok, pass} <- issue.(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"adapter.connect", current, %{
               details: Map.take(current, [:name, :public_id])
             }) do
        {:ok, pass}
      end
    end)
  end

  @doc false
  # Deletes `adapter` (`adapter.delete`, owners and admins): it leaves every page, its name
  # is free again, and its row stays for what names it until its organisation is purged.
  # In the same transaction its keys in use are revoked and its outstanding codes
  # cancelled (`Apiary.AccessKeys.revoke_node_keys/3`, each key with its entry of
  # `access_key.revoke`), and every pool it served is served by none, which the entry
  # records (`unserved_pool_ids`, their public ids). The organisation's lock comes first
  # (`Apiary.Gateways.lock/1`), as a change of a pool takes it, then the adapter's row.
  # `{:ok, adapter}`, `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec delete_adapter(Scope.t(), Node.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def delete_adapter(
        %Scope{user: user, organisation: %Organisation{id: organisation_id}} = scope,
        %Node{} = adapter
      ) do
    Repo.transact(fn ->
      with :ok <- Gateways.lock({:organisation, organisation_id}) do
        mutate(scope, :"adapter.delete", adapter, fn current ->
          now = DateTime.utc_now()

          with {:ok, key_ids} <- AccessKeys.revoke_node_keys(scope, current, :node_deleted),
               pool_ids = unserve_pools(current, now),
               {:ok, deleted} <-
                 current
                 |> Ecto.Changeset.change(deleted_at: now, deleted_by_id: user.id)
                 |> Repo.update(),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"adapter.delete", deleted, %{
                   before: %{deleted_at: nil},
                   after: %{deleted_at: deleted.deleted_at},
                   details:
                     deleted
                     |> Map.take([:name, :kind, :public_id])
                     |> Map.put(:revoked_key_ids, key_ids)
                     |> Map.put(:unserved_pool_ids, pool_ids)
                 }) do
            {:ok, deleted}
          end
        end)
      end
    end)
  end

  # Every pool `adapter` serves, deleted ones too, is served by none from now on: the
  # public ids of those in use, in order.
  defp unserve_pools(%Node{id: id, organisation_id: organisation_id}, now) do
    {_count, pools} =
      Repo.update_all(
        from(n in Node,
          where: n.organisation_id == ^organisation_id and n.served_by_id == ^id,
          select: {n.public_id, n.deleted_at}
        ),
        set: [served_by_id: nil, updated_at: now]
      )

    for({public_id, nil} <- pools, do: public_id) |> Enum.sort()
  end

  # Asks `action` of the person as they are now, then hands `fun` the adapter as it is now,
  # in use and the scope's organisation's, locked for the rest of the transaction.
  defp mutate(scope, action, %Node{id: id} = adapter, fun) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, action, adapter),
           %Node{} = current <-
             scope |> live_query() |> where([n], n.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
        fun.(current)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  ## At the server contract

  @doc false
  # The adapter an access key's scope stands for, once `action` is allowed to it
  # (`Apiary.Access.authorize/3`, asked of the adapter): `{:ok, adapter}`, or `{:error,
  # :not_found}` for a scope of no key, a key whose node is no adapter in use of the key's
  # organisation, or an action the key may not take there, `{:error, :forbidden}` for one
  # its role does not hold.
  @spec for_key(Scope.t(), Access.action()) :: {:ok, Node.t()} | {:error, Access.reason()}
  def for_key(
        %Scope{access_key: %AccessKey{node_id: node_id, organisation_id: organisation_id}} =
          scope,
        action
      )
      when is_binary(node_id) and is_binary(organisation_id) do
    adapter =
      Repo.one(
        from n in Node,
          where: n.id == ^node_id and n.organisation_id == ^organisation_id,
          where: n.kind == :adapter and is_nil(n.workspace_id) and is_nil(n.deleted_at)
      )

    with %Node{} <- adapter || {:error, :not_found},
         :ok <- Access.authorize(scope, action, adapter) do
      {:ok, adapter}
    end
  end

  def for_key(%Scope{}, _action), do: {:error, :not_found}
end
