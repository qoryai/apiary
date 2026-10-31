defmodule ApiaryWeb.WorkItemLive.Workflow do
  # The workflow model on the work item page and the board, under the feature
  # `workflow_model`: what the pages read and do through `Apiary.Stages`,
  # `Apiary.Processes` and `Apiary.Artifacts`, and the plain maps the stage parts draw
  # (`ApiaryWeb.WorkItemLive.StageComponents`).
  #
  # **The artifacts.** Transition, until piece A lands: the artifacts (`artifacts`,
  # `Apiary.Artifacts`) and their plain list (`artifact_components`,
  # `ApiaryWeb.ArtifactComponents`) are read from the application's environment
  # (`config :apiary, ApiaryWeb.WorkItemLive.Workflow, artifacts: …`), with the shared
  # contract's module as the default, through a variable, so the page compiles before
  # they land; the tests put fakes there (`ApiaryWeb.WorkflowFake`). While a module is
  # not loaded, the page lists no artifact.
  #
  # **Check again.** Transition, until `Apiary.Stages.check_workflows/2` lands in the
  # stage runner's next round: `check/3` calls it through the same environment
  # (`workflow_checks`), so the page compiles before it exists.
  #
  # **The work item's topics.** Transition: the stage runner tells `{:stage_changed, id}`
  # on `Apiary.Stages.topic/1`, and piece A `{:artifact_pushed, …}` on
  # `Apiary.Artifacts.topic/1`. Neither function is on `next` yet, so `subscribe/1` reads
  # the modules from the same environment (`stage_topic`, `artifact_topic`) and subscribes
  # only where the module has `topic/1`.
  #
  # **The runs.** Transition: `Apiary.Stages` gives no list of a work item's runs, so
  # `runs/2` reads the runs the stage runner queued (`dispatch_runs` with a workflow) and
  # each run's newest `verdict` in the artifact index.
  #
  # **The feature.** `on?/1` is whether the reader is shown `workflow_model`. A work item
  # the stage runner has not placed (`Apiary.Stages.status/2` is nil) draws as before the
  # feature.
  #
  # **Who decides.** A gate's Approve and Request changes, every escalation action and a
  # move back take `gate.approve`, and only the stage's listed approvers where the stage
  # lists them; Add takes `artifact.write`. The page hides a button from everyone else,
  # and asks again with the scope read from the database on every event (`decide/4`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import Phoenix.Component, only: [sigil_H: 2]

  alias Apiary.{Access, Features, Processes, Repo, Stages}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.Escalation
  alias ApiaryWeb.WorkItemLive.Board

  @defaults [
    artifacts: Apiary.Artifacts,
    artifact_components: ApiaryWeb.ArtifactComponents,
    workflow_checks: Apiary.Stages,
    stage_topic: Apiary.Stages,
    artifact_topic: Apiary.Artifacts
  ]

  @states Apiary.Processes.Version.stage_states()
  @checks [:passed, :missing, :not_checked]
  @verdicts %{
    "passed" => :passed,
    "changes-requested" => :changes_requested,
    "escalate" => :escalate
  }
  @causes %{
    "round_limit" => :round_limit,
    "escalate" => :escalate,
    "check_failed" => :check_failed,
    "run_stopped" => :run_stopped
  }

  @doc false
  # module/1 is the module the pages call for `key`, one of the keys of `@defaults`.
  @spec module(atom) :: module
  def module(key) do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc false
  # on?/1 is whether the reader of `scope` is shown the workflow model: the instance has
  # the feature `workflow_model`, and the scope does not hide it.
  @spec on?(Scope.t()) :: boolean
  def on?(scope), do: Features.visible?(scope, :workflow_model)

  ## The work item page

  @doc false
  # subscribe/1 subscribes the calling process to the topics of `row` that tell a change of
  # its stage or a pushed artifact, where those functions exist.
  @spec subscribe(struct) :: :ok
  def subscribe(row) do
    for key <- [:stage_topic, :artifact_topic],
        topics = module(key),
        Code.ensure_loaded?(topics) and function_exported?(topics, :topic, 1) do
      Phoenix.PubSub.subscribe(Apiary.PubSub, topics.topic(row))
    end

    :ok
  end

  @doc false
  # page/2 is what the work item page draws of `row` under the workflow model: the
  # stages of its process version with the current one marked, the current stage with
  # its state, round and gaps, the runs, the inputs, the outputs at the gate, the
  # escalation, the artifacts' approval marks, and what the reader may do; nil for a work
  # item the stage runner has not placed.
  @spec page(Scope.t(), struct) :: map | nil
  def page(scope, row) do
    case Stages.status(row, scope) do
      nil -> nil
      status -> page(scope, row, status)
    end
  end

  defp page(scope, row, status) do
    version = Processes.version_for(row)
    index = Stages.artifact_index(row)
    document = get(version, :document) || %{}
    all = Enum.map(get(document, :stages) || [], &stage_map/1)
    current_id = id_of(get(status, :stage))
    at = Enum.find_index(all, &(&1.id == current_id))
    state = state(get(status, :state))

    stage =
      Enum.find(
        all,
        %{id: current_id, name: name_of(get(status, :stage))},
        &(&1.id == current_id)
      )

    %{
      version: get(get(status, :version), :number) || get(version, :number),
      stages: track(all, at, state),
      stage: stage,
      state: state,
      round: get(status, :round),
      rounds: get(status, :rounds),
      gaps: lines(get(status, :gaps)),
      runs: runs(row, index),
      inputs: Enum.map(get(status, :inputs) || [], &input/1),
      outputs: Enum.map(get(status, :outputs) || [], &output/1),
      escalation: escalation(get(status, :escalation)),
      approvers: approvers(stage),
      approvable: get(get(status, :gate) || %{}, :approvable?) == true,
      index: Enum.map(index, &indexed/1),
      earlier: if(at, do: Enum.take(all, at), else: []),
      missing_workflows: List.wrap(get(status, :waiting_workflow)),
      confirm_gate: false,
      explore: false,
      can_decide: approver?(scope, stage) and Access.can?(scope, :"gate.approve", row),
      can_add: Access.can?(scope, :"artifact.write", row)
    }
  end

  @doc false
  # artifacts/1 is every artifact of `row`, as `Apiary.Artifacts.list/1` gives them; none
  # while that module is not loaded.
  @spec artifacts(struct) :: list
  def artifacts(row) do
    artifacts = module(:artifacts)
    if Code.ensure_loaded?(artifacts), do: artifacts.list(row), else: []
  end

  @doc false
  # artifact_list/1 draws the plain list of artifacts, `ApiaryWeb.ArtifactComponents.list/1`;
  # nothing while that module is not loaded.
  @spec artifact_list(map) :: Phoenix.LiveView.Rendered.t()
  def artifact_list(assigns) do
    components = module(:artifact_components)

    if Code.ensure_loaded?(components), do: components.list(assigns), else: ~H""
  end

  # The stages of the version, each with whether it is done, the current one or to come.
  defp track(all, nil, _state), do: Enum.map(all, &Map.put(&1, :at, :todo))

  defp track(all, at, state) do
    for {stage, i} <- Enum.with_index(all) do
      at =
        cond do
          i < at or (i == at and state == :done) -> :done
          i == at -> :now
          true -> :todo
        end

      Map.put(stage, :at, at)
    end
  end

  defp stage_map(stage) do
    %{
      id: get(stage, :id),
      name: get(stage, :name),
      gate: get(stage, :gate) || %{},
      sequence: get(stage, :sequence) || []
    }
  end

  defp state(state) when state in @states, do: state

  defp state(state) when is_binary(state),
    do: Enum.find(@states, :running, &(Atom.to_string(&1) == state))

  defp state(_state), do: :running

  # The runs the stage runner queued for the work item, newest first: each with its
  # number in its take in, its workflow, its round, its newest verdict, and whether it
  # runs, stopped (it ended with an error, or the stage runner escalated it as
  # `run_stopped`), or ended.
  defp runs(row, index) do
    stopped =
      Repo.all(
        from e in Escalation,
          where: e.work_item_id == ^row.id and e.cause == :run_stopped and not is_nil(e.run_id),
          select: e.run_id
      )

    verdicts =
      for %{type: "verdict"} = artifact <- index,
          version <- Map.get(artifact, :versions, []),
          is_binary(version[:run_id]),
          reduce: %{} do
        acc -> Map.put_new(acc, version.run_id, version)
      end

    Repo.all(
      from r in DispatchRun,
        where: r.work_item_id == ^row.id and not is_nil(r.workflow),
        order_by: [desc: r.take_in, desc: r.attempt]
    )
    |> Enum.map(fn run ->
      %{
        id: run.attempt,
        workflow: run.workflow,
        round: run.round,
        verdict: verdict(verdicts[run.id]),
        state: if(run.id in stopped, do: :stopped, else: run_state(run))
      }
    end)
  end

  defp run_state(%{state: :ended, end_cause: :run_ended, result_outcome: outcome})
       when outcome not in [:error, :refused],
       do: :ended

  defp run_state(%{state: :ended}), do: :stopped
  defp run_state(_run), do: :running

  defp verdict(nil), do: nil

  defp verdict(version) do
    case Stages.Artifacts.read_json(version) do
      %{"verdict" => verdict} -> verdict_value(verdict)
      _other -> nil
    end
  end

  defp verdict_value(verdict) when is_binary(verdict), do: Map.get(@verdicts, verdict)
  defp verdict_value(_none), do: nil

  defp input(input) do
    %{
      type: get(input, :type),
      required: get(input, :required) == true,
      version: number_of(get(input, :version))
    }
  end

  defp output(output) do
    check = get(output, :check)

    %{
      type: get(output, :type),
      required: get(output, :required) == true,
      version: number_of(get(output, :version)),
      version_id: id_of(get(output, :version)),
      check: if(check in @checks, do: check, else: :missing)
    }
  end

  defp escalation(nil), do: nil

  defp escalation(escalation) do
    cause = get(escalation, :cause)
    cause = if is_atom(cause) and not is_nil(cause), do: Atom.to_string(cause), else: cause

    run = get(escalation, :run)

    %{
      cause: Map.get(@causes, cause, :escalate),
      gaps: lines(get(escalation, :gaps)),
      round: get(escalation, :round),
      run: run && %{number: get(run, :attempt), workflow: get(run, :workflow)}
    }
  end

  # An artifact of the index with its approval marks: the number of the version a gate
  # approved, and of a newer one where there is one.
  defp indexed(artifact) do
    versions = get(artifact, :versions) || []
    approved = Enum.find(versions, &(get(&1, :id) == get(artifact, :approved_version)))
    newest = List.first(versions)
    approved = approved && get(approved, :number)
    newest = newest && get(newest, :number)

    %{
      type: get(artifact, :type),
      name: get(artifact, :name) || "main",
      approved: approved,
      newer: if(approved && newest && newest > approved, do: newest),
      changed_after_approval: get(artifact, :changed_after_approval) == true
    }
  end

  # Who approves the stage's gate: any member, or the members it lists.
  defp approvers(%{gate: gate}) do
    case get(gate, :approvers) do
      %{} = listed -> {:listed, get(listed, :members) || []}
      _members -> :members
    end
  end

  defp approvers(_stage), do: :members

  defp approver?(%Scope{user: %{id: id}}, stage) do
    case approvers(stage) do
      :members -> true
      {:listed, ids} -> id in ids
    end
  end

  defp approver?(_scope, _stage), do: false

  ## What a reader does

  @doc false
  # decide/4 does `action` on `row` for the reader of `scope`, after it asks again,
  # with the scope read from the database, whether the reader may: `gate.approve`, and
  # the stage's listed approvers where it lists them; `{:error, :forbidden}` otherwise.
  # `page` is the page as the reader saw it, for the stage and the earlier stages.
  @spec decide(Scope.t(), struct, map, tuple) :: {:ok, term} | {:error, term}
  def decide(scope, row, page, action) do
    with :ok <- Access.authorize(scope, :"gate.approve", row),
         true <- approver?(scope, page.stage) || {:error, :forbidden},
         {:ok, action} <- checked(action, page) do
      case action do
        {:approve, note} -> Stages.approve(scope, row, note)
        {:request_changes, note, av} -> Stages.request_changes(scope, row, note, av)
        {:resolve, how, note} -> Stages.resolve_escalation(scope, row, how, note)
        {:move, stage_id, note} -> Stages.move(scope, row, stage_id, note)
      end
    end
  end

  # An action the page offered: a move back only to an earlier stage, a Request changes
  # only about a version at the gate.
  #
  # At Explore's gate, a member confirms the proposal (`Apiary.WorkItems.confirm/4`),
  # which approves the gate: the page offers no Approve and no Request changes there.
  defp checked({:approve, _note}, %{confirm_gate: true}), do: {:error, :confirm_gate}

  defp checked({:request_changes, _note, _id}, %{confirm_gate: true}),
    do: {:error, :confirm_gate}

  defp checked({:resolve, {:move_back, id}, _note} = action, page),
    do: if(earlier?(page, id), do: {:ok, action}, else: {:error, :invalid})

  defp checked({:move, id, _note} = action, page),
    do: if(earlier?(page, id), do: {:ok, action}, else: {:error, :invalid})

  defp checked({:request_changes, _note, nil} = action, _page), do: {:ok, action}

  defp checked({:request_changes, _note, id} = action, page),
    do:
      if(Enum.any?(page.outputs, &(&1.version_id == id)),
        do: {:ok, action},
        else: {:error, :invalid}
      )

  defp checked(action, _page), do: {:ok, action}

  defp earlier?(page, id), do: Enum.any?(page.earlier, &(&1.id == id))

  @doc false
  # check/3 reads again whether the harness lists the workflows of the work item's stage
  # while it waits for one (`Apiary.Stages.check_workflows/2`), for a reader who may act
  # on the stage, asked again with the scope read from the database:
  # `{:ok, work_item}` once the stage started, `{:error, :still_missing}`, or another
  # `{:error, reason}`.
  @spec check(Scope.t(), struct, map) :: {:ok, struct} | {:error, term}
  def check(scope, row, page) do
    with :ok <- Access.authorize(scope, :"gate.approve", row),
         true <- approver?(scope, page.stage) || {:error, :forbidden} do
      module(:workflow_checks).check_workflows(scope, row)
    end
  end

  ## The board

  @doc false
  # board/1 is the board's columns for the scope's workspace: one for each stage of its
  # current process version, in order, then one for each stage that version removed
  # while a live work item is still in it, marked with the version that has it. A work
  # item on another version sits in the stage with the same id. Each column lists its
  # work items in the list's `sort`.
  @spec board(Scope.t(), :updated | :created) :: [map]
  def board(scope, sort \\ :updated) do
    current = Processes.current(scope.workspace)
    versions = Processes.list_versions(scope.workspace)
    stages = Enum.map(get(get(current, :document) || %{}, :stages) || [], &stage_map/1)
    first = List.first(stages)

    # A work item the process has not placed yet sits in the first stage, where every
    # work item starts.
    rows =
      for row <- Board.rows(scope, sort),
          do: if(is_nil(row.stage_id) and first, do: %{row | stage_id: first.id}, else: row)

    ids = MapSet.new(stages, & &1.id)
    by_stage = Enum.group_by(rows, & &1.stage_id)

    columns =
      for stage <- stages do
        %{id: stage.id, name: stage.name, version: nil, items: Map.get(by_stage, stage.id, [])}
      end

    removed =
      rows
      |> Enum.reject(&MapSet.member?(ids, &1.stage_id))
      |> Enum.group_by(& &1.stage_id)
      |> Enum.map(fn {id, items} -> removed_column(id, items, versions) end)
      |> Enum.sort_by(&{-(&1.version || 0), &1.name || ""})

    columns ++ removed
  end

  # A stage the current version removed: its name and the newest version of its work
  # items that has it.
  defp removed_column(id, items, versions) do
    on = MapSet.new(items, & &1.process_version_id)

    version =
      versions
      |> Enum.filter(&MapSet.member?(on, get(&1, :id)))
      |> Enum.sort_by(&(-(get(&1, :number) || 0)))
      |> Enum.find(fn version ->
        Enum.any?(get(get(version, :document) || %{}, :stages) || [], &(get(&1, :id) == id))
      end)

    stage =
      Enum.find(get(get(version, :document) || %{}, :stages) || [], %{}, &(get(&1, :id) == id))

    %{
      id: id,
      name: get(stage, :name) || id,
      version: version && get(version, :number),
      items: items
    }
  end

  ## Reading the contract's maps

  # A field of a map from the contract: by its atom key, or its string key where the map
  # came from a JSON document.
  defp get(nil, _key), do: nil

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil

  defp id_of(nil), do: nil
  defp id_of(id) when is_binary(id), do: id
  defp id_of(map), do: get(map, :id)

  defp name_of(map) when is_map(map), do: get(map, :name)
  defp name_of(_other), do: nil

  defp number_of(nil), do: nil
  defp number_of(n) when is_integer(n), do: n
  defp number_of(map), do: get(map, :number)

  # Gaps as lines: a text's non-blank lines, without a list mark; a list as it is.
  defp lines(nil), do: []
  defp lines(list) when is_list(list), do: Enum.filter(list, &is_binary/1)

  defp lines(text) when is_binary(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^[-*•]\s+/u, "")))
    |> Enum.reject(&(&1 == ""))
  end

  defp lines(_other), do: []
end
