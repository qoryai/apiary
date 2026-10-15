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
  # members) where they are shown the feature, and an instance admin reads them where the
  # feature is on; anyone else reads none. An owner or an admin of an organisation
  # connects one (`adapter.connect`), which the organisation's trail records.
  #
  # A node pool may name the adapter that serves it (`served_by_id`, `Apiary.Nodes`): one of
  # `serving_choices/1`. The database holds a pool to an adapter of the pool's organisation
  # (`nodes_served_by_is_an_adapter`), and an adapter has none, so no pool names one, and
  # `serving_choices/1` offers none. Deleting an adapter revokes its keys, cancels its codes
  # and clears every pool it served, in one transaction, with the adapter's row
  # `FOR UPDATE`, which the trigger holds `FOR SHARE` in a change that names it.
  #
  # At the server contract an adapter's key acts as the role `adapter_key`
  # (`Apiary.Access.role/1`), with a scope of no organisation and no workspace
  # (`Apiary.Accounts.Scope.for_access_key/1`): `for_key/2` is the adapter such a scope
  # stands for, once the action is allowed.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Accounts, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  ## Who may

  @doc false
  # Whether the person of `scope` may change the instance's adapters, their keys and their
  # codes: `:ok` for an instance admin (`Apiary.Access.instance_admin?/1`) on an instance
  # with the feature `factory`; `{:error, :not_found}` where the feature is off, whoever
  # asks; `{:error, :forbidden}` for anyone else. With `sudo: true`, an instance admin who
  # did not sign in recently (`Apiary.Accounts.sudo_mode?/2`) is `{:error, :sudo}`, and
  # signs in again first.
  @spec authorize_instance(Scope.t() | nil, keyword) ::
          :ok | {:error, :not_found | :forbidden | :sudo}
  def authorize_instance(scope, opts \\ []) do
    cond do
      not Features.on?(:factory) -> {:error, :not_found}
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
  # where the feature is on.
  defp readable?(scope),
    do:
      Access.can?(scope, :"adapter.read", scope.organisation) or
        authorize_instance(scope) == :ok

  @doc false
  # The adapters a node pool of the scope's organisation may name as the one that serves
  # it: none. A pool is served by an adapter of its organisation
  # (`nodes_served_by_is_an_adapter`), and an adapter has no organisation.
  @spec serving_choices(Scope.t()) :: [Node.t()]
  def serving_choices(%Scope{}), do: []

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
  # owners and admins, asked of the organisation): `issue`, given the adapter as it is now,
  # in use and held `FOR SHARE`, makes what the person is sent to the adapter with,
  # `{:ok, pass}`, which the entry never holds. The entry is the organisation's, about the
  # organisation, naming the adapter. `{:ok, pass}`, `{:error, :forbidden}`,
  # `{:error, :not_found}`, or the `{:error, reason}` of `issue`, with no entry.
  @spec connect(Scope.t(), Node.t(), (Node.t() -> {:ok, term} | {:error, term})) ::
          {:ok, term} | {:error, term}
  def connect(%Scope{} = scope, %Node{id: id}, issue) when is_function(issue, 1) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"adapter.connect", scope.organisation),
           %Node{} = current <-
             live_query() |> where([n], n.id == ^id) |> lock("FOR SHARE") |> Repo.one() ||
               {:error, :not_found},
           {:ok, pass} <- issue.(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"adapter.connect", scope.organisation, %{
               details: Map.take(current, [:name, :public_id])
             }) do
        {:ok, pass}
      end
    end)
  end

  @doc false
  # Deletes `adapter` (`adapter.delete`, an instance admin): it leaves every page, its name
  # is free again, and its row stays for what names it. In the same transaction its keys in
  # use are revoked and its outstanding codes cancelled
  # (`Apiary.AccessKeys.revoke_node_keys/3`, each key with its entry of
  # `access_key.revoke`), and every pool it served is served by none, which the entry
  # records (`unserved_pool_ids`, their public ids). `{:ok, adapter}`,
  # `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec delete_adapter(Scope.t(), Node.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def delete_adapter(%Scope{} = scope, %Node{} = adapter) do
    mutate(scope, adapter, fn recorder, current ->
      now = DateTime.utc_now()

      with {:ok, key_ids} <- AccessKeys.revoke_node_keys(recorder, current, :node_deleted),
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
  defp mutate(scope, %Node{id: id}, fun) do
    Repo.transact(fn ->
      with :ok <- authorize_instance(scope),
           {:ok, recorder} <- instance_scope(scope),
           %Node{} = current <-
             live_query() |> where([n], n.id == ^id) |> lock("FOR UPDATE") |> Repo.one() ||
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
