defmodule Apiary.Nodes do
  @moduledoc """
  Nodes holds a workspace's nodes and node pools (`Apiary.Nodes.Node`), the places its
  runs run: a **node** is one permanent machine, which runs one instance at a time; a
  **node pool** is a fleet of short-lived instances, which run up to its instance limit,
  or any number when it has none. It holds its **gateways** too, the third kind, which
  the others may record as their choice of gateway (`Apiary.Gateways`). The kind is
  chosen when one is made and never changes.

  Every function a page calls takes an `Apiary.Accounts.Scope` with a workspace first and
  reads or changes only that workspace's nodes, in its organisation: a node of another
  workspace is not found. A node is named by its public id (`nd_…`, `np_…` or `ng_…`), the id its
  page's path carries. A deleted node is gone from every read here. The receiving side's
  functions (`seen/3`, `placement/2`, `check_instance_limit/3`, `admit/4`) take the node
  a verified access key names instead, and the retention job's (`prune_instances/1`)
  none.

  Making, changing and deleting a node, and clearing an instance, are owners' and admins'
  (`node.create`, `node.edit`, `node.delete`, `node.clear_instance`), and so is setting a
  pool's instance limit, as it is made or after, a separate action (`node.set_limit`)
  that an edition may keep from some who change the rest; everyone in the workspace reads
  them (`node.read`, asked by the pages). A node's access keys are
  `Apiary.AccessKeys`'s; deleting a node revokes them. Each change asks
  `Apiary.Access.authorize/3` first and leaves its audit entry (`Apiary.Audit`) in its
  transaction: the name, kind, public id and limit of a new node, with a node's or a
  pool's choice of gateway and a gateway's address and default mark; what an edit
  changed; a deletion's time; the instance a clearing cleared.

  **Gateways.** A gateway is made, changed and deleted as a node is, under the same
  actions. It lives at a workspace, or at an organisation, with no workspace
  (`Apiary.Gateways`): an organisation's gateways are listed, made and read through
  `list_organisation_gateways/1`, `create_organisation_gateway/2` and
  `get_organisation_gateway/2`, with a scope of the organisation, and asked of
  `Apiary.Access` at the organisation's place; `update_node/3`, `make_default_gateway/2`
  and `delete_node/2` take either. A node's or a pool's choice of gateway is saved with
  it; given none, a new one starts on `:default` when a default resolves for the
  workspace, and on `:direct` otherwise. `:named` must name one of
  `Apiary.Gateways.gateway_choices/1`, and `:default` needs a default that resolves for
  the workspace. A gateway made when no default resolves for it at its level or after
  (`Apiary.Gateways.default_resolves?/1`) becomes its level's default;
  `make_default_gateway/2` moves the mark. A gateway is deleted only when nothing points
  to it and no run through it is live or waiting (`Apiary.Gateways.delete_blockers/1`),
  and the deletion then marks the oldest gateway left at its level as the default when a
  workspace it served resolves none any more. Each of these takes the gateways' locks
  first (`Apiary.Gateways.lock/1`), and a mark that moves leaves an entry of `node.edit`
  for each gateway it moved on or off.

  **Instances.** An instance is what Forager, under a node's access key, reports itself as
  (`Apiary.Nodes.Instance`): a claim, for display, the audit and the instance limit, never
  for authorisation. `seen/3` records one when a request is verified and broadcasts
  `{:nodes_touched, workspace_id}` (`topic/1`). An instance is **running** while it has a
  run alive by the lost-run check's rule (`Apiary.Runs.Liveness.alive/2`), so running
  means "not yet lost", and a node runs while any of its instances does (`activity/3`).
  `check_instance_limit/3` and `admit/4` hold a node to its instance limit when a
  registration would create a run, under the node's row lock; `clear_instance/3` marks an instance's
  open runs lost, for one that stopped without saying so; `prune_instances/1` deletes the
  rows the pages no longer show.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Audit, Gateways, PublicId, Repo, Runs}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Dispatches.Slots
  alias Apiary.Nodes.{Instance, Node, Throttle}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Liveness, Run}

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

      {:kind, kind}, query when kind in [:node, :pool, :gateway] ->
        where(query, [n], n.kind == ^kind)

      _other, query ->
        query
    end)
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/u, "\\\\\\0")

  @doc """
  count_nodes/1 is how many nodes in use the workspace has, by kind:
  `%{node: n, pool: n, gateway: n}`.
  """
  @spec count_nodes(Scope.t()) :: %{
          node: non_neg_integer,
          pool: non_neg_integer,
          gateway: non_neg_integer
        }
  def count_nodes(%Scope{} = scope) do
    counts =
      scope
      |> live_query()
      |> group_by([n], n.kind)
      |> select([n], {n.kind, count(n.id)})
      |> Repo.all()
      |> Map.new()

    %{
      node: Map.get(counts, :node, 0),
      pool: Map.get(counts, :pool, 0),
      gateway: Map.get(counts, :gateway, 0)
    }
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

  # The scope's organisation's gateways in use, those with no workspace.
  defp organisation_query(%Scope{organisation: %Organisation{id: organisation_id}}) do
    from n in Node,
      where: n.organisation_id == ^organisation_id and is_nil(n.workspace_id),
      where: n.kind == :gateway and is_nil(n.deleted_at)
  end

  # The nodes in use at the place of `node`, of the scope: its workspace's, the scope's,
  # or its organisation's gateways.
  defp place_query(scope, %Node{workspace_id: nil}), do: organisation_query(scope)
  defp place_query(scope, %Node{}), do: live_query(scope)

  @doc """
  list_organisation_gateways/1 is the scope's organisation's gateways in use, those that
  live at the organisation, by name.
  """
  @spec list_organisation_gateways(Scope.t()) :: [Node.t()]
  def list_organisation_gateways(%Scope{} = scope) do
    scope
    |> organisation_query()
    |> order_by([n], asc: n.name, asc: n.id)
    |> Repo.all()
  end

  @doc """
  get_organisation_gateway/2 is the scope's organisation's gateway in use whose public id
  is `public_id`, with the account that made it (`created_by`), or nil for one that is
  deleted, of a workspace, of another organisation, or none.
  """
  @spec get_organisation_gateway(Scope.t(), String.t()) :: Node.t() | nil
  def get_organisation_gateway(%Scope{} = scope, public_id) when is_binary(public_id) do
    scope
    |> organisation_query()
    |> where([n], n.public_id == ^public_id)
    |> preload(:created_by)
    |> Repo.one()
  end

  def get_organisation_gateway(%Scope{}, _public_id), do: nil

  @doc """
  list_serving_gateways/2 is the organisation-level gateways in use that may serve the
  scope's workspace (`Apiary.Gateways.may_serve?/2`): its organisation's, then those of
  the organisations that serve it, as `Apiary.Gateways.gateway_choices/1` orders them,
  narrowed by `filters` as `list_nodes/2` narrows the workspace's nodes.
  """
  @spec list_serving_gateways(Scope.t(), filters) :: [Node.t()]
  def list_serving_gateways(%Scope{} = scope, filters \\ %{}) do
    gateways = scope |> Gateways.gateway_choices() |> Enum.filter(&is_nil(&1.workspace_id))

    if gateways == [] or Map.get(filters, :kind) not in [nil, :gateway] do
      []
    else
      matching =
        from(n in Node, where: n.id in ^Enum.map(gateways, & &1.id))
        |> narrow(Map.delete(filters, :kind))
        |> select([n], n.id)
        |> Repo.all()
        |> MapSet.new()

      Enum.filter(gateways, &MapSet.member?(matching, &1.id))
    end
  end

  ## Changes

  @doc """
  new_node/1 is a node of `kind` not yet made, for the form that makes one: a node's
  limit is 1, a pool's and a gateway's none.
  """
  @spec new_node(Node.kind()) :: Node.t()
  def new_node(:node), do: %Node{kind: :node, instance_limit: 1}
  def new_node(:pool), do: %Node{kind: :pool, instance_limit: nil}
  def new_node(:gateway), do: %Node{kind: :gateway, instance_limit: nil}

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
  admins) from `attrs`: its `kind`, `node`, `pool` or `gateway`, which is fixed from then
  on, its `name`, a pool's `instance_limit`, empty for none, which a limit given asks of
  `node.set_limit` too: one who may not set it makes a pool whose limit is 1; a gateway's
  `url`, and a node's or a pool's `gateway_choice` (`named` with its `gateway_id`). A node
  or a pool given no choice starts on `default` when a default gateway resolves for the
  workspace, and on `direct` otherwise. A gateway made when no default gateway resolves
  for the workspace is made its default. `{:ok, node}`, `{:error, changeset}`, or
  `{:error, :forbidden}` for
  one who may not, `{:error, :not_found}` where the workspace is out of their reach.

  It takes the gateways' locks of the workspace first (`Apiary.Gateways.lock/1`).
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
      with :ok <- Gateways.lock(workspace),
           asking = Access.reload(scope),
           :ok <- Access.check(asking, :"node.create", workspace),
           changeset =
             %Node{
               organisation_id: organisation_id,
               workspace_id: workspace_id,
               created_by_id: user.id
             }
             |> Node.create_changeset(attrs)
             |> made_here()
             |> put_first_choice(attrs, workspace)
             |> validate_gateway(scope),
           {:ok, changeset} <- limit_set(asking, changeset, workspace),
           {:ok, node} <- PublicId.Insert.insert(changeset),
           {:ok, node} <- default_if_none(node, workspace),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"node.create", node, %{after: created(node)}) do
        {:ok, node}
      end
    end)
  end

  # A node, a node pool or a gateway is made here; an adapter, which is the instance's, is
  # made through `Apiary.Adapters` alone.
  defp made_here(changeset),
    do: Ecto.Changeset.validate_inclusion(changeset, :kind, Node.all_kinds())

  # A new node or pool given no choice: the default when one resolves, else direct.
  defp put_first_choice(changeset, attrs, workspace) do
    given? = Map.has_key?(attrs, :gateway_choice) or Map.has_key?(attrs, "gateway_choice")

    if Ecto.Changeset.get_field(changeset, :kind) in Node.kinds() and not given? and
         Gateways.default_gateway_for(workspace) != nil,
       do: Ecto.Changeset.put_change(changeset, :gateway_choice, :default),
       else: changeset
  end

  # What the entry of a new node records of it.
  defp created(%Node{kind: :gateway} = node),
    do: Map.take(node, [:name, :kind, :public_id, :instance_limit, :url, :default_gateway])

  defp created(%Node{} = node) do
    fields = [:name, :kind, :public_id, :instance_limit, :gateway_choice]
    fields = if node.gateway_choice == :named, do: fields ++ [:gateway_id], else: fields
    Map.take(node, fields)
  end

  # A new gateway is its level's default when no default resolves for it at its level or
  # after it (`Apiary.Gateways.default_resolves?/1`).
  defp default_if_none(%Node{kind: :gateway} = gateway, workspace) do
    level =
      case Gateways.level(gateway) do
        {:workspace, _id} -> {:workspace, workspace}
        organisation -> organisation
      end

    if Gateways.default_resolves?(level),
      do: {:ok, gateway},
      else: gateway |> Node.default_changeset(true) |> Repo.update()
  end

  defp default_if_none(node, _workspace), do: {:ok, node}

  @doc """
  create_organisation_gateway/2 makes a gateway of the scope's organisation, one that
  lives at the organisation with no workspace (`node.create`, asked of the organisation:
  owners and admins in the core), from `attrs`, its `name` and `url`. It is made its
  organisation's default when no default resolves for it
  (`Apiary.Gateways.default_resolves?/1`). It takes the organisation's gateways' locks
  first (`Apiary.Gateways.lock/1`). `{:ok, gateway}`, `{:error, changeset}`,
  `{:error, :forbidden}`, or `{:error, :not_found}` for an organisation out of reach.
  """
  @spec create_organisation_gateway(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_organisation_gateway(
        %Scope{user: user, organisation: %Organisation{id: organisation_id} = organisation} =
          scope,
        attrs
      ) do
    Repo.transact(fn ->
      with :ok <- Gateways.lock({:organisation, organisation_id}),
           asking = Access.reload(scope),
           :ok <- Access.check(asking, :"node.create", organisation),
           changeset =
             Node.create_changeset(
               %Node{organisation_id: organisation_id, workspace_id: nil, created_by_id: user.id},
               Map.put(stringify(attrs), "kind", :gateway)
             ),
           {:ok, gateway} <- PublicId.Insert.insert(changeset),
           {:ok, gateway} <- default_if_none(gateway, nil),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"node.create", gateway, %{after: created(gateway)}) do
        {:ok, gateway}
      end
    end)
  end

  @doc """
  change_new_organisation_gateway/1 is the changeset of an organisation's gateway not yet
  made, for the form that makes one.
  """
  @spec change_new_organisation_gateway(map) :: Ecto.Changeset.t()
  def change_new_organisation_gateway(attrs \\ %{}),
    do:
      Node.create_changeset(
        %Node{kind: :gateway, instance_limit: nil},
        Map.put(stringify(attrs), "kind", :gateway)
      )

  # A node's or a pool's choice, when it changes, against the gateways as they are, under
  # the workspace's gateway lock: a gateway it names must be one it may name, and a
  # default must resolve.
  defp validate_gateway(%Ecto.Changeset{valid?: true} = changeset, scope) do
    choice = Ecto.Changeset.get_field(changeset, :gateway_choice)
    changed? = Ecto.Changeset.changed?(changeset, :gateway_choice)

    cond do
      choice == :named and Ecto.Changeset.changed?(changeset, :gateway_id) ->
        id = Ecto.Changeset.get_field(changeset, :gateway_id)

        if Enum.any?(Gateways.gateway_choices(scope), &(&1.id == id)),
          do: changeset,
          else:
            Ecto.Changeset.add_error(
              changeset,
              :gateway_id,
              dgettext_noop("errors", "is not a gateway this node may use")
            )

      choice == :default and changed? and is_nil(Gateways.default_gateway_for(scope.workspace)) ->
        Ecto.Changeset.add_error(
          changeset,
          :gateway_choice,
          dgettext_noop("errors", "has no default gateway")
        )

      true ->
        changeset
    end
  end

  defp validate_gateway(changeset, _scope), do: changeset

  @doc """
  update_node/3 renames `node`, and changes a gateway's `url` or a node's or a pool's
  choice of gateway (`node.edit`), and a pool's instance limit (`node.set_limit`), from
  `attrs`, each asked of what the edit changes: owners and admins, in the core; its kind
  stays. An edit that changes nothing asks `node.edit`. Lowering a pool's limit stops none
  of its instances. `{:ok, node}`, `{:error, changeset}`, `{:error, :forbidden}`, or
  `{:error, :not_found}` for a node that is deleted or not the workspace's.
  """
  @spec update_node(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def update_node(scope, node, attrs)

  # An adapter is changed through `Apiary.Adapters` alone.
  def update_node(%Scope{}, %Node{kind: :adapter}, _attrs), do: {:error, :not_found}

  def update_node(%Scope{} = scope, %Node{} = node, attrs) do
    Repo.transact(fn ->
      with :ok <- Gateways.lock_for(scope, node),
           asking = Access.reload(scope),
           :ok <- may_change(asking, node),
           %Node{} = current <- lock_node(scope, node) || {:error, :not_found},
           changeset =
             current
             |> Node.changeset(attrs)
             |> validate_gateway(scope),
           :ok <- check_each(asking, edit_actions(changeset), current),
           {:ok, updated} <- Repo.update(changeset),
           :ok <- record_edit(scope, current, updated) do
        {:ok, updated}
      end
    end)
  end

  @doc """
  make_default_gateway/2 marks `gateway` as its level's default gateway, its workspace's or
  its organisation's (`node.edit`,
  owners and admins), and takes the mark off the gateway that held it, each change with
  its entry. The nodes on `:default` resolve to it from then on (`Apiary.Gateways.resolve/1`).
  `{:ok, gateway}`, unchanged when it was the default already; `{:error, changeset}` when
  the database refuses the mark; `{:error, :forbidden}`; or
  `{:error, :not_found}` for a gateway that is deleted, not of the scope's workspace or
  organisation, or a node that is not a gateway.
  """
  @spec make_default_gateway(Scope.t(), Node.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def make_default_gateway(scope, gateway)

  def make_default_gateway(%Scope{}, %Node{kind: :adapter}), do: {:error, :not_found}

  def make_default_gateway(%Scope{} = scope, %Node{} = gateway) do
    gateway_mutate(scope, :"node.edit", gateway, fn
      %Node{kind: :gateway, default_gateway: true} = current ->
        {:ok, current}

      %Node{kind: :gateway} = current ->
        level = Gateways.level(current)

        with {:ok, _previous} <- unmark(scope, Gateways.default_at(level, scope.workspace)),
             do: mark(scope, current)

      %Node{} ->
        {:error, :not_found}
    end)
  end

  defp unmark(_scope, nil), do: {:ok, nil}
  defp unmark(scope, %Node{} = gateway), do: set_default(scope, gateway, false)

  defp mark(scope, %Node{} = gateway), do: set_default(scope, gateway, true)

  defp set_default(scope, gateway, default?) do
    with {:ok, updated} <-
           gateway |> Node.default_changeset(default?) |> Repo.update(),
         :ok <- record_edit(scope, gateway, updated) do
      {:ok, updated}
    end
  end

  @doc """
  delete_node/2 deletes `node` (`node.delete`, owners and admins): it leaves every page,
  its name is free again, and its row stays for what names it until its workspace is
  purged. In the same transaction it revokes every key of the node in use, each with its entry of `access_key.revoke` and its public key a
  tombstone for `node_deleted`, and cancels its outstanding enrolment codes
  (`Apiary.AccessKeys.revoke_node_keys/3`). `{:ok, node}`, `{:error, :forbidden}`, or
  `{:error, :not_found}` for a node that is deleted already or not the workspace's.

  A gateway, at a workspace or at the organisation, is deleted only when nothing points to
  it and no run through it is live or waiting: otherwise
  `{:error, {:gateway_in_use, blockers}}`, which names the nodes, wherever they are, and
  the runs (`Apiary.Gateways.delete_blockers/1`), and nothing changes. The runs are read
  with the gateway's row held `FOR UPDATE`, so a registration through it or an attach by
  it that commits first is among them, and one that commits after finds it deleted. A
  deleted gateway loses its default mark; when a workspace it served resolves no default
  any more and gateways remain at its level, the oldest of them becomes the level's
  default (`Apiary.Gateways.needs_default_after_deletion?/1`), with its entry of
  `node.edit`. No node moves.
  `{:error, changeset}` when the database refuses that mark, and nothing changes.
  """
  @spec delete_node(Scope.t(), Node.t()) ::
          {:ok, Node.t()}
          | {:error,
             Ecto.Changeset.t() | Access.reason() | {:gateway_in_use, Gateways.blockers()}}
  def delete_node(scope, node)

  # An adapter is deleted through `Apiary.Adapters` alone.
  def delete_node(%Scope{}, %Node{kind: :adapter}), do: {:error, :not_found}

  def delete_node(%Scope{user: user} = scope, %Node{} = node) do
    gateway_mutate(scope, :"node.delete", node, fn current ->
      with :ok <- unblocked(current),
           {:ok, key_ids} <- AccessKeys.revoke_node_keys(scope, current, :node_deleted),
           {:ok, deleted} <-
             current
             |> Ecto.Changeset.change(
               deleted_at: DateTime.utc_now(),
               deleted_by_id: user.id,
               default_gateway: false
             )
             |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"node.delete", deleted, %{
               before: %{deleted_at: nil},
               after: %{deleted_at: deleted.deleted_at},
               details:
                 deleted
                 |> Map.take([:name, :kind, :public_id])
                 |> Map.put(:revoked_key_ids, key_ids)
                 |> put_default_gateway(current)
             }),
           :ok <- default_after_deletion(scope, current) do
        {:ok, deleted}
      end
    end)
  end

  # Under the gateway's row, held `FOR UPDATE` by `mutate/4`.
  defp unblocked(%Node{kind: :gateway} = gateway) do
    case Gateways.delete_blockers(gateway) do
      %{nodes: [], runs: []} -> :ok
      blockers -> {:error, {:gateway_in_use, blockers}}
    end
  end

  defp unblocked(%Node{}), do: :ok

  defp put_default_gateway(details, %Node{kind: :gateway, default_gateway: default?}),
    do: Map.put(details, :default_gateway, default?)

  defp put_default_gateway(details, %Node{}), do: details

  # After a gateway's deletion, when a workspace it served resolves no default any more,
  # the oldest gateway left at its level becomes the level's default, if there is one.
  defp default_after_deletion(scope, %Node{kind: :gateway} = gateway) do
    level = Gateways.level(gateway)
    workspace = level_workspace(level)

    with true <- Gateways.needs_default_after_deletion?(gateway),
         %Node{} = oldest <- Gateways.oldest_at(level, workspace),
         {:ok, _marked} <- mark(scope, oldest) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _resolved_or_none -> :ok
    end
  end

  defp default_after_deletion(_scope, %Node{}), do: :ok

  defp level_workspace({:workspace, id}), do: Repo.get(Workspace, id)
  defp level_workspace({:organisation, _id}), do: nil
  defp level_workspace(:instance), do: nil

  # `mutate/4` under the gateways' locks of the node's place, taken first, before the
  # node's row (`Apiary.Gateways.lock_for/2`).
  defp gateway_mutate(%Scope{} = scope, action, node, fun) do
    Repo.transact(fn ->
      with :ok <- Gateways.lock_for(scope, node), do: mutate(scope, action, node, fun)
    end)
  end

  # Asks `action` of the caller's membership as it is now, then hands `fun` the node as
  # it is now, in use and the scope's workspace's, or the organisation's for an
  # organisation-level gateway, locked for the rest of the transaction.
  defp mutate(scope, action, %Node{} = node, fun) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, action, node),
           %Node{} = current <- lock_node(scope, node) do
        fun.(current)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # The node as it is now, in use at its place of the scope, locked for the rest of the
  # transaction; nil for none.
  defp lock_node(scope, %Node{id: id} = node),
    do:
      scope
      |> place_query(node)
      |> where([n], n.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  # Whether the person, as `reload/2` read them, may change something of `node`: its edit
  # or its limit. The answer of `node.edit` when they may neither.
  defp may_change(scope, node) do
    with {:error, _reason} = refused <- Access.check(scope, :"node.edit", node) do
      if Access.check(scope, :"node.set_limit", node) == :ok, do: :ok, else: refused
    end
  end

  # What an edit asks: `node.set_limit` for a change of the limit, `node.edit` for a change
  # of anything else, and for an edit that changes nothing.
  defp edit_actions(%Ecto.Changeset{changes: changes}) do
    limit = if Map.has_key?(changes, :instance_limit), do: [:"node.set_limit"], else: []
    rest = Map.delete(changes, :instance_limit)
    if rest == %{} and limit != [], do: limit, else: [:"node.edit" | limit]
  end

  # A new pool's limit, when one is given, asks `node.set_limit` too; a node's is 1,
  # whoever makes it.
  # A pool's limit as it is made: what one who may set it (`node.set_limit`) gives, none
  # when they give none; for one who may not, a limit given is refused, and the pool is
  # made with a limit of 1, which one who may set it raises.
  defp limit_set(scope, changeset, workspace) do
    with :pool <- Ecto.Changeset.get_field(changeset, :kind),
         {:error, :forbidden} <- Access.check(scope, :"node.set_limit", workspace) do
      if is_nil(Ecto.Changeset.get_change(changeset, :instance_limit)),
        do: {:ok, Ecto.Changeset.put_change(changeset, :instance_limit, 1)},
        else: {:error, :forbidden}
    else
      :ok -> {:ok, changeset}
      {:error, _reason} = refused -> refused
      _node -> {:ok, changeset}
    end
  end

  defp check_each(scope, actions, subject) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case Access.check(scope, action, subject) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  # The entry of an edit, when it changed the name, the limit, a gateway's address or
  # default mark, or a node's choice of gateway; an edit that changed nothing has nothing
  # to record.
  defp record_edit(scope, old, new) do
    case Audit.changed(old, new, [
           :name,
           :instance_limit,
           :url,
           :gateway_choice,
           :gateway_id,
           :default_gateway
         ]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"node.edit", new, changes), do: :ok
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  ## Instances

  # At most this many new instances of a node are recorded in a window of a day.
  @bound 256
  @day 86_400
  # A Node keeps its instances other than its latest this many days after they were last
  # seen; a pool keeps one a day after.
  @node_keeps_days 30
  @max_version 255

  @typedoc """
  What a request under a node's access key said of its instance: the `instance_id` it
  signed, and beside it the `name` it gave (unsigned), the key's row id, and Forager's
  and the contract's versions. Only `instance_id` is required.
  """
  @type claim :: %{
          required(:instance_id) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:access_key_id) => Ecto.UUID.t() | nil,
          optional(:forager_version) => String.t() | nil,
          optional(:contract_version) => pos_integer | nil
        }

  @typedoc """
  An instance running now, as the pages show it: its id and name, since when it runs (the
  start of its oldest run alive), its newest run alive (`run_public_id`, the run's
  `public_id`) and the Forager version that run reported. `row_id` is the id of its row
  in `node_instances`, nil when it has none (rows are bounded and pruned): a page
  addresses the instance by `row_id`, and one with no row by `run_public_id`, never by
  the node's instance id (`instance_id`).
  """
  @type running :: %{
          instance_id: String.t(),
          row_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          since: DateTime.t(),
          run_public_id: String.t(),
          forager_version: String.t() | nil
        }

  @typedoc """
  What a node is doing: its instances running now, oldest first, the instance seen last,
  running or not (nil when none was recorded, or every one was pruned), and when one of
  its keys, revoked ones too, was last used (nil when none was).
  """
  @type activity :: %{
          running: [running],
          last: Instance.t() | nil,
          used: DateTime.t() | nil
        }

  @doc """
  topic/1 is the topic of a workspace's nodes, or of an organisation's gateways, by the
  workspace's or the organisation's id: `{:nodes_touched, id}` whenever an instance of
  one of them was seen or cleared.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id), do: "nodes:" <> workspace_id

  @doc """
  subscribe/1 subscribes the caller to `topic/1` of the scope's workspace;
  `subscribe/2` with `:organisation`, of the scope's organisation's gateways.
  """
  @spec subscribe(Scope.t(), :workspace | :organisation) :: :ok | {:error, term}
  def subscribe(scope, place \\ :workspace)

  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}, :workspace),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))

  def subscribe(%Scope{organisation: %Organisation{id: organisation_id}}, :organisation),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(organisation_id))

  # Where a node's instances are announced: its workspace, an organisation-level
  # gateway's organisation, or `instance` for the instance's pool and gateway.
  defp place_id(%Node{workspace_id: nil, organisation_id: nil}), do: "instance"
  defp place_id(%Node{workspace_id: nil, organisation_id: organisation_id}), do: organisation_id
  defp place_id(%Node{workspace_id: workspace_id}), do: workspace_id

  defp broadcast_touched(workspace_id),
    do:
      Phoenix.PubSub.broadcast(Apiary.PubSub, topic(workspace_id), {:nodes_touched, workspace_id})

  @doc """
  seen/3 records that an instance of `node` was seen at `now`, from what a verified
  request said of it (`t:claim/0`): the instance's row is made, or its last time, name,
  key and versions are brought up to date, and `{:nodes_touched, workspace_id}` is
  broadcast (`topic/1`).

  It writes at most once per node and instance id in each fifteen seconds
  (`Apiary.Nodes.Throttle`), and records at most #{@bound} new instances of a node in a
  day: past that, nothing is inserted and the node's `instance_ids_over_bound` is counted
  instead. Two first sightings at once may each pass the count, so the bound is a ceiling
  that a burst can pass by a few. An instance id that cannot be kept
  (`Apiary.Nodes.Instance.instance_id?/1`) is ignored, and a name that does not match the
  pattern of a name is dropped. It never fails the request it is called from: whatever
  goes wrong is logged, by the exception's module alone, and it answers `:ok`.

  The receiving side calls it once a request has verified and its instance id has passed
  (`ApiaryWeb.Contract.SignedRequest`).
  """
  @spec seen(Node.t(), claim, DateTime.t()) :: :ok
  def seen(node, claim, now \\ DateTime.utc_now())

  def seen(%Node{} = node, %{instance_id: instance_id} = claim, %DateTime{} = now) do
    if Instance.instance_id?(instance_id) and Throttle.due?({node.id, instance_id}, now),
      do: record_seen(node, instance_id, claim, now)

    :ok
  rescue
    exception ->
      Logger.error("an instance could not be recorded: #{inspect(exception.__struct__)}")
      :ok
  end

  def seen(%Node{}, _claim, _now), do: :ok

  defp record_seen(node, instance_id, claim, now) do
    name = Instance.name(claim[:name])
    key = claim[:access_key_id]
    forager = version(claim[:forager_version])
    contract = contract(claim[:contract_version])

    {updated, _} =
      Repo.update_all(
        from(i in Instance,
          where: i.node_id == ^node.id and i.node_instance_id == ^instance_id,
          update: [
            set: [
              last_seen_at: fragment("GREATEST(?, ?)", i.last_seen_at, ^now),
              name: coalesce(type(^name, :string), i.name),
              access_key_id: coalesce(type(^key, :binary_id), i.access_key_id),
              last_forager_version: coalesce(type(^forager, :string), i.last_forager_version),
              last_contract_version: coalesce(type(^contract, :integer), i.last_contract_version)
            ]
          ]
        ),
        []
      )

    cond do
      updated == 1 ->
        :ok

      over_bound?(node, now) ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id),
          inc: [instance_ids_over_bound: 1],
          set: [instance_ids_over_bound_at: now]
        )

      true ->
        # A first sighting that another request recorded a moment before is that one's.
        Repo.insert_all(
          Instance,
          [
            %{
              id: Ecto.UUID.generate(),
              organisation_id: node.organisation_id,
              workspace_id: node.workspace_id,
              node_id: node.id,
              access_key_id: key,
              node_instance_id: instance_id,
              name: name,
              first_seen_at: now,
              last_seen_at: now,
              last_forager_version: forager,
              last_contract_version: contract
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:node_id, :node_instance_id]
        )
    end

    broadcast_touched(place_id(node))
  end

  defp over_bound?(node, now) do
    since = DateTime.add(now, -@day, :second)

    Repo.aggregate(
      from(i in Instance, where: i.node_id == ^node.id and i.first_seen_at > ^since),
      :count
    ) >= @bound
  end

  defp version(version) when is_binary(version) and version != "",
    do: String.slice(version, 0, @max_version)

  defp version(_version), do: nil

  defp contract(version) when is_integer(version) and version in 1..2_147_483_647, do: version
  defp contract(_version), do: nil

  @doc """
  placement/2 is what a run records of where it runs, `%{node_id:, node_instance_id:}`:
  the node of the access key its registration or first batch came with, and the instance
  id that request claimed, nil
  when it cannot be kept (`Apiary.Nodes.Instance.instance_id?/1`). The receiving side
  merges it into the run's row when it creates the run, and the instance id into the
  delivery's row (`Apiary.Runs.Ingest`).
  """
  @spec placement(Node.t() | nil, String.t() | nil) ::
          %{node_id: Ecto.UUID.t() | nil, node_instance_id: String.t() | nil}
  def placement(nil, _instance_id), do: %{node_id: nil, node_instance_id: nil}

  def placement(%Node{id: id}, instance_id),
    do: %{
      node_id: id,
      node_instance_id: if(Instance.instance_id?(instance_id), do: instance_id)
    }

  ## The instance limit

  @doc """
  check_instance_limit/3 says whether `instance_id` may start a run on `node` at `now`,
  inside the transaction of the batch that would create the run. A pool without a limit
  admits any, with neither a lock nor a count. Otherwise it locks the node's row
  `FOR UPDATE`, so two checks for one node take turns, reads the limit as it is now (1 for
  a Node), and counts what is in use on the node (`instances_in_use/2`): the distinct
  instance ids of its runs alive at `now` (`Apiary.Runs.Liveness.alive/2`):

  - `:already_counted` when `instance_id` is among those instance ids: it runs already,
    and a second run of it takes no slot;
  - `{:error, :instance_limit}` when they are as many as the limit or more: the caller
    rolls back and stores nothing;
  - `:ok` otherwise: the run the caller then creates, in the same transaction, is the
    reservation, and counts for the next check as soon as it commits.

  Only accepted runs count, so a refused instance never does; lowering a pool's limit
  stops none that run, and refuses new ones until fewer run. The lock comes before
  whatever the batch locks after it, the run's row among them. Raises outside a
  transaction. `admit/4` is the whole of it, with the refusal counted.
  """
  # With the `factory` feature, the runs alive counted are those that were not
  # dispatched, and the slots the node's claims hold count its
  # dispatched runs (`Apiary.Dispatches.Slots.held/1`).
  @spec check_instance_limit(Node.t(), String.t(), DateTime.t()) ::
          :ok | :already_counted | {:error, :instance_limit}
  def check_instance_limit(%Node{kind: :pool, instance_limit: nil}, _instance_id, _now),
    do: :ok

  def check_instance_limit(%Node{id: id} = node, instance_id, %DateTime{} = now) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "the instance limit is checked inside the batch's transaction")

    limit =
      Repo.one!(from n in Node, where: n.id == ^id, lock: "FOR UPDATE", select: n.instance_limit)

    running = running_instance_ids(node, now)

    cond do
      instance_id in running -> :already_counted
      is_nil(limit) -> :ok
      length(running) + Slots.held(id) >= limit -> {:error, :instance_limit}
      true -> :ok
    end
  end

  # instances_in_use/2 is what counts against the instance limit of `node` at `now`: the
  # distinct instance ids of its runs alive that were not dispatched, and the slots its
  # claims hold (`Apiary.Dispatches.Slots.held/1`), which count its dispatched runs. The
  # caller holds the node's row locked, as `check_instance_limit/3` does.
  @doc false
  @spec instances_in_use(Node.t(), DateTime.t()) :: non_neg_integer
  def instances_in_use(%Node{id: id} = node, %DateTime{} = now),
    do: length(running_instance_ids(node, now)) + Slots.held(id)

  # The distinct instance ids of the node's runs alive at `now` that were not dispatched,
  # read from the partial index on the runs alive by node and instance. A dispatched run
  # counts by the slot its dispatch holds, not here. The instance's pool runs in every
  # workspace it serves, so its runs are counted in all of them.
  defp running_instance_ids(%Node{id: id} = node, now) do
    from(r in Run,
      as: :run,
      where: r.node_id == ^id,
      where: ^in_node_workspace(node),
      where: not is_nil(r.node_instance_id) and is_nil(r.dispatch_run_id),
      distinct: true,
      select: r.node_instance_id
    )
    |> Liveness.alive(now)
    |> Repo.all()
  end

  @doc """
  admit/4 runs `fun`, the store that creates a run of `instance_id` on
  `node`, in one transaction with the instance limit's check (`check_instance_limit/3`)
  before it: `fun`'s answer when the instance is admitted, `{:ok, value}` or
  `{:error, reason}` (an error rolls the whole back); `{:error, :instance_limit}` when it
  is refused, after the transaction has rolled back with nothing stored, and then the
  node's `instance_limit_refused` is counted and `instance_limit_refused_at` set, in a
  separate statement. Raises inside a transaction: it is the store's transaction.

  The receiving side calls it for a run's registration (`Apiary.Runs.Registration`).
  """
  @spec admit(Node.t(), String.t(), (-> {:ok, value} | {:error, reason}), DateTime.t()) ::
          {:ok, value} | {:error, :instance_limit | reason}
        when value: term, reason: term
  def admit(%Node{} = node, instance_id, fun, now \\ DateTime.utc_now())
      when is_function(fun, 0) do
    if Repo.in_transaction?(),
      do: raise(ArgumentError, "admit/4 is the batch's transaction, not part of another")

    result =
      Repo.transact(fn ->
        case check_instance_limit(node, instance_id, now) do
          {:error, :instance_limit} -> {:error, :instance_limit}
          _admitted -> fun.()
        end
      end)

    with {:error, :instance_limit} <- result do
      Repo.update_all(from(n in Node, where: n.id == ^node.id),
        inc: [instance_limit_refused: 1],
        set: [instance_limit_refused_at: now]
      )

      result
    end
  end

  ## Clear instance

  @doc """
  clear_instance/3 clears the instance `instance_id` of `node` (`node.clear_instance`,
  owners and admins), for one that stopped without saying so: its open runs on the node,
  pending or running, are marked lost through the lost-run check's update
  (`Apiary.Runs.Liveness.mark/2`), so they no longer count against the instance limit and
  another instance can start at once; its row, when there is one, records who cleared it
  and when; and the change is audited, with how many runs it marked. Once committed, each
  run is broadcast as changed, and the workspace's nodes as touched.

  `lost` is not final: if the instance was in fact alive, its next heartbeat brings its
  run back, and it counts again from then on. `{:ok, %{instance_id:, instance:, runs:}}`,
  `instance` nil for an instance with runs and no row; `{:error, :not_found}` for an
  instance id the node has neither a row nor an open run of, or a node that is deleted or
  not the workspace's; `{:error, :forbidden}`.
  """
  @spec clear_instance(Scope.t(), Node.t(), String.t()) ::
          {:ok, %{instance_id: String.t(), instance: Instance.t() | nil, runs: [Run.t()]}}
          | {:error, Access.reason()}
  def clear_instance(%Scope{user: user} = scope, %Node{} = node, instance_id) do
    now = DateTime.utc_now()

    result =
      mutate(scope, :"node.clear_instance", node, fn current ->
        with true <- Instance.instance_id?(instance_id) || {:error, :not_found},
             runs = Liveness.mark(open_runs(current, instance_id), now),
             {_count, cleared} =
               Repo.update_all(
                 from(i in Instance,
                   where: i.node_id == ^current.id and i.node_instance_id == ^instance_id,
                   select: i
                 ),
                 set: [cleared_at: now, cleared_by_id: user.id]
               ),
             instance = List.first(cleared),
             true <- (runs != [] or not is_nil(instance)) || {:error, :not_found},
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"node.clear_instance", current, %{
                 details: %{
                   instance_id: instance_id,
                   name: instance && instance.name,
                   runs: length(runs)
                 }
               }) do
          {:ok, %{instance_id: instance_id, instance: instance, runs: runs}}
        end
      end)

    with {:ok, %{runs: runs}} <- result do
      Enum.each(runs, &Runs.broadcast_changed/1)
      broadcast_touched(place_id(node))
    end

    result
  end

  defp open_runs(%Node{id: id} = node, instance_id) do
    from r in Run,
      as: :run,
      where: r.node_id == ^id,
      where: ^in_node_workspace(node),
      where: r.node_instance_id == ^instance_id and r.state in ["pending", "running"]
  end

  # The runs, bound `:run`, of the node's workspace; of any workspace for a node with none,
  # the instance's pool.
  defp in_node_workspace(%Node{workspace_id: nil}), do: dynamic(true)

  defp in_node_workspace(%Node{workspace_id: workspace_id}),
    do: dynamic([run: r], r.workspace_id == ^workspace_id)

  ## Reading instances

  @doc """
  get_instance/3 is the instance `instance_id` of `node`, a node of the scope's workspace
  or a gateway of its organisation, or nil when the node has no row of it.
  """
  @spec get_instance(Scope.t(), Node.t() | Ecto.UUID.t(), String.t()) :: Instance.t() | nil
  def get_instance(scope, %Node{id: id, workspace_id: nil}, instance_id)
      when is_binary(instance_id),
      do: get_instance_at(scope, :organisation, id, instance_id)

  def get_instance(scope, %Node{id: id}, instance_id), do: get_instance(scope, id, instance_id)

  def get_instance(%Scope{} = scope, node_id, instance_id)
      when is_binary(node_id) and is_binary(instance_id) do
    get_instance_at(scope, nil, node_id, instance_id)
  end

  def get_instance(%Scope{}, _node_id, _instance_id), do: nil

  # Of a node of the scope's workspace, or, `place` `:organisation`, of one of the scope's
  # organisation's gateways.
  defp get_instance_at(scope, place, node_id, instance_id) do
    scope
    |> instances_query(place)
    |> where([i], i.node_id == ^node_id and i.node_instance_id == ^instance_id)
    |> Repo.one()
  end

  @doc """
  get_instance_by_id/3 is the instance of `node`, a node of the scope's workspace or a
  gateway of its organisation, whose row in `node_instances` has the id `id`: the id a
  page addresses an instance by. It takes only the 36-character text form of a UUID, in
  either case. nil for any other id (a 16-byte binary among them), and for a row of
  another node, workspace or organisation.
  """
  @spec get_instance_by_id(Scope.t(), Node.t(), term) :: Instance.t() | nil
  def get_instance_by_id(%Scope{} = scope, %Node{id: node_id} = node, id)
      when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        place = if is_nil(node.workspace_id), do: :organisation, else: nil

        scope
        |> instances_query(place)
        |> where([i], i.node_id == ^node_id and i.id == ^id)
        |> Repo.one()

      :error ->
        nil
    end
  end

  def get_instance_by_id(%Scope{}, %Node{}, _id), do: nil

  @doc """
  get_instance_run/3 is the open run, pending or running, of the scope's workspace whose
  `public_id` is `public_id`, a run of `node` that names its instance: the address of an
  instance with no row in `node_instances`. The page links its newest open run, and the
  address accepts any open run of that instance. nil for a malformed id, a run of another
  node or workspace, a run that names no instance, and one that has ended.
  """
  @spec get_instance_run(Scope.t(), Node.t(), term) :: Run.t() | nil
  def get_instance_run(
        %Scope{organisation: %Organisation{id: organisation_id}, workspace: %Workspace{id: ws}},
        %Node{id: node_id},
        public_id
      ) do
    if Run.public_id?(public_id) do
      Repo.one(
        from r in Run,
          where: r.organisation_id == ^organisation_id and r.workspace_id == ^ws,
          where: r.node_id == ^node_id and r.public_id == ^public_id,
          where: not is_nil(r.node_instance_id) and r.state in ["pending", "running"]
      )
    end
  end

  def get_instance_run(%Scope{}, %Node{}, _public_id), do: nil

  @doc """
  instance_of/2 is the row of the instance `run`, a run of the scope's workspace, ran as:
  nil for a run that names no node or no instance, and for an instance whose row was
  pruned or never recorded.
  """
  @spec instance_of(Scope.t(), Run.t()) :: Instance.t() | nil
  def instance_of(%Scope{} = scope, %Run{node_id: node_id, node_instance_id: instance_id})
      when is_binary(node_id) and is_binary(instance_id),
      do: get_instance(scope, node_id, instance_id)

  def instance_of(%Scope{}, %Run{}), do: nil

  @doc """
  activity/3 is what each of `nodes`, nodes the caller read under the scope (of its
  workspace, or gateways of its organisation or of one that serves it), is doing at `now`
  (`t:activity/0`), by node id: its instances running now, those with a run alive by the
  lost-run check's rule (`Apiary.Runs.Liveness.alive/2`), oldest first; the instance
  seen last; and when one of its keys was last used, which still says the node was seen
  once `prune_instances/1` has taken a pool's last instance. Four reads, whatever the
  number of nodes.
  """
  #
  # `:instance` in place of a scope reads the instance's pool and gateway, which have no
  # organisation: their instances, their keys, and the runs of the pool in every workspace
  # it served. Only a caller that checked the person is an instance admin shows all of it
  # (`Apiary.Nodes.Installed.activity/3`); a workspace's Nodes page takes from it only
  # when the nodes' keys were last used.
  @spec activity(Scope.t() | :instance, [Node.t()], DateTime.t()) :: %{Ecto.UUID.t() => activity}
  def activity(scope, nodes, now \\ DateTime.utc_now())

  def activity(_scope, [], _now), do: %{}

  def activity(scope, nodes, %DateTime{} = now)
      when is_struct(scope, Scope) or scope == :instance do
    ids = Enum.map(nodes, & &1.id)
    runs = alive_runs(scope, ids, now)

    last =
      from(i in Instance, where: ^of_scope(scope))
      |> where([i], i.node_id in ^ids)
      |> distinct([i], i.node_id)
      |> order_by([i], asc: i.node_id, desc: i.last_seen_at, desc: i.id)
      |> Repo.all()
      |> Map.new(&{&1.node_id, &1})

    used = keys_used(scope, ids)

    instance_ids = runs |> Enum.map(& &1.instance_id) |> Enum.uniq()

    rows =
      if instance_ids == [],
        do: %{},
        else:
          from(i in Instance, where: ^of_scope(scope))
          |> where([i], i.node_id in ^ids and i.node_instance_id in ^instance_ids)
          |> Repo.all()
          |> Map.new(&{{&1.node_id, &1.node_instance_id}, &1})

    running =
      runs
      |> Enum.group_by(&{&1.node_id, &1.instance_id})
      |> Enum.map(fn {{node_id, instance_id} = key, runs} ->
        newest = Enum.max_by(runs, & &1.since, DateTime)
        row = Map.get(rows, key)

        {node_id,
         %{
           instance_id: instance_id,
           row_id: row && row.id,
           name: row && row.name,
           since: runs |> Enum.map(& &1.since) |> Enum.min(DateTime),
           run_public_id: newest.public_id,
           forager_version: newest.forager_version || (row && row.last_forager_version)
         }}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(ids, fn id ->
      {id,
       %{
         running:
           running
           |> Map.get(id, [])
           |> Enum.sort_by(&{DateTime.to_unix(&1.since, :microsecond), &1.instance_id}),
         last: Map.get(last, id),
         used: Map.get(used, id)
       }}
    end)
  end

  # The rows of nodes the scope reads: of its workspace, of its organisation's own
  # gateways, and of the gateways of the organisations that serve it; for `:instance`,
  # those of no organisation.
  defp of_scope(:instance), do: dynamic([r], is_nil(r.organisation_id) and is_nil(r.workspace_id))

  defp of_scope(%Scope{organisation: %Organisation{id: organisation_id}, workspace: workspace}) do
    serving = Gateways.serving_organisations(organisation_id)

    own =
      case workspace do
        %Workspace{id: workspace_id} ->
          dynamic([r], is_nil(r.workspace_id) or r.workspace_id == ^workspace_id)

        nil ->
          dynamic([r], is_nil(r.workspace_id))
      end

    dynamic(
      [r],
      (r.organisation_id == ^organisation_id and ^own) or
        (r.organisation_id in ^serving and is_nil(r.workspace_id))
    )
  end

  # When each node's keys were last used, revoked keys too, by node id: a node none of
  # whose keys was used is not among them.
  defp keys_used(scope, ids) do
    from(k in AccessKey,
      where: ^of_scope(scope),
      where: k.node_id in ^ids and not is_nil(k.last_used_at),
      group_by: k.node_id,
      select: {k.node_id, max(k.last_used_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp alive_runs(%Scope{workspace: nil}, _ids, _now), do: []

  defp alive_runs(:instance, ids, now) do
    from(r in Run,
      as: :run,
      where: r.node_id in ^ids and not is_nil(r.node_instance_id),
      select: %{
        node_id: r.node_id,
        instance_id: r.node_instance_id,
        public_id: r.public_id,
        since: coalesce(r.started_at, r.inserted_at),
        forager_version: r.forager_version
      }
    )
    |> Liveness.alive(now)
    |> Repo.all()
  end

  defp alive_runs(%Scope{organisation: organisation, workspace: workspace}, ids, now) do
    from(r in Run,
      as: :run,
      where: r.organisation_id == ^organisation.id and r.workspace_id == ^workspace.id,
      where: r.node_id in ^ids and not is_nil(r.node_instance_id),
      select: %{
        node_id: r.node_id,
        instance_id: r.node_instance_id,
        public_id: r.public_id,
        since: coalesce(r.started_at, r.inserted_at),
        forager_version: r.forager_version
      }
    )
    |> Liveness.alive(now)
    |> Repo.all()
  end

  @doc """
  names/2 is the scope's workspace's nodes of `ids`, deleted ones too, by id: for a page
  that shows the node a run ran on. A node of another workspace is not among them.
  """
  @spec names(Scope.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => Node.t()}
  def names(%Scope{}, []), do: %{}

  def names(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        ids
      ) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: n.id in ^Enum.uniq(ids)
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp instances_query(%Scope{organisation: %Organisation{id: organisation_id}}, :organisation) do
    from i in Instance,
      where: i.organisation_id == ^organisation_id and is_nil(i.workspace_id)
  end

  defp instances_query(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{id: workspace_id}
         },
         nil
       ) do
    from i in Instance,
      where: i.organisation_id == ^organisation_id and i.workspace_id == ^workspace_id
  end

  ## Pruning

  @doc """
  prune_instances/1 deletes, on every workspace, the instance rows that are no longer
  shown: a pool's instances not seen for a day before `now`, and a Node's instances other
  than its latest not seen for #{@node_keeps_days} days. Runs and deliveries keep the
  instance id they claimed. Returns how many rows went. The retention job calls it
  (`Apiary.Retention.prune_all/1`).
  """
  @spec prune_instances(DateTime.t()) :: non_neg_integer
  def prune_instances(%DateTime{} = now \\ DateTime.utc_now()) do
    day = DateTime.add(now, -@day, :second)
    month = DateTime.add(now, -@node_keeps_days * @day, :second)

    {pools, _} =
      Repo.delete_all(
        from i in Instance,
          join: n in Node,
          on: n.id == i.node_id,
          where: n.kind == :pool and i.last_seen_at < ^day
      )

    later =
      from l in Instance,
        where:
          l.node_id == parent_as(:instance).node_id and
            l.last_seen_at > parent_as(:instance).last_seen_at

    {nodes, _} =
      Repo.delete_all(
        from i in Instance,
          as: :instance,
          join: n in Node,
          on: n.id == i.node_id,
          where: n.kind == :node and i.last_seen_at < ^month and exists(later)
      )

    pools + nodes
  end
end
