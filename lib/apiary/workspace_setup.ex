defmodule Apiary.WorkspaceSetup do
  # What the Overview's setup list reads of a workspace, with the `factory` feature: its
  # four steps, each done by its rule, and the state of its test run.
  #
  # Each rule is asked of the edition (`c:Apiary.Edition.work_source_ready/1`,
  # `c:Apiary.Edition.machines_ready/1`, `c:Apiary.Edition.model_key_ready?/1`,
  # `c:Apiary.Edition.test_run_passed?/1`), which may count what serves the workspace from
  # another organisation. The core's edition answers with the functions here:
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
  # line. None of them asks access: the Overview's reader reads them.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{AccessKeys, Edition, Gateways, ModelChoices, Repo}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Connections.Connection, as: ModelProvider
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Nodes.{Installed, Node}
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value
  alias Apiary.WorkItems.WorkItem

  # How long the test run may wait for a machine before the step says so.
  @machine_wait_seconds 300

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

  ## The rules

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
        provider_with_key =
          from c in ModelProvider,
            join: v in Value,
            on: v.secret_id == c.secret_id,
            where: c.organisation_id == ^owner_id and not is_nil(c.provider_kind),
            where: c.chain == ^chain

        Repo.exists?(provider_with_key) and Repo.exists?(choice(chain, owner_id, workspace))
    end
  end

  # The choice a run of `workspace` reads on `chain`, of the organisation `owner_id`.
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
