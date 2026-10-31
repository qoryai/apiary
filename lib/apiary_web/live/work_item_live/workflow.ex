defmodule ApiaryWeb.WorkItemLive.Workflow do
  # The workflow model on the work item page and the board, under the feature
  # `workflow_model`: what the pages read and do through `Apiary.Stages`,
  # `Apiary.Processes` and `Apiary.Artifacts`, and the plain maps the stage parts draw
  # (`ApiaryWeb.WorkItemLive.StageComponents`).
  #
  # **The modules it calls.** Each one is read from the application's environment
  # (`config :apiary, ApiaryWeb.WorkItemLive.Workflow, stages: …`), with the shared
  # contract's module as the default: `features` (`Apiary.Features`), `access`
  # (`Apiary.Access`), `stages` (`Apiary.Stages`), `processes` (`Apiary.Processes`),
  # `artifacts` (`Apiary.Artifacts`), `artifact_components`
  # (`ApiaryWeb.ArtifactComponents`) and `board` (`ApiaryWeb.WorkItemLive.Board`). The
  # calls go through a variable, so the pages compile before those modules exist; the
  # tests put fakes there (`ApiaryWeb.WorkflowFake`).
  #
  # **The feature.** `on?/1` is false while the instance has no feature `workflow_model`,
  # so every page draws as before it.
  #
  # **Who decides.** A gate's Approve and Request changes, every escalation action and a
  # move back take `gate.approve`, and only the stage's listed approvers where the stage
  # lists them; Add takes `artifact.write`. The page hides a button from everyone else,
  # and asks again with the scope read from the database on every event (`decide/4`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Accounts.Scope

  @defaults [
    features: Apiary.Features,
    access: Apiary.Access,
    stages: Apiary.Stages,
    processes: Apiary.Processes,
    artifacts: Apiary.Artifacts,
    artifact_components: ApiaryWeb.ArtifactComponents,
    board: ApiaryWeb.WorkItemLive.Board
  ]

  @states ~w(running waiting_inputs waiting_answers waiting_workflow escalated at_gate done)a
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
  def on?(scope) do
    features = module(:features)
    :workflow_model in features.all() and features.visible?(scope, :workflow_model)
  end

  ## The work item page

  @doc false
  # page/2 is what the work item page draws of `row` under the workflow model: the
  # stages of its process version with the current one marked, the current stage with
  # its state, round and gaps, the runs, the inputs, the outputs at the gate, the
  # escalation, the artifacts' approval marks, and what the reader may do.
  @spec page(Scope.t(), struct) :: map
  def page(scope, row) do
    stages = module(:stages)
    status = stages.status(row)
    version = module(:processes).version_for(row)
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
      version: get(version, :number),
      stages: track(all, at, state),
      stage: stage,
      state: state,
      round: get(status, :round),
      rounds: get(status, :rounds),
      gaps: lines(get(status, :gaps)),
      runs: Enum.map(get(status, :runs) || [], &run/1),
      inputs: Enum.map(stages.inputs(row) || [], &input/1),
      outputs: Enum.map(get(status, :outputs) || [], &output/1),
      escalation: escalation(get(status, :escalation)),
      approvers: approvers(stage),
      approvable: get(get(status, :gate) || %{}, :approvable?) == true,
      index: Enum.map(stages.artifact_index(row) || [], &indexed/1),
      earlier: if(at, do: Enum.take(all, at), else: []),
      missing_workflows: missing_workflows(scope, stage, state),
      can_decide: approver?(scope, stage) and module(:access).can?(scope, :"gate.approve", row),
      can_add: module(:access).can?(scope, :"artifact.write", row)
    }
  end

  @doc false
  # artifacts/1 is every artifact of `row`, as `Apiary.Artifacts.list/1` gives them.
  @spec artifacts(struct) :: list
  def artifacts(row), do: module(:artifacts).list(row)

  @doc false
  # artifact_list/1 draws the plain list of artifacts, `ApiaryWeb.ArtifactComponents.list/1`.
  @spec artifact_list(map) :: Phoenix.LiveView.Rendered.t()
  def artifact_list(assigns), do: module(:artifact_components).list(assigns)

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

  defp run(run) do
    %{
      id: get(run, :id),
      workflow: get(run, :workflow),
      round: get(run, :round),
      verdict: verdict(get(run, :verdict)),
      state: get(run, :state)
    }
  end

  defp verdict(verdict) when is_atom(verdict) and not is_nil(verdict),
    do: verdict |> Atom.to_string() |> String.replace("_", "-") |> verdict()

  defp verdict(verdict) when is_binary(verdict), do: Map.get(@verdicts, verdict)
  defp verdict(_none), do: nil

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

    %{
      cause: Map.get(@causes, cause, :escalate),
      gaps: lines(get(escalation, :gaps)),
      round: get(escalation, :round),
      run_id: get(escalation, :run_id)
    }
  end

  defp indexed(artifact) do
    %{
      type: get(artifact, :type),
      name: get(artifact, :name) || "main",
      approved: get(artifact, :approved),
      newer: get(artifact, :newer),
      changed_after_approval: get(artifact, :changed_after_approval) == true
    }
  end

  # The workflows of the stage that the composed harness no longer declares, while the
  # stage waits for one.
  defp missing_workflows(scope, stage, :waiting_workflow) do
    declared = module(:processes).declared_workflows(scope.workspace) || []

    stage.sequence
    |> Enum.flat_map(fn entry ->
      case get(entry, :loop) do
        nil -> [get(entry, :workflow)]
        loop -> Enum.map(get(loop, :body) || [], &get(&1, :workflow))
      end
    end)
    |> Enum.reject(&(is_nil(&1) or &1 in declared))
    |> Enum.uniq()
  end

  defp missing_workflows(_scope, _stage, _state), do: []

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
    stages = module(:stages)

    with :ok <- module(:access).authorize(scope, :"gate.approve", row),
         true <- approver?(scope, page.stage) || {:error, :forbidden},
         {:ok, action} <- checked(action, page) do
      case action do
        {:approve, note} -> stages.approve(scope, row, note)
        {:request_changes, note, av} -> stages.request_changes(scope, row, note, av)
        {:resolve, how, note} -> stages.resolve_escalation(scope, row, how, note)
        {:move, stage_id, note} -> stages.move(scope, row, stage_id, note)
      end
    end
  end

  # An action the page offered: a move back only to an earlier stage, a Request changes
  # only about a version at the gate.
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

  ## The board

  @doc false
  # board/1 is the board's columns for the scope's workspace: one for each stage of its
  # current process version, in order, then one for each stage that version removed
  # while a live work item is still in it, marked with the version that has it. A work
  # item on another version sits in the stage with the same id.
  @spec board(Scope.t()) :: [map]
  def board(scope) do
    processes = module(:processes)
    current = processes.current(scope.workspace)
    versions = processes.list_versions(scope.workspace) || []
    rows = module(:board).rows(scope)
    stages = Enum.map(get(get(current, :document) || %{}, :stages) || [], &stage_map/1)
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
