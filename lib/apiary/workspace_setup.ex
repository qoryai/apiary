defmodule Apiary.WorkspaceSetup do
  # What the set-up reads: the steps of the set-up flow (`flow/0`), each done by its rule
  # here, and the state of a workspace's test run. The set-up page
  # (`ApiaryWeb.WorkspaceSetupLive`) and the Overview's setup list read the same rules.
  #
  # The flow's steps, in order, each of a group: for the organisation, Work sources,
  # Work destinations and Model; for the workspace, Name, Work sources used, Destinations
  # used, Harness and Test run. A step is done by its rule:
  #
  #   * `sources?/2`: the organisation has a connected connection of an adapter in use
  #     with items that serves the workspace's type (`Apiary.Lingo.Domain`);
  #   * `destinations?/2`: the same, for an adapter with `targets` true;
  #   * `model?/1`: on the chain of model choices that resolves for the organisation's
  #     runs (`Apiary.ModelChoices.chain_owner/1`), a model provider with at least one
  #     key, and the organisation's default (level 6). The runtime is checked when the
  #     choice is saved, so the rule resolves none;
  #   * `name?/1`: the workspace exists;
  #   * `sources_used?/2`: a row of its tick list is ticked: a collection assigned to
  #     the workspace with its Backlog on;
  #   * `destinations_used?/2`: a row of its tick list is ticked: a collection with a
  #     target assigned to the workspace;
  #   * `harness?/1`: the workspace has a saved harness choice (`Apiary.Stacks.choice/1`);
  #   * `test?/1`: the edition's `test_run_passed?/1`.
  #
  # The Overview's setup list reads the edition's four rules (`read/2`):
  # `c:Apiary.Edition.work_source_ready/1`, `c:Apiary.Edition.machines_ready/1`,
  # `c:Apiary.Edition.model_key_ready?/1` and `c:Apiary.Edition.test_run_passed?/1`, which
  # may count what serves the workspace from another organisation. The core's edition
  # answers with the functions here:
  #
  #   * `work_source/1`: the live collections assigned to the workspace, of a connection
  #     of its organisation that is connected and that an adapter's listing has named
  #     (`listed_at`), of an adapter in use, counted per adapter;
  #   * `machines/1`: a node pool that serves the workspace's runs, with an active key,
  #     and the gateway its choice resolves to, with an active key too
  #     (`Apiary.Gateways.resolve/1`). The pools that serve them are the workspace's pools
  #     in use, or, while it has none, the instance's pool, as a claim takes them
  #     (`Apiary.Dispatches.no_pool_in_use/0`);
  #   * `model_key?/1`: on the chain of model choices that resolves for the workspace's
  #     runs (`Apiary.ModelChoices.chain_owner/1`), a model provider with at least one key,
  #     and a choice that a run reads: for the organisation's chain, a choice of the
  #     workspace (level 5, `Apiary.ModelChoices.ModelChoice`); for an operator's chain,
  #     the operator's default (level 6), the one level a run reads of it;
  #   * `test_passed?/1`: a run of one of the workspace's test work items
  #     (`Apiary.WorkItems.take_in_test/2`) that ended by its exit, `run_ended`, with its
  #     registered run `completed`.
  #
  # `test_run/2` is the state of the latest test work item's latest run, for the step's
  # line. `collections/3` is the rows of the tick lists of Work sources used and
  # Destinations used, to a person who may read the instance's adapters, and `tick/5` one
  # tick or untick of a row: the set-up's steps and Workspace settings › Work sources and
  # › Destinations show and tick the same lists. `tick/5` changes a collection through
  # `Apiary.Adapters.Collections`, which checks access. None of the others checks access:
  # the page's reader reads them.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Adapters, Edition, Gateways, ModelChoices, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection}
  alias Apiary.Connections.Connection, as: ModelProvider
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Nodes.{Installed, Node}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value
  alias Apiary.WorkItems.WorkItem

  # How long the test run may wait for a machine before the step says so.
  @machine_wait_seconds 300

  # The steps of the set-up flow, in order, each with its group. A step is one entry
  # here, its rule in `done?/3`, and its page (`ApiaryWeb.WorkspaceSetupLive`).
  @flow [
    sources: :organisation,
    destinations: :organisation,
    model: :organisation,
    name: :workspace,
    sources_used: :workspace,
    destinations_used: :workspace,
    harness: :workspace,
    test: :workspace
  ]

  @typedoc "A step of the set-up flow (`flow/0`)."
  @type step ::
          :sources
          | :destinations
          | :model
          | :name
          | :sources_used
          | :destinations_used
          | :harness
          | :test

  @typedoc """
  A row of a tick list (`collections/3`): a live collection with its connection, and the
  workspace it is assigned to, nil for none.
  """
  @type tick_row :: %{
          collection: Collection.t(),
          connection: Connection.t(),
          workspace: Workspace.t() | nil
        }

  @typedoc "An adapter whose collections are assigned to the workspace, with how many."
  @type source :: %{adapter: Node.t(), collections: pos_integer}

  @typedoc "A node pool that serves the workspace's runs, and its gateway."
  @type machines :: %{pool: Node.t(), gateway: Node.t()}

  @typedoc """
  The latest test run: `:waiting` for a machine, `:running` once claimed, `:passed`, or
  `{:failed, cause}`: `:no_machine` (it waited more than 5 minutes), `:model_key_missing`
  (its gateway refused it for a missing model key), `:silent` (lost: no word from it for
  10 minutes) or `:other`. `run` is the run its claim registered, nil before.
  """
  @type test_run :: %{
          state:
            :waiting
            | :running
            | :passed
            | {:failed, :no_machine | :model_key_missing | :silent | :other},
          work_item: WorkItem.t(),
          dispatch_run: DispatchRun.t(),
          run: Run.t() | nil
        }

  @typedoc "What the setup list reads, each rule as the edition answers it."
  @type t :: %{
          work_source: [source],
          machines: machines | nil,
          model_key: boolean,
          test_passed: boolean,
          test_run: test_run | nil
        }

  @doc false
  # read/2 is the four rules, asked of the edition, and the latest test run at `now`.
  @spec read(Workspace.t(), DateTime.t()) :: t
  def read(%Workspace{} = workspace, %DateTime{} = now \\ DateTime.utc_now()) do
    %{
      work_source: Edition.work_source_ready(workspace),
      machines: Edition.machines_ready(workspace),
      model_key: Edition.model_key_ready?(workspace),
      test_passed: Edition.test_run_passed?(workspace),
      test_run: test_run(workspace, now)
    }
  end

  @doc false
  # machine_wait_seconds/0 is how long a test run waits for a machine before its step says
  # that none has taken it.
  @spec machine_wait_seconds() :: pos_integer
  def machine_wait_seconds, do: @machine_wait_seconds

  ## The flow

  @doc false
  # flow/0 is the steps of the set-up flow, in order, each `{step, group}`: `:organisation`
  # for the steps the organisation does once, `:workspace` for each workspace's.
  @spec flow() :: [{step, :organisation | :workspace}]
  def flow, do: @flow

  @doc false
  # done?/3 is whether `step` is done, by its rule, for `organisation`, a workspace of the
  # type `domain` (`Apiary.Lingo.Domain`), and `workspace`, nil before it exists.
  @spec done?(step, Organisation.t(), {module, Workspace.t() | nil}) :: boolean
  def done?(:sources, organisation, {domain, _workspace}), do: sources?(organisation, domain)

  def done?(:destinations, organisation, {domain, _workspace}),
    do: destinations?(organisation, domain)

  def done?(:model, organisation, _type), do: model?(organisation)
  def done?(:name, _organisation, {_domain, workspace}), do: name?(workspace)
  def done?(_step, _organisation, {_domain, nil}), do: false

  def done?(:sources_used, _organisation, {domain, workspace}),
    do: sources_used?(workspace, domain)

  def done?(:destinations_used, _organisation, {domain, workspace}),
    do: destinations_used?(workspace, domain)

  def done?(:harness, _organisation, {_domain, workspace}), do: harness?(workspace)
  def done?(:test, _organisation, {_domain, workspace}), do: test?(workspace)

  @doc false
  # sources?/2 is whether `organisation` has a connected connection of an adapter in use
  # with items that serves `domain`.
  @spec sources?(Organisation.t(), module) :: boolean
  def sources?(%Organisation{id: organisation_id}, domain),
    do: Repo.exists?(connected_adapters(organisation_id, domain, :items))

  @doc false
  # destinations?/2 is whether `organisation` has a connected connection of an adapter in
  # use with `targets` true that serves `domain`.
  @spec destinations?(Organisation.t(), module) :: boolean
  def destinations?(%Organisation{id: organisation_id}, domain),
    do: Repo.exists?(connected_adapters(organisation_id, domain, :targets))

  @doc false
  # connected_ids/3 is the ids of the adapters in use with items (`:items`) or with
  # `targets` true (`:targets`) that serve `domain` and that `organisation` has a
  # connected connection of.
  @spec connected_ids(Organisation.t(), module, :items | :targets) :: MapSet.t(Ecto.UUID.t())
  def connected_ids(%Organisation{id: organisation_id}, domain, role),
    do:
      organisation_id
      |> connected_adapters(domain, role)
      |> select([_k, n], n.id)
      |> Repo.all()
      |> MapSet.new()

  defp connected_adapters(organisation_id, domain, role) do
    name = domain.name()

    from(k in Connection,
      join: n in Node,
      on: n.id == k.adapter_id,
      where: k.organisation_id == ^organisation_id,
      where: k.state == :connected and is_nil(k.ended_at),
      where: n.kind == :adapter and is_nil(n.deleted_at),
      where: is_nil(n.domains) or ^name in n.domains
    )
    |> where_role(role)
  end

  defp where_role(query, :items), do: where(query, [_k, n], n.items)
  defp where_role(query, :targets), do: where(query, [_k, n], n.targets == true)

  @doc false
  # model?/1 is whether the chain of model choices that resolves for `organisation`'s runs
  # has a model provider with a key and the organisation's default (level 6) on that chain.
  # False on an operator's chain for which `c:Apiary.Edition.operator_chain_organisation/1`
  # returns nil.
  @spec model?(Organisation.t()) :: boolean
  def model?(%Organisation{id: organisation_id}) do
    case ModelChoices.chain_owner(organisation_id) do
      {_chain, nil} ->
        false

      {chain, owner_id} ->
        Repo.exists?(provider_with_key(chain, owner_id)) and
          Repo.exists?(choice(chain, owner_id, nil))
    end
  end

  @doc false
  # name?/1 is whether the workspace exists.
  @spec name?(Workspace.t() | nil) :: boolean
  def name?(workspace), do: match?(%Workspace{}, workspace)

  @doc false
  # sources_used?/2 is whether a row of the tick list Work sources used, of `workspace` of
  # the type `domain`, is ticked: a collection of the list (`collections/3`, `:sources`)
  # assigned to `workspace` with its Backlog on.
  @spec sources_used?(Workspace.t(), module) :: boolean
  def sources_used?(%Workspace{id: workspace_id, organisation_id: organisation_id}, domain) do
    organisation_id
    |> list_query(domain, :sources)
    |> where([c], c.workspace_id == ^workspace_id and c.backlog)
    |> Repo.exists?()
  end

  @doc false
  # destinations_used?/2 is whether a row of the tick list Destinations used, of
  # `workspace` of the type `domain`, is ticked: a collection of the list
  # (`collections/3`, `:destinations`) assigned to `workspace`.
  @spec destinations_used?(Workspace.t(), module) :: boolean
  def destinations_used?(%Workspace{id: workspace_id, organisation_id: organisation_id}, domain) do
    organisation_id
    |> list_query(domain, :destinations)
    |> where([c], c.workspace_id == ^workspace_id)
    |> Repo.exists?()
  end

  @doc false
  # harness?/1 is whether `workspace` has a saved harness choice.
  @spec harness?(Workspace.t()) :: boolean
  def harness?(%Workspace{} = workspace), do: Stacks.choice(workspace) != nil

  @doc false
  # test?/1 is whether the edition counts a test run of `workspace` that passed
  # (`c:Apiary.Edition.test_run_passed?/1`).
  @spec test?(Workspace.t()) :: boolean
  def test?(%Workspace{} = workspace), do: Edition.test_run_passed?(workspace)

  ## The tick lists

  @doc false
  # collections/3 is the rows of a tick list for `domain`, a workspace's type, grouped by
  # adapter, by the adapter's name, then by title: the live collections of the scope's organisation,
  # of a connection that is connected, of an adapter in use that serves `domain`, each with
  # its connection and the workspace it is assigned to. For `:sources`, the collections
  # with items of an adapter with items; for `:destinations`, the collections with a
  # target of an adapter with `targets` true. `[]` to a person who may not read the
  # instance's adapters in the organisation (`adapter.read`).
  @spec collections(Scope.t(), module, :sources | :destinations) :: [{Node.t(), [tick_row]}]
  def collections(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
        domain,
        list
      ) do
    if Access.can?(scope, :"adapter.read", organisation) do
      from([c, k, n] in list_query(organisation_id, domain, list),
        left_join: w in Workspace,
        on: w.id == c.workspace_id,
        order_by: [
          asc: fragment("lower(?)", n.name),
          asc: n.id,
          asc: fragment("lower(?)", c.title),
          asc: c.id
        ],
        select: {n, %{collection: c, connection: k, workspace: w}}
      )
      |> Repo.all()
      |> Enum.chunk_by(fn {adapter, _row} -> adapter.id end)
      |> Enum.map(fn [{adapter, _row} | _rest] = rows ->
        {adapter, Enum.map(rows, &elem(&1, 1))}
      end)
    else
      []
    end
  end

  # The collections of a tick list (`collections/3`), as `[c, k, n]`: collection,
  # connection, adapter.
  defp list_query(organisation_id, domain, list) do
    name = domain.name()

    from(c in Collection,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      on: n.id == c.adapter_id,
      where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
      where: k.state == :connected and is_nil(k.ended_at),
      where: n.kind == :adapter and is_nil(n.deleted_at),
      where: is_nil(n.domains) or ^name in n.domains
    )
    |> where_list(list)
  end

  defp where_list(query, :sources), do: where(query, [c, _k, n], c.items and n.items)

  defp where_list(query, :destinations),
    do: where(query, [c, _k, n], n.targets == true and not is_nil(c.target_system))

  @doc false
  # ticked?/3 is whether `row` of the tick list `list` is ticked for `workspace`: a work
  # source while it is the workspace's with its Backlog on; a destination while it is the
  # workspace's.
  @spec ticked?(:sources | :destinations, tick_row, Workspace.t()) :: boolean
  def ticked?(:sources, %{collection: c}, %Workspace{id: id}),
    do: c.workspace_id == id and c.backlog

  def ticked?(:destinations, %{collection: c}, %Workspace{id: id}), do: c.workspace_id == id

  @doc false
  # tick/5 ticks or unticks the collection `collection_id` in the tick list `list` of
  # `workspace` of the type `domain`, on the list as it stands now (`collections/3`), not as
  # a page last showed it:
  #
  #   * ticking a work source assigns the collection and turns its Backlog on;
  #   * ticking a destination assigns it with its Backlog off, unless it is ticked as a
  #     work source;
  #   * unticking a work source turns its Backlog off, and unassigns a collection that is
  #     no destination;
  #   * unticking a destination turns its Backlog off and unassigns it.
  #
  # `{:error, :unlisted}` for a collection the list does not have, and
  # `{:error, :elsewhere}` for one in another workspace, which changes nothing: moving it
  # stays on the organisation's integration page. `Apiary.Adapters.Collections` returns
  # neither atom. Else the answer of
  # `Apiary.Adapters.Collections.assign_collections/4` and
  # `Apiary.Adapters.Collections.set_collection_backlog/4`: `{:error, :forbidden}` to a
  # person whom `collection.assign` or `collection.set_backlog` does not allow, and
  # `{:error, :not_found}` where the connection, the workspace or the collection ended
  # after the read.
  @spec tick(Scope.t(), Workspace.t(), module, :sources | :destinations, term) ::
          :ok | {:error, term}
  def tick(%Scope{} = scope, %Workspace{} = workspace, domain, list, collection_id) do
    found =
      scope
      |> collections(domain, list)
      |> Enum.find_value(fn {adapter, rows} ->
        Enum.find_value(rows, &(&1.collection.id == collection_id && {adapter, &1}))
      end)

    case found do
      nil ->
        {:error, :unlisted}

      {_adapter, %{workspace: %Workspace{id: id}}} when id != workspace.id ->
        {:error, :elsewhere}

      {adapter, row} ->
        toggle(scope, workspace, list, adapter, row)
    end
  end

  defp toggle(scope, workspace, list, adapter, %{collection: collection} = row) do
    here? = collection.workspace_id == workspace.id
    switch? = collection.items and Adapters.items?(adapter)
    destination? = adapter.targets == true and not is_nil(collection.target_system)

    case {list, ticked?(list, row, workspace)} do
      {:sources, false} ->
        with :ok <- if(here?, do: :ok, else: assign_row(scope, row, workspace)),
             do: if(switch?, do: backlog(scope, row, true), else: :ok)

      {:sources, true} ->
        with :ok <- if(switch?, do: backlog(scope, row, false), else: :ok),
             do: if(destination?, do: :ok, else: assign_row(scope, row, nil))

      {:destinations, false} ->
        with :ok <- if(here?, do: :ok, else: assign_row(scope, row, workspace)),
             do: if(switch? and not here?, do: backlog(scope, row, false), else: :ok)

      {:destinations, true} ->
        with :ok <- if(switch?, do: backlog(scope, row, false), else: :ok),
             do: assign_row(scope, row, nil)
    end
  end

  defp assign_row(scope, %{collection: collection, connection: connection}, workspace) do
    case Collections.assign_collections(scope, connection, [collection.id], workspace) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp backlog(scope, %{collection: collection, connection: connection}, on) do
    case Collections.set_collection_backlog(scope, connection, collection.id, on) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## The rules of the setup list

  @doc false
  # work_source/1 is each adapter in use with live collections assigned to `workspace` of
  # a connection that is connected and listed, with how many, by the adapter's name.
  @spec work_source(Workspace.t()) :: [source]
  def work_source(%Workspace{id: workspace_id, organisation_id: organisation_id}) do
    from(c in Collection,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      on: n.id == c.adapter_id,
      where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
      where: is_nil(c.ended_at),
      where: k.state == :connected and is_nil(k.ended_at) and not is_nil(k.listed_at),
      where: n.kind == :adapter and is_nil(n.deleted_at),
      group_by: n.id,
      order_by: [asc: fragment("lower(?)", n.name), asc: n.id],
      select: %{adapter: n, collections: count(c.id)}
    )
    |> Repo.all()
  end

  @doc false
  # machines/1 is the first node pool that serves `workspace`'s runs with an active key
  # and whose choice resolves to a gateway with an active key, with that gateway; nil for
  # none.
  @spec machines(Workspace.t()) :: machines | nil
  def machines(%Workspace{} = workspace) do
    workspace
    |> serving_pools()
    |> Enum.find_value(fn pool ->
      with true <- AccessKeys.active_key?(pool),
           {:gateway, gateway} <- Gateways.resolve(pool) do
        %{pool: pool, gateway: gateway}
      else
        _not_ready -> nil
      end
    end)
  end

  @doc false
  # instance_pool?/1 is whether the instance's pool serves `workspace`'s runs: whether the
  # workspace has no node pool in use.
  @spec instance_pool?(Workspace.t()) :: boolean
  def instance_pool?(%Workspace{} = workspace),
    do: not Repo.exists?(workspace_pools(workspace))

  # The workspace's node pools in use, oldest first, or the instance's pool while it has
  # none.
  defp serving_pools(%Workspace{} = workspace) do
    case Repo.all(workspace_pools(workspace)) do
      [] -> List.wrap(Repo.one(Installed.live_query(:pool)))
      pools -> Enum.map(pools, &%{&1 | workspace: workspace})
    end
  end

  defp workspace_pools(%Workspace{id: workspace_id}) do
    from n in Node,
      where: n.workspace_id == ^workspace_id and n.kind == :pool and is_nil(n.deleted_at),
      order_by: [asc: n.inserted_at, asc: n.id]
  end

  @doc false
  # model_key?/1 is whether the chain of model choices that resolves for `workspace`'s runs
  # has a model provider with a key, and a choice a run reads: the workspace's (level 5)
  # on the organisation's chain, the operator's default (level 6) on an operator's. False
  # on an operator's chain whose operator the edition does not name.
  @spec model_key?(Workspace.t()) :: boolean
  def model_key?(%Workspace{organisation_id: organisation_id} = workspace) do
    case ModelChoices.chain_owner(organisation_id) do
      {_chain, nil} ->
        false

      {chain, owner_id} ->
        Repo.exists?(provider_with_key(chain, owner_id)) and
          Repo.exists?(choice(chain, owner_id, workspace))
    end
  end

  # The model providers of `chain` of the organisation `owner_id` that have a key.
  defp provider_with_key(chain, owner_id) do
    from c in ModelProvider,
      join: v in Value,
      on: v.secret_id == c.secret_id,
      where: c.organisation_id == ^owner_id and not is_nil(c.provider_kind),
      where: c.chain == ^chain
  end

  # The choice a run of `workspace` reads on `chain`, of the organisation `owner_id`; with
  # no workspace, the organisation's default (level 6).
  defp choice(chain, owner_id, nil) do
    from m in ModelChoice,
      where: m.organisation_id == ^owner_id and m.chain == ^chain,
      where: is_nil(m.workspace_id) and is_nil(m.target_id) and is_nil(m.workflow)
  end

  defp choice("operator", owner_id, _workspace) do
    from m in ModelChoice,
      where: m.organisation_id == ^owner_id and m.chain == "operator",
      where: is_nil(m.workspace_id) and is_nil(m.target_id) and is_nil(m.workflow)
  end

  defp choice(chain, owner_id, %Workspace{id: workspace_id}) do
    from m in ModelChoice,
      where: m.organisation_id == ^owner_id and m.workspace_id == ^workspace_id,
      where: is_nil(m.target_id) and is_nil(m.workflow) and m.chain == ^chain
  end

  @doc false
  # test_passed?/1 is whether a run of a test work item of `workspace` ended by its exit
  # with its registered run completed.
  @spec test_passed?(Workspace.t()) :: boolean
  def test_passed?(%Workspace{id: workspace_id, organisation_id: organisation_id}) do
    Repo.exists?(
      from d in DispatchRun,
        join: w in WorkItem,
        on: w.id == d.work_item_id,
        join: r in Run,
        on: r.dispatch_run_id == d.id,
        where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id,
        where: w.test and d.state == :ended and d.end_cause == :run_ended,
        where: r.state == "completed"
    )
  end

  ## The test run

  @doc false
  # test_run/2 is the latest run of `workspace`'s latest test work item, read at `now`,
  # with its state (`t:test_run/0`); nil while the workspace has no test work item.
  @spec test_run(Workspace.t(), DateTime.t()) :: test_run | nil
  def test_run(%Workspace{id: workspace_id, organisation_id: organisation_id}, now) do
    work_item =
      Repo.one(
        from w in WorkItem,
          where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id,
          where: w.test,
          order_by: [desc: w.number],
          limit: 1
      )

    dispatch_run =
      work_item &&
        Repo.one(
          from d in DispatchRun,
            where: d.work_item_id == ^work_item.id,
            order_by: [desc: d.take_in, desc: d.attempt],
            limit: 1,
            preload: [run: :node]
        )

    if dispatch_run do
      %{
        state: test_state(dispatch_run, dispatch_run.run, now),
        work_item: work_item,
        dispatch_run: dispatch_run,
        run: dispatch_run.run
      }
    end
  end

  defp test_state(%DispatchRun{state: :waiting, queued_at: queued_at}, _run, now) do
    if DateTime.diff(now, queued_at, :second) > @machine_wait_seconds,
      do: {:failed, :no_machine},
      else: :waiting
  end

  defp test_state(%DispatchRun{state: state}, _run, _now) when state in [:claimed, :handed_over],
    do: :running

  defp test_state(%DispatchRun{end_cause: :run_ended}, %Run{state: "completed"}, _now),
    do: :passed

  defp test_state(%DispatchRun{end_cause: :run_refused, end_detail: "model_key_missing"}, _, _),
    do: {:failed, :model_key_missing}

  defp test_state(%DispatchRun{end_cause: :lost}, %Run{silenced_at: %DateTime{}}, _now),
    do: {:failed, :silent}

  defp test_state(_dispatch_run, _run, _now), do: {:failed, :other}
end
