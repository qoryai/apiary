defmodule ApiaryWeb.WorkItemLive.Workflow do
  # The workflow model on the work item page and the board, under the feature
  # `workflow_model`: what the pages read and do through `Apiary.Stages`,
  # `Apiary.Processes` and `Apiary.Artifacts`, and the plain maps the stage parts draw
  # (`ApiaryWeb.WorkItemLive.StageComponents`).
  #
  # **Check again.** `check/3` calls `Apiary.Stages.check_workflows/2`, which reads the
  # harness through its adapter. A test puts the read in the environment
  # (`harness_read`, a function of the scope and the workspace) in place of the adapter.
  #
  # **The work item's topics.** `subscribe/2` subscribes to the stage runner's topic of the
  # work item (`Apiary.Stages.subscribe/1`), where `{:stage_changed, id}` arrives, and to
  # its artifacts' (`Apiary.Artifacts.subscribe/2`), where `{:artifact_pushed, work_item_id,
  # version_id}` arrives.
  #
  # **The runs.** `Apiary.Stages.runs/1` of the current take in, each numbered by its
  # attempt in the take in, not the run's number in its workspace. A run whose `questions`
  # artifact has a version shows as questions: the versions carry the run of the queue, so
  # `runs/2` reads the registered runs' links to it (`runs`). A paused run with no verdict
  # that a run continues shows why it paused and the run that continues it
  # (`Apiary.Dispatches.Pause`, `with_pauses/2`).
  #
  # **The feature.** `on?/1` is whether the reader is shown `workflow_model`. A work item
  # the stage runner has not placed (`Apiary.Stages.status/2` is nil) draws as before the
  # feature.
  #
  # **Who decides.** A gate's Approve and Request changes, every escalation action and a
  # move back take `gate.approve`, which `Apiary.Access` allows only for the stage's
  # listed approvers where the stage lists them; Add takes `artifact.write`. The page
  # hides a button from everyone else, and checks again with the scope read from the
  # database on every event (`decide/4`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :verified_routes

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Artifacts, Features, Processes, Repo, Stages, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.Pause
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Approvers, Runner}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkItemLive.{StageComponents, View}

  @states Apiary.Processes.Version.stage_states()
  @checks [:passed, :missing, :not_checked]
  @causes %{
    "round_limit" => :round_limit,
    "escalate" => :escalate,
    "check_failed" => :check_failed,
    "run_stopped" => :run_stopped
  }

  @doc false
  # on?/1 is whether the reader of `scope` is shown the workflow model: the instance has
  # the feature `workflow_model`, and the scope does not hide it.
  @spec on?(Scope.t()) :: boolean
  def on?(scope), do: Features.visible?(scope, :workflow_model)

  ## The work item page

  @doc false
  # subscribe/2 subscribes the calling process to the topics of `row` that tell a change of
  # its stage or a pushed artifact.
  @spec subscribe(Scope.t(), struct) :: :ok | {:error, term}
  def subscribe(scope, row) do
    :ok = Stages.subscribe(row)
    Artifacts.subscribe(scope, row)
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
    runs = runs(row, index)
    document = get(version, :document) || %{}
    all = Enum.map(get(document, :stages) || [], &stage_map/1)
    current_id = id_of(get(status, :stage))
    at = Enum.find_index(all, &(&1.id == current_id))
    state = state(get(status, :state))
    outputs = Enum.map(get(status, :outputs) || [], &output/1)

    stage =
      Enum.find(
        all,
        %{id: current_id, name: name_of(get(status, :stage))},
        &(&1.id == current_id)
      )

    explore_id = Stages.explore_stage_id(row)
    runs = scope |> with_paths(runs, current_id, explore_id) |> with_pauses(scope)

    %{
      version: get(get(status, :version), :number) || get(version, :number),
      stages: track(all, at, state),
      stage: stage,
      state: state,
      # The stage runs, and its newest run still waits for a machine.
      queued: state == :running and match?([%{shows: :queued} | _], runs),
      round: get(status, :round),
      rounds: shown_rounds(get(status, :round), get(status, :rounds)),
      # Whether the work item is in a loop, whose limit `rounds` is.
      loop: get(status, :loop) == true,
      gaps: lines(get(status, :gaps)),
      runs: runs,
      notes: Enum.map(Stages.notes(row), &note(&1, all)),
      inputs: Enum.map(get(status, :inputs) || [], &input/1),
      outputs: outputs,
      escalation: escalation(scope, get(status, :escalation), runs, outputs),
      approvers: approvers(stage),
      # The gate's approvers from `Apiary.Stages.status/2`: `:members`, or account ids.
      gate_approvers: get(get(status, :gate) || %{}, :approvers) || :members,
      gate_kind: get(get(status, :gate) || %{}, :kind),
      approvable: get(get(status, :gate) || %{}, :approvable?) == true,
      index: Enum.map(index, &indexed/1),
      earlier: if(at, do: Enum.take(all, at), else: []),
      missing_workflows: List.wrap(get(status, :waiting_workflow)),
      missing_outputs: List.wrap(get(status, :missing_outputs)),
      confirm_gate: false,
      explore: false,
      at_explore: stage.id == explore_id,
      explore_id: explore_id,
      tabs: [],
      ended: false,
      can_decide: Access.can?(scope, :"gate.approve", row),
      can_add: Access.can?(scope, :"artifact.write", row)
    }
  end

  # The round limit as the card counts it: Run another round at the limit runs one round
  # more, which is then the last before the stage escalates again, so the count is never
  # under the round.
  defp shown_rounds(round, rounds) when is_integer(round) and is_integer(rounds),
    do: max(round, rounds)

  defp shown_rounds(_round, rounds), do: rounds

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
      sequence: get(stage, :sequence) || [],
      outputs: for(output <- get(stage, :outputs) || [], do: get(output, :type))
    }
  end

  defp state(state) when state in @states, do: state

  defp state(state) when is_binary(state),
    do: Enum.find(@states, :running, &(Atom.to_string(&1) == state))

  defp state(_state), do: :running

  # The runs of the work item's current take in, newest first, each numbered by its attempt
  # in the take in, as the step card and Details count it, with its workflow, its round,
  # and what it gave: its verdict, its questions, or, with neither, its state.
  defp runs(row, index) do
    all = Stages.runs(row)
    take_in = current_take_in(row, all)
    runs = Enum.filter(all, &(&1.take_in == take_in))
    asked = asked(runs, index)

    for run <- runs do
      %{
        id: run.id,
        number: run.attempt,
        attempt: run.attempt,
        run_number: nil,
        stage_id: run.stage_id,
        path: nil,
        workflow: run.workflow,
        round: run.round,
        shows: shows(run, asked),
        paused: nil,
        paused_path: nil
      }
    end
  end

  # While the work item is at Explore, each of Explore's runs has the path of its page, by
  # the rule of the Explore tab's run links (`View.run_path/2`). At a later stage, and for
  # a later stage's run, the path stays nil.
  defp with_paths(scope, runs, explore_id, explore_id) do
    ids = for %{id: id, stage_id: ^explore_id} when is_binary(id) <- runs, do: id

    rows =
      Repo.all(
        from r in Run.registered(),
          where: r.public_id in ^ids,
          select: {r.public_id, %{number: r.number, workspace_id: r.workspace_id}}
      )
      |> Map.new()

    ctx = %{
      scope: scope,
      readable: View.readable(scope, Enum.map(Map.values(rows), & &1.workspace_id))
    }

    for run <- runs do
      row = rows[run.id]
      %{run | path: View.run_path(ctx, row), run_number: row && row.number}
    end
  end

  defp with_paths(_scope, runs, _stage_id, _explore_id), do: runs

  # Each paused run that shows no verdict, with why it paused and the path of the run
  # that continues it, where the reader may read that run's workspace.
  defp with_pauses(runs, scope) do
    pauses = Pause.of_public_ids(for %{id: id} when is_binary(id) <- runs, do: id)

    ctx = %{
      scope: scope,
      readable: View.readable(scope, Enum.map(Map.values(pauses), & &1.workspace_id))
    }

    for run <- runs do
      case pauses[run.id] do
        %{} = pause when run.shows == :no_verdict ->
          %{run | shows: :paused, paused: pause, paused_path: View.run_path(ctx, pause)}

        _other ->
          run
      end
    end
  end

  # The work item's take in, else the take in of its newest run.
  defp current_take_in(%{take_in: take_in}, _runs) when is_integer(take_in), do: take_in
  defp current_take_in(_row, [run | _runs]), do: run.take_in
  defp current_take_in(_row, []), do: nil

  # The registered runs (`rn_…`) whose run of the queue has a `questions` version.
  defp asked(runs, index) do
    queued =
      for %{type: "questions"} = artifact <- index,
          version <- Map.get(artifact, :versions, []),
          is_binary(version[:run_id]),
          do: version.run_id

    registered(runs, queued)
  end

  # The public ids (`rn_…`) of `runs` whose run of the queue is one of `queued`.
  defp registered(runs, queued) do
    ids = for %{id: id} when is_binary(id) <- runs, do: id

    if queued == [] or ids == [] do
      MapSet.new()
    else
      Repo.all(
        from r in Run.registered(),
          where: r.public_id in ^ids and r.dispatch_run_id in ^Enum.uniq(queued),
          select: r.public_id
      )
      |> MapSet.new()
    end
  end

  # What a run shows: its verdict, queued or running, its questions; a run an undo of its
  # take in ended, undone; an ended run with neither ended without a verdict. The page
  # does not tell a run that ended with a result from one that stopped.
  defp shows(%{verdict: verdict}, _asked) when verdict in [:passed, :failed], do: verdict
  defp shows(%{status: :ended, end_cause: :undone}, _asked), do: :undone
  defp shows(%{status: status}, _asked) when status in [:waiting, :claimed], do: :queued
  defp shows(%{status: :handed_over}, _asked), do: :running

  defp shows(%{id: id}, asked) when is_binary(id) do
    if MapSet.member?(asked, id), do: :questions, else: :no_verdict
  end

  defp shows(_run, _asked), do: :no_verdict

  # The set-up step Harness, where an escalation's fix is on it (`set_up_step: :harness`).
  defp harness_path(%Scope{organisation: organisation, workspace: workspace}, :harness),
    do: ~p"/#{organisation}/#{workspace}/set-up/harness"

  defp harness_path(_scope, _step), do: nil

  # The run an escalation came from, as the run list numbers it: the run whose page has
  # the failed build's log (`build_run`, `rn_…`), else the run that stopped or escalated,
  # by the registered run of its run of the queue.
  defp escalated_run(escalation, runs) do
    queued = get(get(escalation, :run), :id)

    id =
      get(escalation, :build_run) ||
        (queued &&
           Repo.one(
             from r in Run.registered(),
               where: r.dispatch_run_id == ^queued,
               select: r.public_id,
               limit: 1
           ))

    Enum.find(runs, &(is_binary(id) and &1.id == id))
  end

  # A note the next run reads, with the name of its stage in the version.
  defp note(note, stages) do
    %{
      kind: note.kind,
      comment: Map.get(note, :comment) == true,
      stage: Enum.find_value(stages, &(&1.id == note.stage_id && &1.name)),
      text: note.note
    }
  end

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

  defp escalation(_scope, nil, _runs, _outputs), do: nil

  defp escalation(scope, escalation, runs, outputs) do
    cause = get(escalation, :cause)
    cause = if is_atom(cause) and not is_nil(cause), do: Atom.to_string(cause), else: cause
    cause = Map.get(@causes, cause, :escalate)

    run = escalated_run(escalation, runs)

    %{
      cause: cause,
      result: result?(cause, outputs, get(escalation, :no_verdict) == true, run),
      points: points(get(escalation, :points)),
      round: get(escalation, :round),
      run: run,
      harness_path: harness_path(scope, get(escalation, :set_up_step))
    }
  end

  # An escalation's points as the block "What the run needs from you" shows them: each
  # with its text, its action (`:answer` or `:run_again`) and, for `:answer`, the id of
  # its question. A point without text is left out.
  defp points(points) when is_list(points) do
    for %{} = point <- points, text = get(point, :text), is_binary(text) and text != "" do
      case get(point, :action) do
        action when action in ["answer", :answer] ->
          %{text: text, action: :answer, question: get(point, :question)}

        _run_again ->
          %{text: text, action: :run_again, question: nil, fix: get(point, :fix)}
      end
    end
  end

  defp points(_none), do: []

  # Whether the stage has a result to accept as it is: a version of one of its outputs; for
  # a stage with no outputs, a run that did not stop before its verdict; or a run of the
  # stage that ended with no verdict (`no_verdict`, `Apiary.Stages.status/2`) where no
  # output is required. The run of an escalation the migration placed has no stage, so the
  # page lists it nowhere (`Apiary.Stages.runs/1`) and that clause does not apply to it.
  defp result?(:run_stopped, outputs, true, %{}),
    do: Enum.any?(outputs, & &1.version_id) or not Enum.any?(outputs, & &1.required)

  defp result?(cause, [], _no_verdict, _run), do: cause != :run_stopped
  defp result?(_cause, outputs, _no_verdict, _run), do: Enum.any?(outputs, & &1.version_id)

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

  ## The list's rows

  # Explore's statuses (`Apiary.WorkItems.explore/3`) under which a work item at Explore
  # keeps Explore's words, as the work item page's head does.
  @explore_statuses [
    :queued,
    :running,
    :questions,
    :used_up,
    :no_result,
    :lost,
    :cancelled,
    :confirm
  ]

  @doc false
  # row_statuses/3 is, for the Work items list's rows (`Apiary.WorkItems.WorkList`), the
  # status each live work item the stage runner placed shows in place of Explore's words,
  # by the row's id: the stage and its state, with its mark, as the work item page's head
  # shows them (`ApiaryWeb.WorkItemLive.StageComponents.head_status/1`), or, for rows under
  # their stage's group (`grouped`), the state alone
  # (`ApiaryWeb.WorkItemLive.StageComponents.group_status/1`). A row is left out, and keeps
  # Explore's words, where it is not placed, or is at Explore while a run, its questions
  # or its gate are what the stage is at. A row that ended keeps its words, and has a mark
  # alone: `:done` where every stage is done, else `:stopped`.
  @spec row_statuses(Scope.t(), [map], boolean) :: %{String.t() => map}
  def row_statuses(scope, rows, grouped \\ false)

  def row_statuses(_scope, [], _grouped), do: %{}

  def row_statuses(%Scope{workspace: workspace} = scope, rows, grouped) do
    placed = placed(workspace, for(%{id: id, state: :exploring} <- rows, do: id))

    status =
      if grouped, do: &StageComponents.group_status/1, else: &StageComponents.head_status/1

    for %{id: id} = row <- rows, work_item = placed[id], into: %{} do
      {id, row_status(scope, row, work_item, status)}
    end
    |> Enum.reject(fn {_id, status} -> is_nil(status) end)
    |> Map.new()
    |> Map.merge(ended_marks(rows))
  end

  defp ended_marks(rows) do
    for %{id: id, state: state} = row <- rows, state in [:closed, :undone], into: %{} do
      {id, %{mark: if(row[:ended_reason] == "last_stage_done", do: :done, else: :stopped)}}
    end
  end

  defp row_status(scope, row, work_item, status) do
    raw = placed_stage(work_item)
    state = state(work_item.stage_state)

    cond do
      is_nil(raw) ->
        nil

      "explore-a-ticket" in Runner.workflows(raw) and
        state in [:running, :waiting_answers, :at_gate] and row.status in @explore_statuses ->
        nil

      true ->
        stage = stage_map(raw)

        status.(%{
          stage: stage,
          state: state,
          queued: state == :running and row.status == :queued,
          can_decide: Access.can?(scope, :"gate.approve", work_item)
        })
    end
  end

  @doc false
  # row_confirmers/3 is, for the Work items list's rows (`Apiary.WorkItems.WorkList`) whose
  # proposal waits at Explore's gate, who confirms next where the stage the work item is
  # in lists its approvers, by the row's id: `:you` where the reader may confirm
  # (`work_item.confirm`, `Apiary.Access`), else the listed account ids, in the gate's
  # order. `:left_explore` for a work item at a later stage, as the work item page reads
  # it (`Apiary.Stages.explore_stage_id/1`): no one confirms there. A row whose stage
  # lists no one, or that the stage runner did not place, is left out, and keeps the
  # owner rule. The same queries for any number of rows (`placed/2`). `opts` as
  # `Apiary.WorkItems.WorkList.list/4` reads them.
  @spec row_confirmers(Scope.t(), [map], keyword) ::
          %{String.t() => :you | [Ecto.UUID.t()] | :left_explore}
  def row_confirmers(%Scope{workspace: workspace} = scope, rows, opts \\ []) do
    ids = for %{id: id, state: :exploring, status: :confirm} <- rows, do: id
    placed = placed(workspace, ids)

    explore =
      if placed != %{},
        do:
          Keyword.get_lazy(opts, :explore_workflow, fn -> Stages.explore_workflow(workspace) end)

    for {id, work_item} <- placed,
        confirmers when not is_nil(confirmers) <- [row_confirmer(scope, work_item, explore)],
        into: %{},
        do: {id, confirmers}
  end

  defp row_confirmer(scope, work_item, explore) do
    listed = listed(placed_stage(work_item))

    cond do
      work_item.stage_id != Stages.explore_stage_in(work_item.process_version, explore) ->
        :left_explore

      not match?([_ | _], listed) ->
        nil

      Access.can?(scope, :"work_item.confirm", work_item) ->
        :you

      true ->
        listed
    end
  end

  defp listed(nil), do: :members
  defp listed(stage), do: Approvers.listed(stage)

  # The work items of the public ids `ids` that the stage runner placed, by public id, each
  # with its process version loaded (the workspace's current one for a work item with
  # none), so that `Apiary.Access` reads no version per work item: a query for the work
  # items, one for the workspace's versions and one for its current version.
  defp placed(_workspace, []), do: %{}

  defp placed(%{id: workspace_id} = workspace, ids) do
    work_items =
      Repo.all(
        from w in WorkItem,
          where: w.workspace_id == ^workspace_id and w.public_id in ^ids,
          where: not is_nil(w.stage_id) and not is_nil(w.stage_state)
      )

    if work_items == [] do
      %{}
    else
      by_id = Map.new(Processes.list_versions(workspace), &{&1.id, &1})
      current = Processes.current(workspace)

      Map.new(work_items, fn work_item ->
        version = Map.get(by_id, work_item.process_version_id, current)
        {work_item.public_id, %{work_item | process_version: version}}
      end)
    end
  end

  # The stage of its process version that the placed work item `work_item` is in, as the
  # version's document has it; nil for none.
  defp placed_stage(%WorkItem{process_version: version, stage_id: stage_id}),
    do: Enum.find(stages_of(version), &(get(&1, :id) == stage_id))

  ## What a reader does

  @doc false
  # decide/4 does `action` on `row` for the reader of `scope`, after it asks again,
  # with the scope read from the database, whether the reader may: `gate.approve`
  # (`Apiary.Access`), which only the stage's listed approvers have where it lists them;
  # `{:error, :forbidden}` or `{:error, :not_approver}` otherwise.
  # `page` is the page as the reader saw it, for the stage and the earlier stages.
  @spec decide(Scope.t(), struct, map, tuple) :: {:ok, term} | {:error, term}
  def decide(scope, row, page, action) do
    expect = [expect_stage: page.stage.id]

    with :ok <- Access.authorize(scope, :"gate.approve", row),
         {:ok, action} <- checked(action, page) do
      case action do
        {:approve, note} -> Stages.approve(scope, row, note, expect)
        {:request_changes, note, av} -> Stages.request_changes(scope, row, note, av, expect)
        {:resolve, how, note} -> Stages.resolve_escalation(scope, row, how, note, expect)
        {:move, stage_id, note} -> Stages.move(scope, row, stage_id, note, expect)
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

  # Accept as it is only where the stage has a result: the page offers it nowhere else.
  defp checked({:resolve, :accept, _note}, %{escalation: %{result: false}}),
    do: {:error, :invalid}

  defp checked({:resolve, {:move_back, id}, _note} = action, page), do: back(action, id, page)
  defp checked({:move, id, _note} = action, page), do: back(action, id, page)

  defp checked({:request_changes, _note, nil} = action, _page), do: {:ok, action}

  defp checked({:request_changes, _note, id} = action, page),
    do:
      if(Enum.any?(page.outputs, &(&1.version_id == id)),
        do: {:ok, action},
        else: {:error, :invalid}
      )

  defp checked(action, _page), do: {:ok, action}

  # A move back: to an earlier stage of the version, `:not_earlier` for a later one, and
  # `:unknown_stage` for a stage the version does not have.
  defp back(action, id, page) do
    cond do
      Enum.any?(page.earlier, &(&1.id == id)) -> {:ok, action}
      Enum.any?(page.stages, &(&1.id == id)) -> {:error, :not_earlier}
      true -> {:error, :unknown_stage}
    end
  end

  @doc false
  # check/2 reads again whether the harness lists the workflows of the work item's stage
  # while it waits for one (`Apiary.Stages.check_workflows/2`), for a reader who may act
  # on the stage (`gate.approve`, `Apiary.Access`), checked again with the scope read from
  # the database: `{:ok, work_item}` once the stage started, `{:error, :still_missing}`,
  # or another `{:error, reason}`.
  @spec check(Scope.t(), struct) :: {:ok, struct} | {:error, term}
  def check(scope, row) do
    with :ok <- Access.authorize(scope, :"gate.approve", row) do
      case Application.get_env(:apiary, __MODULE__, [])[:harness_read] do
        nil -> Stages.check_workflows(scope, row)
        read -> Stages.check_workflows(scope, row, read)
      end
    end
  end

  ## The board

  @doc false
  # board/3 is the board's columns for the scope's workspace, each with how many live work
  # items are in it under the search and the filters of `params`
  # (`Apiary.WorkItems.list_stage_counts/3`): one for each stage of its current process
  # version, in order, then one for each stage that version removed while a live work item
  # is still in it, marked with the version that has it. A work item on another version
  # counts in the stage with the same id, and one the process has not placed yet in the
  # first stage, where every work item starts.
  # nil where the current version has no stage (`Apiary.Processes.current/1` makes
  # version 1 for a workspace with none): the list then shows as before the feature.
  @spec board(Scope.t(), map, DateTime.t()) :: [map] | nil
  def board(scope, params, now) do
    current = Processes.current(scope.workspace)

    if stages_of(current) == [],
      do: nil,
      else: columns(scope, WorkItems.list_stage_counts(scope, params, now), current)
  end

  defp columns(scope, counts, current) do
    versions = Processes.list_versions(scope.workspace)
    stages = Enum.map(stages_of(current), &stage_map/1)
    first = hd(stages)
    counts = for row <- counts, do: %{row | stage_id: row.stage_id || first.id}

    ids = MapSet.new(stages, & &1.id)
    by_stage = Enum.group_by(counts, & &1.stage_id)

    columns =
      for stage <- stages do
        %{
          id: stage.id,
          name: stage.name,
          removed: false,
          version: nil,
          count: total(Map.get(by_stage, stage.id, []))
        }
      end

    removed =
      counts
      |> Enum.reject(&MapSet.member?(ids, &1.stage_id))
      |> Enum.group_by(& &1.stage_id)
      |> Enum.map(fn {id, stage_counts} -> removed_column(id, stage_counts, versions) end)
      |> Enum.sort_by(&{-(&1.version || 0), &1.name || ""})

    columns ++ removed
  end

  defp total(stage_counts), do: stage_counts |> Enum.map(& &1.count) |> Enum.sum()

  @doc false
  # groups/2 is the Open view's rows by the board's columns, in the board's order: a group
  # for each column with a row, with the column's place on the board (`index`), name and
  # count, and its rows in their order. A row the process has not placed yet is in the
  # first column.
  @spec groups([map], [map]) :: [map]
  def groups([first | _columns] = board, rows) do
    by_stage = Enum.group_by(rows, &(&1.stage_id || first.id))

    for {column, index} <- Enum.with_index(board), rows = by_stage[column.id] do
      %{index: index, name: column.name, count: column.count, rows: rows}
    end
  end

  # A stage the current version removed: its name and number in the newest version of its
  # work items that has it, else in the newest version of the workspace that has it; nil
  # for both where no version has it.
  defp removed_column(id, stage_counts, versions) do
    on = MapSet.new(stage_counts, & &1.process_version_id)
    has? = fn version -> Enum.any?(stages_of(version), &(get(&1, :id) == id)) end
    newest = Enum.sort_by(versions, &(-(get(&1, :number) || 0)))

    version =
      Enum.find(newest, &(MapSet.member?(on, get(&1, :id)) and has?.(&1))) ||
        Enum.find(newest, has?)

    stage = Enum.find(stages_of(version), %{}, &(get(&1, :id) == id))

    %{
      id: id,
      name: get(stage, :name),
      removed: true,
      version: version && get(version, :number),
      count: total(stage_counts)
    }
  end

  defp stages_of(nil), do: []
  defp stages_of(version), do: get(get(version, :document) || %{}, :stages) || []

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
