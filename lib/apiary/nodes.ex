defmodule Apiary.Nodes do
  @moduledoc """
  Nodes holds a workspace's nodes and node pools (`Apiary.Nodes.Node`), the places its
  runs run: a **node** is one permanent machine, which runs one instance at a time; a
  **node pool** is a fleet of short-lived instances, which run up to its instance limit,
  or any number when it has none. The kind is chosen when one is made and never changes.

  Every function a page calls takes an `Apiary.Accounts.Scope` with a workspace first and
  reads or changes only that workspace's nodes, in its organisation: a node of another
  workspace is not found. A node is named by its public id (`nd_…` or `np_…`), the id its
  page's path carries. A deleted node is gone from every read here. The receiving side's
  functions (`seen/3`, `placement/2`, `check_instance_limit/3`, `admit/4`) take the node
  a verified access key names instead, and the retention job's (`prune_instances/1`)
  none.

  Making, changing and deleting a node, and clearing an instance, are owners' and admins'
  (`node.create`, `node.edit`, `node.delete`, `node.clear_instance`); everyone in the
  workspace reads them (`node.read`, asked by the pages). A node's access keys are
  `Apiary.AccessKeys`'s; deleting a node revokes them. Each change asks
  `Apiary.Access.authorize/3` first and leaves its audit entry (`Apiary.Audit`) in its
  transaction: the name, kind, public id and limit of a new node, the name and limit an
  edit changed, a deletion's time, the instance a clearing cleared.

  **Instances.** An instance is what a runner using a node's access key reports itself as
  (`Apiary.Nodes.Instance`): a claim, for display, the audit and the instance limit, never
  for authorisation. `seen/3` records one when a request is verified and broadcasts
  `{:nodes_touched, workspace_id}` (`topic/1`). An instance is **running** while it has a
  run alive by the lost-run check's rule (`Apiary.Runs.Liveness.alive/2`), so running
  means "not yet lost", and a node runs while any of its instances does (`activity/3`).
  `check_instance_limit/3` and `admit/4` hold a node to its instance limit when a ping
  would create a run, under the node's row lock; `clear_instance/3` marks an instance's
  open runs lost, for one that stopped without saying so; `prune_instances/1` deletes the
  rows the pages no longer show.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Audit, Repo, Runs}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
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
  purged. In the same transaction it revokes every key of the node in use, each with its entry of `access_key.revoke` and its public key a
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
  signed, and beside it the `name` it gave (unsigned), the key's row id, and the runner's
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
  start of its oldest run alive), its newest run alive (`run_id`, the run's subject) and
  the runner's version that run reported.
  """
  @type running :: %{
          instance_id: String.t(),
          name: String.t() | nil,
          since: DateTime.t(),
          run_id: Ecto.UUID.t(),
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
  topic/1 is the topic of a workspace's nodes: `{:nodes_touched, workspace_id}` whenever
  an instance of one of them was seen or cleared.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id), do: "nodes:" <> workspace_id

  @doc "subscribe/1 subscribes the caller to `topic/1` of the scope's workspace."
  @spec subscribe(Scope.t()) :: :ok | {:error, term}
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))

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
    runner = version(claim[:forager_version])
    contract = contract(claim[:contract_version])

    {updated, _} =
      Repo.update_all(
        from(i in Instance,
          where: i.node_id == ^node.id and i.instance_id == ^instance_id,
          update: [
            set: [
              last_seen_at: fragment("GREATEST(?, ?)", i.last_seen_at, ^now),
              name: coalesce(type(^name, :string), i.name),
              access_key_id: coalesce(type(^key, :binary_id), i.access_key_id),
              last_forager_version: coalesce(type(^runner, :string), i.last_forager_version),
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
              instance_id: instance_id,
              name: name,
              first_seen_at: now,
              last_seen_at: now,
              last_forager_version: runner,
              last_contract_version: contract
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:node_id, :instance_id]
        )
    end

    broadcast_touched(node.workspace_id)
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
  placement/2 is what a run records of where it runs, `%{node_id:, instance_id:}`: the
  node of the access key its ping came with, and the instance id that ping claimed, nil
  when it cannot be kept (`Apiary.Nodes.Instance.instance_id?/1`). The receiving side
  merges it into the run's row when it creates the run, and the instance id into the
  delivery's row (`Apiary.Runs.Ingest`).
  """
  @spec placement(Node.t() | nil, String.t() | nil) ::
          %{node_id: Ecto.UUID.t() | nil, instance_id: String.t() | nil}
  def placement(nil, _instance_id), do: %{node_id: nil, instance_id: nil}

  def placement(%Node{id: id}, instance_id),
    do: %{node_id: id, instance_id: if(Instance.instance_id?(instance_id), do: instance_id)}

  ## The instance limit

  @doc """
  check_instance_limit/3 says whether `instance_id` may start a run on `node` at `now`,
  inside the transaction of the batch that would create the run. A pool without a limit
  admits any, with neither a lock nor a count. Otherwise it locks the node's row
  `FOR UPDATE`, so two checks for one node take turns, reads the limit as it is now (1 for
  a Node), and counts the distinct instance ids of the node's runs alive at `now`
  (`Apiary.Runs.Liveness.alive/2`):

  - `:already_counted` when `instance_id` is among them: it runs already, and a second
    run of it takes no slot;
  - `{:error, :instance_limit}` when they are as many as the limit or more: the caller
    rolls back and stores nothing;
  - `:ok` otherwise: the run the caller then creates, in the same transaction, is the
    reservation, and counts for the next check as soon as it commits.

  Only accepted runs count, so a refused instance never does; lowering a pool's limit
  stops none that run, and refuses new ones until fewer run. The lock comes before
  whatever the batch locks after it, the run's row among them. Raises outside a
  transaction. `admit/4` is the whole of it, with the refusal counted.
  """
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
      length(running) >= limit -> {:error, :instance_limit}
      true -> :ok
    end
  end

  # The distinct instance ids of the node's runs alive at `now`, read from the partial
  # index on the runs alive by node and instance.
  defp running_instance_ids(%Node{id: id, workspace_id: workspace_id}, now) do
    from(r in Run,
      as: :run,
      where: r.node_id == ^id and r.workspace_id == ^workspace_id,
      where: not is_nil(r.instance_id),
      distinct: true,
      select: r.instance_id
    )
    |> Liveness.alive(now)
    |> Repo.all()
  end

  @doc """
  admit/4 runs `fun`, the store of the batch that creates a run of `instance_id` on
  `node`, in one transaction with the instance limit's check (`check_instance_limit/3`)
  before it: `fun`'s answer when the instance is admitted, `{:ok, value}` or
  `{:error, reason}` (an error rolls the whole back); `{:error, :instance_limit}` when it
  is refused, after the transaction has rolled back with nothing stored, and then the
  node's `instance_limit_refused` is counted and `instance_limit_refused_at` set, in a
  statement of its own. Raises inside a transaction: it is the batch's transaction.

  The receiving side calls it for a batch that holds the ping of a run the workspace has
  not seen (`Apiary.Runs.Ingest`).
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
  pending or running, are marked lost through the lost-run check's own update
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
                   where: i.node_id == ^current.id and i.instance_id == ^instance_id,
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
      broadcast_touched(node.workspace_id)
    end

    result
  end

  defp open_runs(%Node{id: id, workspace_id: workspace_id}, instance_id) do
    from r in Run,
      where: r.node_id == ^id and r.workspace_id == ^workspace_id,
      where: r.instance_id == ^instance_id and r.state in ["pending", "running"]
  end

  ## Reading instances

  @doc """
  get_instance/3 is the instance `instance_id` of `node`, a node of the scope's workspace,
  or nil when the node has no row of it.
  """
  @spec get_instance(Scope.t(), Node.t() | Ecto.UUID.t(), String.t()) :: Instance.t() | nil
  def get_instance(scope, %Node{id: id}, instance_id), do: get_instance(scope, id, instance_id)

  def get_instance(%Scope{} = scope, node_id, instance_id)
      when is_binary(node_id) and is_binary(instance_id) do
    scope
    |> instances_query()
    |> where([i], i.node_id == ^node_id and i.instance_id == ^instance_id)
    |> Repo.one()
  end

  def get_instance(%Scope{}, _node_id, _instance_id), do: nil

  @doc """
  instance_of/2 is the row of the instance `run`, a run of the scope's workspace, ran as:
  nil for a run that names no node or no instance, and for an instance whose row was
  pruned or never recorded.
  """
  @spec instance_of(Scope.t(), Run.t()) :: Instance.t() | nil
  def instance_of(%Scope{} = scope, %Run{node_id: node_id, instance_id: instance_id})
      when is_binary(node_id) and is_binary(instance_id),
      do: get_instance(scope, node_id, instance_id)

  def instance_of(%Scope{}, %Run{}), do: nil

  @doc """
  activity/3 is what each of `nodes`, nodes of the scope's workspace, is doing at `now`
  (`t:activity/0`), by node id: its instances running now, those with a run alive by the
  lost-run check's rule (`Apiary.Runs.Liveness.alive/2`), oldest first; the instance
  seen last; and when one of its keys was last used, which still says the node was seen
  once `prune_instances/1` has taken a pool's last instance. Four reads, whatever the
  number of nodes.
  """
  @spec activity(Scope.t(), [Node.t()], DateTime.t()) :: %{Ecto.UUID.t() => activity}
  def activity(scope, nodes, now \\ DateTime.utc_now())

  def activity(%Scope{}, [], _now), do: %{}

  def activity(%Scope{} = scope, nodes, %DateTime{} = now) do
    ids = Enum.map(nodes, & &1.id)
    runs = alive_runs(scope, ids, now)

    last =
      scope
      |> instances_query()
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
          scope
          |> instances_query()
          |> where([i], i.node_id in ^ids and i.instance_id in ^instance_ids)
          |> Repo.all()
          |> Map.new(&{{&1.node_id, &1.instance_id}, &1})

    running =
      runs
      |> Enum.group_by(&{&1.node_id, &1.instance_id})
      |> Enum.map(fn {{node_id, instance_id} = key, runs} ->
        newest = Enum.max_by(runs, & &1.since, DateTime)
        row = Map.get(rows, key)

        {node_id,
         %{
           instance_id: instance_id,
           name: row && row.name,
           since: runs |> Enum.map(& &1.since) |> Enum.min(DateTime),
           run_id: newest.run_id,
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

  # When each node's keys were last used, revoked keys too, by node id: a node none of
  # whose keys was used is not among them.
  defp keys_used(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{id: workspace_id}
         },
         ids
       ) do
    from(k in AccessKey,
      where: k.organisation_id == ^organisation_id and k.workspace_id == ^workspace_id,
      where: k.node_id in ^ids and not is_nil(k.last_used_at),
      group_by: k.node_id,
      select: {k.node_id, max(k.last_used_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp alive_runs(%Scope{organisation: organisation, workspace: workspace}, ids, now) do
    from(r in Run,
      as: :run,
      where: r.organisation_id == ^organisation.id and r.workspace_id == ^workspace.id,
      where: r.node_id in ^ids and not is_nil(r.instance_id),
      select: %{
        node_id: r.node_id,
        instance_id: r.instance_id,
        run_id: r.run_id,
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

  defp instances_query(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
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
