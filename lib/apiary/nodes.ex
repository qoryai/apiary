defmodule Apiary.Nodes do
  @moduledoc """
  Nodes holds a workspace's nodes and node pools (`Apiary.Nodes.Node`), the places its
  runs run: a **node** is one permanent machine, which runs one instance at a time; a
  **node pool** is a fleet of short-lived instances, which run up to its instance limit,
  or any number when it has none. The kind is chosen when one is made and never changes.

  Every function takes an `Apiary.Accounts.Scope` with a workspace first and reads or
  changes only that workspace's nodes, in its organisation: a node of another workspace
  is not found. A node is named by its public id (`nd_…` or `np_…`), the id its page's
  path carries. A deleted node is gone from every read here.

  Making, changing and deleting a node are owners' and admins' (`node.create`,
  `node.edit`, `node.delete`); everyone in the workspace reads them (`node.read`, asked by
  the pages). A node's access keys are `Apiary.AccessKeys`'s; deleting a node revokes them. Each change asks `Apiary.Access.authorize/3` first and leaves its audit
  entry (`Apiary.Audit`) in its transaction: the name, kind, public id and limit of a new
  node, the name and limit an edit changed, a deletion's time.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc "What a list of nodes is narrowed by: `q`, words of a name or an id; `kind`."
  @type filters :: %{optional(:q) => String.t() | nil, optional(:kind) => Node.kind() | nil}

  ## Reads

  @doc """
  list_nodes/2 is the workspace's nodes in use, by name, narrowed by `filters`
  (`t:filters/0`): `q` matches a name or a public id, without regard to case; `kind`
  keeps one kind.
  """
  @spec list_nodes(Scope.t(), filters) :: [Node.t()]
  def list_nodes(%Scope{} = scope, filters \\ %{}) do
    scope
    |> live_query()
    |> narrow(filters)
    |> order_by([n], asc: n.name, asc: n.id)
    |> Repo.all()
  end

  defp narrow(query, filters) do
    Enum.reduce(filters, query, fn
      {:q, q}, query when is_binary(q) and q != "" ->
        like = "%" <> escape_like(String.trim(q)) <> "%"
        where(query, [n], ilike(n.name, ^like) or ilike(n.public_id, ^like))

      {:kind, kind}, query when kind in [:node, :pool] ->
        where(query, [n], n.kind == ^kind)

      _other, query ->
        query
    end)
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/u, "\\\\\\0")

  @doc """
  count_nodes/1 is how many nodes in use the workspace has, by kind:
  `%{node: n, pool: n}`.
  """
  @spec count_nodes(Scope.t()) :: %{node: non_neg_integer, pool: non_neg_integer}
  def count_nodes(%Scope{} = scope) do
    counts =
      scope
      |> live_query()
      |> group_by([n], n.kind)
      |> select([n], {n.kind, count(n.id)})
      |> Repo.all()
      |> Map.new()

    %{node: Map.get(counts, :node, 0), pool: Map.get(counts, :pool, 0)}
  end

  @doc """
  get_node/2 is the workspace's node in use whose public id is `public_id`, with the
  account that made it (`created_by`), or nil for one that is deleted, of another
  workspace, or none.
  """
  @spec get_node(Scope.t(), String.t()) :: Node.t() | nil
  def get_node(%Scope{} = scope, public_id) when is_binary(public_id) do
    scope
    |> live_query()
    |> where([n], n.public_id == ^public_id)
    |> preload(:created_by)
    |> Repo.one()
  end

  def get_node(%Scope{}, _public_id), do: nil

  # The scope's workspace's nodes in use.
  defp live_query(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: is_nil(n.deleted_at)
  end

  ## Changes

  @doc """
  new_node/1 is a node of `kind` not yet made, for the form that makes one: a node's
  limit is 1, a pool's none.
  """
  @spec new_node(Node.kind()) :: Node.t()
  def new_node(:node), do: %Node{kind: :node, instance_limit: 1}
  def new_node(:pool), do: %Node{kind: :pool, instance_limit: nil}

  @doc """
  change_new_node/2 is the changeset of `node`, from `new_node/1`, made with `attrs`, for
  the form that makes one: its kind stays the one it was given.
  """
  @spec change_new_node(Node.t(), map) :: Ecto.Changeset.t()
  def change_new_node(%Node{kind: kind} = node, attrs \\ %{}),
    do: Node.create_changeset(node, Map.put(stringify(attrs), "kind", kind))

  @doc "change_node/2 is the changeset of an edit of `node`'s name and limit."
  @spec change_node(Node.t(), map) :: Ecto.Changeset.t()
  def change_node(%Node{} = node, attrs \\ %{}), do: Node.changeset(node, attrs)

  @doc """
  create_node/2 makes a node of the scope's workspace (`node.create`, owners and
  admins) from `attrs`: its `kind`, `node` or `pool`, which is fixed from then on, its
  `name`, and a pool's `instance_limit`, empty for none. `{:ok, node}`, `{:error,
  changeset}`, or `{:error, :forbidden}` for one who may not, `{:error, :not_found}` where
  the workspace is out of their reach.
  """
  @spec create_node(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_node(
        %Scope{
          user: user,
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id} = workspace
        } = scope,
        attrs
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"node.create", workspace),
           {:ok, node} <-
             %Node{
               organisation_id: organisation_id,
               workspace_id: workspace_id,
               created_by_id: user.id
             }
             |> Node.create_changeset(attrs)
             |> Repo.insert(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"node.create", node, %{
               after: Map.take(node, [:name, :kind, :public_id, :instance_limit])
             }) do
        {:ok, node}
      end
    end)
  end

  @doc """
  update_node/3 renames `node`, and changes a pool's instance limit (`node.edit`, owners
  and admins), from `attrs`; its kind stays. Lowering a pool's limit stops none of its
  instances. `{:ok, node}`, `{:error, changeset}`, `{:error, :forbidden}`, or
  `{:error, :not_found}` for a node that is deleted or not the workspace's.
  """
  @spec update_node(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def update_node(%Scope{} = scope, %Node{} = node, attrs) do
    mutate(scope, :"node.edit", node, fn current ->
      with {:ok, updated} <- current |> Node.changeset(attrs) |> Repo.update(),
           :ok <- record_edit(scope, current, updated) do
        {:ok, updated}
      end
    end)
  end

  @doc """
  delete_node/2 deletes `node` (`node.delete`, owners and admins): it leaves every page,
  its name is free again, and its row stays for what names it until its workspace is
  purged. In the same transaction it revokes every key of the node in use, a key awaiting
  approval among them, each with its entry of `access_key.revoke` and its public key a
  tombstone for `node_deleted`, and cancels its outstanding enrolment codes
  (`Apiary.AccessKeys.revoke_node_keys/3`). `{:ok, node}`, `{:error, :forbidden}`, or
  `{:error, :not_found}` for a node that is deleted already or not the workspace's.
  """
  @spec delete_node(Scope.t(), Node.t()) :: {:ok, Node.t()} | {:error, Access.reason()}
  def delete_node(%Scope{user: user} = scope, %Node{} = node) do
    mutate(scope, :"node.delete", node, fn current ->
      with {:ok, key_ids} <- AccessKeys.revoke_node_keys(scope, current, :node_deleted),
           {:ok, deleted} <-
             current
             |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(), deleted_by_id: user.id)
             |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"node.delete", deleted, %{
               before: %{deleted_at: nil},
               after: %{deleted_at: deleted.deleted_at},
               details:
                 deleted
                 |> Map.take([:name, :kind, :public_id])
                 |> Map.put(:revoked_key_ids, key_ids)
             }) do
        {:ok, deleted}
      end
    end)
  end

  # Asks `action` of the caller's membership as it is now, then hands `fun` the node as
  # it is now, in use and the scope's workspace's, locked for the rest of the
  # transaction.
  defp mutate(scope, action, %Node{id: id} = node, fun) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, action, node),
           %Node{} = current <-
             scope |> live_query() |> where([n], n.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
        fun.(current)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # The entry of an edit, when it changed the name or the limit; an edit that changed
  # nothing has nothing to record.
  defp record_edit(scope, old, new) do
    case Audit.changed(old, new, [:name, :instance_limit]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"node.edit", new, changes), do: :ok
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
