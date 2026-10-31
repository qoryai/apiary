defmodule Apiary.Stages do
  # Stages is the stage runner of the workflow model (feature `workflow_model`): it moves a
  # work item through the stages of its process version (`Apiary.Processes`), starts the
  # runs of each stage's sequence, reads each run's end, opens the gate, and keeps the
  # people's decisions at gates (`Apiary.Stages.GateDecision`) and the escalations
  # (`Apiary.Stages.Escalation`). The rules are pure functions (`Apiary.Stages.Runner`);
  # this module reads the facts they need and applies what they decide.
  #
  # ## Where a work item is
  #
  # A work item keeps its process version, its stage, the stage's state, the round and
  # its position in the stage's sequence (`work_items.process_version_id`, `stage_id`,
  # `stage_state`, `stage_round`, `stage_entry`, `loop_entry`). Each run the runner starts
  # keeps the same, with its workflow and machine type (`dispatch_runs`). Every run is
  # queued through today's dispatch, for the step `explore`
  # (`Apiary.Dispatches.queue_stage/3`).
  #
  # ## Hand-over points (called only with the feature on)
  #
  #   * `take_in/2`, from `Apiary.Dispatches.queue/2`: a take in enters the first stage of
  #     the workspace's current version.
  #   * `next_run/2`, from `Apiary.Dispatches.queue_next/2`: answers to a run's questions,
  #     or Explore again after a run that stopped, run the stage's next round.
  #   * `run_ended/1`, from the end of a run (`Apiary.Dispatches.RunEnd.finish/5`) and from
  #     its settle (`Apiary.Dispatches.Settle.settle/1`), in their transaction: the runner
  #     reads what the run gave and acts. A run ended `run_ended` is read once what it gave
  #     is stored.
  #   * `confirmed/2`, from `Apiary.WorkItems.confirm/4`: a confirmation of Explore's
  #     proposal approves Explore's gate.
  #
  # ## Explore (decision D1, a transition until the harness change)
  #
  # A run of explore-a-ticket returns today's explore v1 result. The runner keeps a
  # proposal as a `proposal` version written by the run plus a `verdict` version
  # `passed`; questions as a `questions` version, and the stage waits for answers. A run
  # with no result, an invalid result, or one that stopped escalates, `run_stopped`, with
  # the cause. Any other workflow reports with artifacts: its newest `verdict` and its
  # `questions`.
  #
  # ## What a person does
  #
  # `approve/3`, `request_changes/4`, `resolve_escalation/4` and `move/4` ask
  # `gate.approve` (`Apiary.Access`) of the work item, and only the stage's listed
  # approvers may act where the stage lists them (by their account's id). Each writes one
  # entry in the audit trail, `gate.approve`, with `details.change` `approve`,
  # `request_changes`, `escalation_<resolution>` or `move`.
  #
  # ## What is told
  #
  # `{:stage_changed, public_id}` on the work items' topic of the workspace
  # (`Apiary.WorkItems.topic/1`), once the change commits; on a hand-over inside another
  # module's transaction, through what that module tells (`Apiary.Dispatches.broadcast/1`),
  # or, for a take in and an answer, at once.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Dispatches, Features, Processes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Artifacts, Escalation, GateDecision, Runner}
  alias Apiary.WorkItems.{Explore, Moves, Proposal, WorkItem}

  # Transition (D1): the workflow whose runs return today's explore v1 result.
  @explore_workflow "explore-a-ticket"
  @action :"gate.approve"
  @max_note 4000

  @typedoc "A resolution of an escalation."
  @type resolution :: :accept | :another_round | {:move_back, String.t()} | :close | :decline

  @typedoc "Why a person's action is refused."
  @type refusal ::
          :not_found
          | :forbidden
          | :not_placed
          | :not_at_gate
          | :not_escalated
          | :not_approver
          | :not_earlier
          | :unknown_stage
          | :not_live
          | {:invalid, :note}
          | term

  # on?/0 is whether the workflow model is on for the instance.
  @doc false
  @spec on?() :: boolean
  def on?, do: Features.on?(:workflow_model)

  ## Hand-over points

  # take_in/2 places the work item `id`, locked by the caller's transaction, at take in
  # `take_in` in the first stage of its workspace's current version, and starts it:
  # `{:ok, run}`, nil when the stage waits.
  @doc false
  @spec take_in(Ecto.UUID.t(), pos_integer) :: {:ok, DispatchRun.t() | nil}
  def take_in(id, _take_in) when is_binary(id) do
    in_transaction!()
    work_item = lock!(id)
    version = Processes.current(Repo.get!(Workspace, work_item.workspace_id))
    [first | _rest] = version.document["stages"]
    :ok = close_open(work_item, :close, nil, nil)
    {work_item, run} = enter_locked(%{work_item | process_version_id: version.id}, version, first)
    tell_now(work_item)
    {:ok, run}
  end

  # next_run/2 runs the next round of the stage of the work item `id`, locked by the
  # caller's transaction: after answers, the same workflow; after an escalation or a run
  # that stopped, another round. `{:ok, run}`; `{:error, :not_waiting}` when the stage
  # waits for a workflow; `:not_placed` for a work item the runner did not place.
  @doc false
  @spec next_run(Ecto.UUID.t(), pos_integer) ::
          {:ok, DispatchRun.t()} | {:error, :not_waiting} | :not_placed
  def next_run(id, _take_in) when is_binary(id) do
    in_transaction!()
    work_item = lock!(id)

    with {:ok, version, stage} <- placed(work_item) do
      event =
        case work_item.stage_state do
          :waiting_answers ->
            :answered

          :escalated ->
            case open_escalation(work_item) do
              %Escalation{cause: cause} = escalation ->
                :ok = resolve!(escalation, :another_round, nil, nil)
                {:another_round, cause}

              nil ->
                {:another_round, :run_stopped}
            end

          _stopped ->
            {:another_round, :run_stopped}
        end

      {work_item, run} = apply_event(work_item, version, stage, event)
      tell_now(work_item)
      if run, do: {:ok, run}, else: {:error, :not_waiting}
    else
      _not_placed -> :not_placed
    end
  end

  # hold_work_item/1 locks the work item of the run of the queue `dispatch_run_id`
  # `FOR UPDATE`, before the run is locked, in the order every path keeps.
  @doc false
  @spec hold_work_item(Ecto.UUID.t()) :: :ok
  def hold_work_item(dispatch_run_id) when is_binary(dispatch_run_id) do
    case Repo.one(from d in DispatchRun, where: d.id == ^dispatch_run_id, select: d.work_item_id) do
      nil -> :ok
      work_item_id -> lock!(work_item_id) && :ok
    end
  end

  # run_ended/1 acts on the end of the run of the queue `run`, or its id, inside the
  # caller's transaction, which holds its work item: when the run is the newest of its work
  # item's stage, the stage is running, and what the run gave is known. The work items to
  # tell once the transaction commits (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec run_ended(DispatchRun.t() | Ecto.UUID.t()) :: [Apiary.Dispatches.Settle.told()]
  def run_ended(%DispatchRun{id: id}), do: run_ended(id)

  def run_ended(id) when is_binary(id) do
    in_transaction!()

    with %DispatchRun{state: :ended, step: "explore", work_item_id: work_item_id} = run
         when is_binary(work_item_id) <- Repo.get(DispatchRun, id),
         %WorkItem{} = work_item <- lock!(work_item_id),
         true <- current_run?(work_item, run),
         {:ok, version, stage} <- placed(work_item),
         {:ok, result} <- run_result(work_item, run) do
      {work_item, _run} = apply_event(work_item, version, stage, {:run, result}, run.id)
      told(work_item)
    else
      _other -> []
    end
  end

  # confirmed/2 approves Explore's gate for the work item whose proposal the scope's
  # person confirmed in this transaction (`Apiary.WorkItems.confirm/4`). A confirmation
  # with changes first stores the person's `proposal` version.
  @doc false
  @spec confirmed(Scope.t(), WorkItem.t()) :: {:ok, WorkItem.t()} | {:error, term}
  def confirmed(%Scope{} = scope, %WorkItem{id: id}) do
    in_transaction!()
    work_item = lock!(id)

    with {:ok, version, stage} <- placed(work_item),
         :at_gate <- work_item.stage_state do
      confirmation = Explore.confirmation(work_item.id, work_item.take_in)

      with :ok <- if(may_approve?(scope, stage), do: :ok, else: {:error, :not_approver}),
           :ok <- person_proposal(scope, work_item, stage, confirmation),
           {:ok, work_item} <- approve_locked(scope, work_item, version, stage, nil, false) do
        tell_now(work_item)
        {:ok, work_item}
      end
    else
      _not_at_gate -> {:ok, work_item}
    end
  end

  defp person_proposal(_scope, _work_item, _stage, nil), do: :ok

  defp person_proposal(_scope, _work_item, _stage, %{changes: changes}) when changes == %{},
    do: :ok

  defp person_proposal(scope, work_item, stage, %{result: result, changes: changes}) do
    document = result |> proposal_document() |> with_changes(changes)

    case Artifacts.push_json({:person, scope}, work_item, "proposal", document,
           stage_id: stage["id"]
         ) do
      {:ok, _version} -> :ok
      {:error, _reason} = refused -> refused
    end
  end

  ## What a person does

  # enter/3 moves the work item into the stage `stage_id` of its version and starts it.
  # `cause` is what moved it, for the caller's records. Checks no access: `move/4` is the
  # person's move.
  @doc false
  @spec enter(WorkItem.t(), String.t(), atom) :: {:ok, WorkItem.t()} | {:error, refusal}
  def enter(%WorkItem{id: id}, stage_id, _cause) when is_binary(stage_id) do
    transact(fn ->
      work_item = lock!(id)
      version = Processes.version_for(work_item)

      case Processes.stage(version, stage_id) do
        nil ->
          {:error, :unknown_stage}

        stage ->
          :ok = close_open(work_item, :move_back, nil, nil)

          {work_item, _run} =
            enter_locked(%{work_item | process_version_id: version.id}, version, stage)

          {:ok, work_item}
      end
    end)
  end

  # resume/1 starts a stage that waits for a required input or for a workflow, once the
  # input exists or the harness declares the workflow: after a person adds an input, or
  # the harness changes. A stage in any other state is left as it is.
  @doc false
  @spec resume(WorkItem.t()) :: {:ok, WorkItem.t()} | {:error, refusal}
  def resume(%WorkItem{id: id}) do
    transact(fn ->
      work_item = lock!(id)

      with {:ok, version, stage} <- placed(work_item) do
        if work_item.stage_state in [:waiting_inputs, :waiting_workflow] do
          {work_item, _run} = apply_event(work_item, version, stage, :resume)
          {:ok, work_item}
        else
          {:ok, work_item}
        end
      end
    end)
  end

  # approve/3 approves the gate of the work item's stage, with the scope's person's
  # `note`: the decision covers the newest version of each output made in the stage, and
  # the work item enters the next stage, or its stage is done after the last. At Explore's
  # gate it confirms today's proposal first (`Apiary.WorkItems.Moves`).
  @doc false
  @spec approve(Scope.t(), WorkItem.t(), String.t() | nil) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def approve(%Scope{} = scope, %WorkItem{} = work_item, note) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item),
           :ok <- at_gate(work_item, stage),
           {:ok, confirmed?} <- confirm_explore(scope, work_item) do
        # A confirmation already wrote the act's entry in the audit trail.
        approve_locked(scope, lock!(work_item.id), version, stage, note, not confirmed?)
      end
    end)
  end

  # Today's confirmation, where Explore's proposal waits for it: the gate approves what a
  # member confirms, so the two are one act.
  defp confirm_explore(scope, work_item) do
    case Explore.current(work_item, DateTime.utc_now()) do
      %{status: :confirm, step: %{attempt: attempt}} ->
        case Moves.confirm(scope, work_item, attempt, nil) do
          {:ok, _work_item} -> {:ok, true}
          {:error, _refusal} = refused -> refused
        end

      _other ->
        {:ok, false}
    end
  end

  # An approval; `audit?` false where the confirmation of today's proposal wrote the act's
  # one entry in the trail.
  defp approve_locked(scope, work_item, version, stage, note, audit?) do
    covered = Enum.map(newest_outputs(work_item, stage), & &1.public_id)
    details = %{"stage_id" => stage["id"], "versions" => covered}

    with {:ok, _decision} <-
           decide(scope, work_item, version, stage, :approve, covered, nil, note),
         {:ok, _entry} <-
           if(audit?, do: audit(scope, work_item, "approve", details), else: {:ok, nil}) do
      {work_item, _run} = advance(work_item, version, stage)
      {:ok, work_item}
    end
  end

  # request_changes/4 runs the stage's sequence again from its first loop, or from its
  # start, with the person's note, which may point at one artifact version of the work
  # item (`av_…`).
  @doc false
  @spec request_changes(Scope.t(), WorkItem.t(), String.t() | nil, String.t() | nil) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def request_changes(%Scope{} = scope, %WorkItem{} = work_item, note, artifact_version_id) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item),
           :ok <- at_gate(work_item, stage),
           :ok <- version_of(work_item, artifact_version_id),
           {:ok, _decision} <-
             decide(
               scope,
               work_item,
               version,
               stage,
               :request_changes,
               [],
               artifact_version_id,
               note
             ),
           {:ok, _entry} <-
             audit(scope, work_item, "request_changes", %{
               "stage_id" => stage["id"],
               "artifact_version_id" => artifact_version_id
             }) do
        {work_item, _run} = apply_event(work_item, version, stage, :request_changes)
        {:ok, work_item}
      end
    end)
  end

  # resolve_escalation/4 acts on the work item's open escalation: accept it as it is, run
  # another round with the person's note, move the work item back to an earlier stage,
  # close it or decline it.
  @doc false
  @spec resolve_escalation(Scope.t(), WorkItem.t(), resolution, String.t() | nil) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def resolve_escalation(%Scope{} = scope, %WorkItem{} = work_item, resolution, note) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item),
           %Escalation{} = escalation <- escalation!(work_item, version, stage),
           {:ok, work_item} <-
             resolve(scope, work_item, version, stage, escalation, resolution, note),
           {:ok, _entry} <-
             audit(scope, work_item, "escalation_#{resolution_name(resolution)}", %{
               "stage_id" => stage["id"],
               "cause" => Atom.to_string(escalation.cause)
             }) do
        {:ok, work_item}
      end
    end)
  end

  defp resolve(scope, work_item, version, stage, escalation, resolution, note)
       when resolution in [:accept, :another_round] do
    :ok = resolve!(escalation, resolution, scope, note)
    event = {resolution, escalation.cause}
    {work_item, _run} = apply_event(work_item, version, stage, event)
    {:ok, work_item}
  end

  defp resolve(scope, work_item, version, stage, escalation, {:move_back, stage_id}, note) do
    with {:ok, target} <- earlier(version, stage, stage_id) do
      :ok = resolve!(escalation, :move_back, scope, note)
      {work_item, _run} = enter_locked(work_item, version, target)
      {:ok, work_item}
    end
  end

  defp resolve(scope, work_item, _version, _stage, escalation, resolution, note)
       when resolution in [:close, :decline] do
    :ok = resolve!(escalation, resolution, scope, note)

    result =
      if resolution == :close,
        do: Moves.close(scope, work_item),
        else: Moves.decline(scope, work_item)

    with {:ok, _ended} <- result, do: {:ok, lock!(work_item.id)}
  end

  defp resolve(_scope, _work_item, _version, _stage, _escalation, _resolution, _note),
    do: {:error, :invalid}

  defp resolution_name({:move_back, _stage_id}), do: "move_back"
  defp resolution_name(resolution) when is_atom(resolution), do: Atom.to_string(resolution)

  # move/4 moves the work item to the stage `stage_id` of its version, forward past a
  # stage or back, with the person's note, and starts that stage.
  @doc false
  @spec move(Scope.t(), WorkItem.t(), String.t(), String.t() | nil) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def move(%Scope{} = scope, %WorkItem{} = work_item, stage_id, note) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item),
           target when is_map(target) <-
             Processes.stage(version, stage_id) || {:error, :unknown_stage},
           {:ok, _entry} <-
             audit(scope, work_item, "move", %{
               "from" => stage["id"],
               "to" => target["id"],
               "note" => note
             }) do
        :ok = close_open(work_item, :move_back, scope, note)
        {work_item, _run} = enter_locked(work_item, version, target)
        {:ok, work_item}
      end
    end)
  end

  ## Reading

  # status/2 is where the work item stands in its stage, as the work item page draws it;
  # nil for a work item the runner has not placed. `scope`, when given, decides whether
  # its person may approve the gate.
  @doc false
  @spec status(WorkItem.t(), Scope.t() | nil) :: map | nil
  def status(%WorkItem{} = work_item, scope \\ nil) do
    work_item = Repo.get(WorkItem, work_item.id)

    with %WorkItem{} <- work_item,
         {:ok, version, stage} <- placed(work_item) do
      artifacts = Artifacts.list(work_item)
      escalation = open_escalation(work_item) || placed_escalation(work_item, version, stage)
      state = shown_state(work_item, stage, artifacts)

      %{
        stage: %{id: stage["id"], name: stage["name"]},
        version: %{id: version.public_id, number: version.number},
        round: work_item.stage_round,
        rounds: shown_rounds(stage, work_item.stage_entry),
        state: state,
        gaps: gaps(escalation, work_item, stage, artifacts),
        outputs: outputs(work_item, stage, artifacts),
        inputs: inputs(work_item, version, stage, artifacts),
        escalation: escalation_map(escalation),
        waiting_workflow: waiting_workflow(work_item, stage),
        gate: %{
          kind: get_in(stage, ["gate", "kind"]) || "person",
          approvers: approvers(stage),
          approvable?: state == :at_gate and may_approve?(scope, stage),
          approvals: approvals(work_item, stage, artifacts)
        }
      }
    else
      _other -> nil
    end
  end

  # The round limit of the loop the work item is in, else of the last loop it left.
  defp shown_rounds(stage, entry) do
    last = Runner.last_loop(stage)

    cond do
      rounds = Runner.rounds(stage, entry) -> rounds
      is_integer(last) and is_integer(entry) and entry > last -> Runner.rounds(stage, last)
      true -> nil
    end
  end

  # inputs/1 is, for each input of the work item's stage, the version it reads: a
  # person's version added on the work item in this stage, else the version the gate of
  # the stage that made it approved; nil for none.
  @doc false
  @spec inputs(WorkItem.t()) :: [map]
  def inputs(%WorkItem{} = work_item) do
    work_item = Repo.get!(WorkItem, work_item.id)

    case placed(work_item) do
      {:ok, version, stage} -> inputs(work_item, version, stage, Artifacts.list(work_item))
      _other -> []
    end
  end

  # artifact_index/1 is every artifact of the work item with its versions, their writers
  # and approvals: for each artifact, the newest version an approval covers, the newest
  # version, and whether a version newer than the approved one exists ("approved vN; vM
  # is newer"); "changed after approval" for an artifact of an earlier stage.
  @doc false
  @spec artifact_index(WorkItem.t()) :: [map]
  def artifact_index(%WorkItem{} = work_item) do
    work_item = Repo.get!(WorkItem, work_item.id)
    approved = approved_ids(work_item)

    for artifact <- Artifacts.list(work_item) do
      versions =
        for version <- artifact.versions do
          %{
            id: version.public_id,
            number: version.number,
            writer: version.writer,
            run_id: version.run_id,
            user_id: version.user_id,
            stage_id: version.stage_id,
            inserted_at: version.inserted_at,
            approved?: MapSet.member?(approved, version.public_id)
          }
        end

      newest = List.first(versions)
      approved_version = Enum.find(versions, & &1.approved?)
      newer? = approved_version != nil and newest.number > approved_version.number

      %{
        type: artifact.type,
        name: artifact.name,
        stage_id: newest && newest.stage_id,
        versions: versions,
        newest: newest && newest.number,
        approved: approved_version && approved_version.number,
        newer_than_approved?: newer?,
        changed_after_approval?: newer? and newest.stage_id != work_item.stage_id
      }
    end
  end

  ## Applying the runner's rules

  defp enter_locked(work_item, version, stage), do: apply_event(work_item, version, stage, :enter)

  defp apply_event(work_item, version, stage, event, run_id \\ nil) do
    facts = facts(work_item, version, stage)
    outcome = Runner.step(stage, position(work_item), event, facts)
    apply_outcome(work_item, version, stage, outcome, run_id)
  end

  defp apply_outcome(work_item, version, stage, outcome, run_id) do
    %{state: state, position: position, actions: actions} = outcome
    work_item = place!(work_item, version, stage["id"], state, position)

    Enum.reduce(actions, {work_item, nil}, fn
      {:queue, spec}, {work_item, _run} ->
        {:ok, run} = queue!(work_item, version, stage, spec)
        {work_item, run}

      {:escalate, cause, gaps}, {work_item, run} ->
        :ok = escalate!(work_item, version, stage, position, cause, gaps, run_id)
        {work_item, run}

      :advance, {work_item, _run} ->
        advance(work_item, version, stage)
    end)
  end

  # The next stage of the version after `stage`, entered; after the last, the stage is
  # done.
  defp advance(work_item, version, stage) do
    stages = version.document["stages"]
    index = Enum.find_index(stages, &(&1["id"] == stage["id"]))

    case Enum.at(stages, index + 1) do
      nil -> {place!(work_item, version, stage["id"], :done, position(work_item)), nil}
      next -> enter_locked(work_item, version, next)
    end
  end

  defp facts(work_item, version, stage) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}
    artifacts = Artifacts.list(work_item)

    declarations =
      Map.new(Runner.workflows(stage), &{&1, Processes.workflow_declaration(workspace, &1)})

    %{
      missing_inputs:
        for(
          %{required: true, version: nil, type: type} <-
            inputs(work_item, version, stage, artifacts),
          do: type
        ),
      undeclared: for({name, nil} <- declarations, do: name),
      declarations: declarations,
      failed_checks:
        for(
          %{required: true, check: :missing, type: type} <- outputs(work_item, stage, artifacts),
          do: type
        ),
      machine: version.document["machine"]
    }
  end

  defp position(%WorkItem{stage_entry: entry, loop_entry: loop_entry, stage_round: round})
       when is_integer(entry),
       do: %{entry: entry, loop_entry: loop_entry, round: max(round || 1, 1)}

  defp position(%WorkItem{}), do: nil

  defp place!(work_item, version, stage_id, state, position) do
    fields = [
      process_version_id: version.id,
      stage_id: stage_id,
      stage_state: state,
      stage_round: position.round,
      stage_entry: position.entry,
      loop_entry: position.loop_entry
    ]

    {1, _rows} = Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: fields)
    struct!(work_item, fields)
  end

  defp queue!(work_item, version, stage, spec) do
    rounds_left =
      case Runner.rounds(stage, spec.entry) do
        nil -> 0
        rounds -> rounds - spec.round
      end

    Dispatches.queue_stage(work_item.id, work_item.take_in, %{
      rounds_left: rounds_left,
      stage: %{
        process_version_id: version.id,
        stage_id: stage["id"],
        round: spec.round,
        stage_entry: spec.entry,
        loop_entry: spec.loop_entry,
        workflow: spec.workflow,
        machine_type: spec.machine_type
      }
    })
  end

  defp escalate!(work_item, version, stage, position, cause, gaps, run_id) do
    :ok = close_open(work_item, :close, nil, nil)

    %Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      round: position.round,
      cause: cause,
      gaps: gaps,
      run_id: run_id,
      inserted_at: DateTime.utc_now()
    }
    |> Repo.insert!()

    :ok
  end

  ## A run's end

  # The run is the newest of the work item's take in, of its stage, while that stage runs.
  # A run with no stage is one queued before the work item was placed (the migration that
  # placed the open work items): it counts for the stage the work item is in.
  defp current_run?(work_item, run) do
    newest =
      Repo.one(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id and r.take_in == ^run.take_in,
          select: max(r.attempt)
      )

    work_item.state == :exploring and work_item.stage_state == :running and
      run.stage_id in [nil, work_item.stage_id] and work_item.take_in == run.take_in and
      newest == run.attempt
  end

  # What the run gave, as the runner reads it; `:unsettled` while a run ended by its exit
  # has nothing stored yet.
  defp run_result(_work_item, %DispatchRun{end_cause: :run_ended, result_outcome: nil}),
    do: :unsettled

  defp run_result(_work_item, %DispatchRun{end_cause: cause})
       when cause in [:closed, :undone, :released, :superseded],
       do: :ignored

  defp run_result(work_item, %DispatchRun{workflow: workflow, step: "explore"} = run)
       when workflow in [nil, @explore_workflow],
       do: {:ok, explore_result(work_item, run)}

  defp run_result(work_item, %DispatchRun{end_cause: :run_ended} = run),
    do: {:ok, reported_result(work_item, run)}

  defp run_result(_work_item, run), do: {:ok, {:stopped, stop_cause(run)}}

  # D1: today's explore v1 result as artifacts.
  defp explore_result(
         work_item,
         %DispatchRun{end_cause: :run_ended, result_outcome: :proposal} = run
       )
       when is_map(run.result) do
    with {:ok, _proposal} <-
           Artifacts.push_json({:run, run}, work_item, "proposal", proposal_document(run.result),
             stage_id: work_item.stage_id
           ),
         {:ok, _verdict} <-
           Artifacts.push_json({:run, run}, work_item, "verdict", %{"verdict" => "passed"},
             stage_id: work_item.stage_id
           ) do
      {:verdict, :passed, nil}
    else
      {:error, _reason} -> {:stopped, "The run's proposal could not be stored."}
    end
  end

  defp explore_result(
         work_item,
         %DispatchRun{end_cause: :run_ended, result_outcome: :questions} = run
       )
       when is_map(run.result) do
    document = Map.take(run.result, ["questions", "understanding", "knowledge"])

    case Artifacts.push_json({:run, run}, work_item, "questions", document,
           stage_id: work_item.stage_id
         ) do
      {:ok, _questions} -> {:questions, Enum.join(Map.get(run.result, "questions", []), "\n")}
      {:error, _reason} -> {:stopped, "The run's questions could not be stored."}
    end
  end

  defp explore_result(_work_item, run), do: {:stopped, stop_cause(run)}

  # A workflow that reports with artifacts: its questions, else its newest verdict; a run
  # whose registered run failed or was lost stopped.
  defp reported_result(work_item, run) do
    mine =
      for artifact <- Artifacts.list(work_item),
          artifact.type in ["questions", "verdict"],
          version <- artifact.versions,
          version.run_id == run.id,
          do: {artifact.type, version}

    questions = Enum.find(mine, &(elem(&1, 0) == "questions"))
    verdict = Enum.find(mine, &(elem(&1, 0) == "verdict"))
    registered = Repo.one(from r in Run, where: r.dispatch_run_id == ^run.id)

    cond do
      questions ->
        document = Artifacts.read_json(elem(questions, 1)) || %{}
        {:questions, Enum.join(List.wrap(document["questions"]), "\n")}

      verdict ->
        document = Artifacts.read_json(elem(verdict, 1)) || %{}
        {:verdict, verdict(document["verdict"]), document["gaps"]}

      match?(%Run{exit_state: state} when state in ["failed", "lost", "cancelled"], registered) ->
        {:stopped, stop_cause(run)}

      true ->
        {:verdict, nil, nil}
    end
  end

  defp verdict("passed"), do: :passed
  defp verdict("changes-requested"), do: :changes_requested
  defp verdict("escalate"), do: :escalate
  defp verdict(_none), do: nil

  # stop_cause/1 is the cause shown for a run that stopped.
  @doc false
  @spec stop_cause(DispatchRun.t()) :: String.t()
  def stop_cause(%DispatchRun{end_cause: :run_ended, result_outcome: :refused}),
    do: "The run's result does not match the explore result schema."

  def stop_cause(%DispatchRun{end_cause: :run_ended, result_outcome: :error}),
    do: "The run ended with an error."

  def stop_cause(%DispatchRun{end_cause: :run_ended}), do: "The run ended without a result."

  def stop_cause(%DispatchRun{end_cause: :lost}),
    do: "The run stopped reporting and was marked lost."

  def stop_cause(%DispatchRun{end_cause: :run_refused}), do: "The gateway did not start the run."

  def stop_cause(%DispatchRun{end_cause: :build_failed}),
    do: "The build of the environment for the work item's target failed."

  def stop_cause(%DispatchRun{end_cause: cause}),
    do: "The run ended before it started (#{cause})."

  # proposal_document/1 is the `proposal` artifact of an explore v1 result.
  @doc false
  @spec proposal_document(map) :: map
  def proposal_document(result),
    do: Map.take(result, ["complexity", "understanding", "scope", "approach", "knowledge"])

  # The proposal with a confirmation's changes (`Apiary.WorkItems.Proposal`).
  defp with_changes(document, changes) do
    Enum.reduce(Proposal.encode(Proposal.decode(changes)), document, fn
      {"complexity", complexity}, acc -> Map.put(acc, "complexity", complexity)
      {"understanding", text}, acc -> Map.put(acc, "understanding", text)
      {"scope_in", entries}, acc -> put_into(acc, "scope", "in", entries)
      {"scope_out", entries}, acc -> put_into(acc, "scope", "out", entries)
      {"approach", text}, acc -> put_into(acc, "approach", "summary", text)
    end)
  end

  defp put_into(document, key, field, value) do
    Map.update(document, key, %{field => value}, &Map.put(&1, field, value))
  end

  ## Gates

  # The work item in the scope's workspace, locked, with its version and stage, once the
  # scope may take `gate.approve` on it and is a listed approver of its stage.
  defp hold(scope, %WorkItem{id: id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id),
         :ok <- Access.authorize(scope, @action, found),
         work_item = lock!(found.id),
         :ok <- if(work_item.state == :exploring, do: :ok, else: {:error, :not_live}),
         {:ok, version, stage} <- placed(work_item),
         :ok <- if(may_approve?(scope, stage), do: :ok, else: {:error, :not_approver}) do
      {:ok, work_item, version, stage}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      :not_placed -> {:error, :not_placed}
      {:error, _reason} = refused -> refused
    end
  end

  defp workspace(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{organisation_id: organisation_id} = workspace,
         user: %{id: user_id}
       })
       when is_binary(user_id),
       do: {:ok, workspace}

  defp workspace(%Scope{}), do: {:error, :not_found}

  defp in_workspace(%Workspace{id: workspace_id, organisation_id: organisation_id}, id) do
    Repo.one(
      from w in WorkItem,
        where:
          w.id == ^id and w.organisation_id == ^organisation_id and
            w.workspace_id == ^workspace_id
    )
  end

  defp approvers(stage) do
    case get_in(stage, ["gate", "approvers"]) do
      %{"members" => members} when is_list(members) -> members
      _members -> :members
    end
  end

  defp may_approve?(nil, _stage), do: true

  defp may_approve?(%Scope{user: user}, stage) do
    case approvers(stage) do
      :members -> true
      members -> match?(%{id: id} when is_binary(id), user) and user.id in members
    end
  end

  defp at_gate(work_item, stage) do
    if shown_state(work_item, stage, Artifacts.list(work_item)) == :at_gate,
      do: :ok,
      else: {:error, :not_at_gate}
  end

  # The state as a person sees it: a stage done whose output has a version newer than its
  # last approval is at its gate again.
  defp shown_state(%WorkItem{stage_state: :done} = work_item, stage, artifacts) do
    if reopened?(work_item, stage, artifacts), do: :at_gate, else: :done
  end

  defp shown_state(%WorkItem{stage_state: state}, _stage, _artifacts), do: state

  defp reopened?(work_item, stage, artifacts) do
    case last_approval(work_item, stage["id"]) do
      %GateDecision{versions: covered} ->
        newest = Enum.map(newest_outputs(work_item, stage, artifacts), & &1.public_id)
        newest -- covered != []

      nil ->
        false
    end
  end

  defp last_approval(work_item, stage_id) do
    Repo.one(
      from d in GateDecision,
        where: d.work_item_id == ^work_item.id and d.stage_id == ^stage_id and d.kind == :approve,
        order_by: [desc: d.inserted_at],
        limit: 1
    )
  end

  defp decide(scope, work_item, version, stage, kind, covered, artifact_version_id, note) do
    %GateDecision{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      user_id: scope.user.id,
      kind: kind,
      versions: covered,
      artifact_version_id: artifact_version_id,
      note: note,
      inserted_at: DateTime.utc_now()
    }
    |> Repo.insert()
  end

  defp version_of(_work_item, nil), do: :ok

  defp version_of(work_item, id) when is_binary(id) do
    known? =
      work_item
      |> Artifacts.list()
      |> Enum.any?(fn artifact -> Enum.any?(artifact.versions, &(&1.public_id == id)) end)

    if known?, do: :ok, else: {:error, :not_found}
  end

  defp version_of(_work_item, _id), do: {:error, :not_found}

  defp earlier(version, stage, stage_id) do
    ids = Enum.map(version.document["stages"], & &1["id"])
    here = Enum.find_index(ids, &(&1 == stage["id"]))
    there = Enum.find_index(ids, &(&1 == stage_id))

    if is_integer(there) and there < here,
      do: {:ok, Processes.stage(version, stage_id)},
      else: {:error, :not_earlier}
  end

  ## Escalations

  defp open_escalation(work_item) do
    Repo.one(
      from e in Escalation, where: e.work_item_id == ^work_item.id and is_nil(e.resolved_at)
    )
  end

  # The open escalation of the work item, stored now for a work item that the migration
  # placing open work items placed as escalated without one; else `{:error, :not_escalated}`.
  defp escalation!(work_item, version, stage) do
    cond do
      escalation = open_escalation(work_item) ->
        escalation

      escalation = placed_escalation(work_item, version, stage) ->
        Repo.insert!(escalation)

      true ->
        {:error, :not_escalated}
    end
  end

  # An escalated work item with no open escalation: its run stopped before the stage runner
  # placed it. The escalation that stands for it, not stored.
  defp placed_escalation(%WorkItem{stage_state: :escalated} = work_item, version, stage) do
    run =
      Repo.one(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id and r.take_in == ^work_item.take_in,
          order_by: [desc: r.attempt],
          limit: 1
      )

    %Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      round: work_item.stage_round || 0,
      cause: :run_stopped,
      run_id: run && run.id,
      inserted_at: DateTime.utc_now()
    }
  end

  defp placed_escalation(_work_item, _version, _stage), do: nil

  # Resolves an open escalation of the work item, if one is open, with `resolution`.
  defp close_open(work_item, resolution, scope, note) do
    case open_escalation(work_item) do
      nil -> :ok
      escalation -> resolve!(escalation, resolution, scope, note)
    end
  end

  defp resolve!(escalation, resolution, scope, note) do
    {1, _rows} =
      Repo.update_all(from(e in Escalation, where: e.id == ^escalation.id),
        set: [
          resolution: resolution,
          resolved_by_id: scope && scope.user && scope.user.id,
          resolved_at: DateTime.utc_now(),
          note: note
        ]
      )

    :ok
  end

  defp escalation_map(nil), do: nil

  defp escalation_map(%Escalation{} = escalation) do
    run = escalation.run_id && Repo.get(DispatchRun, escalation.run_id)

    %{
      cause: escalation.cause,
      gaps: escalation.gaps,
      round: escalation.round,
      run: run && %{id: run.id, attempt: run.attempt, workflow: run.workflow},
      inserted_at: escalation.inserted_at
    }
  end

  ## Outputs, inputs and approvals

  # The newest version of each output type made in the stage, by type.
  defp newest_outputs(work_item, stage, artifacts \\ nil) do
    artifacts = artifacts || Artifacts.list(work_item)

    for output <- Map.get(stage, "outputs", []),
        version = newest_made_in(artifacts, output["type"], stage["id"]),
        version != nil,
        do: version
  end

  defp newest_made_in(artifacts, type, stage_id) do
    artifacts
    |> Enum.filter(&(&1.type == type))
    |> Enum.flat_map(& &1.versions)
    |> Enum.filter(&(&1.stage_id == stage_id))
    |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.number}, fn -> nil end)
  end

  defp outputs(work_item, stage, artifacts) do
    for output <- Map.get(stage, "outputs", []) do
      type = output["type"]
      version = newest_made_in(artifacts, type, stage["id"])

      check =
        cond do
          reported?(output) -> :not_checked
          Artifacts.exists?(work_item, stage["id"], type) -> :passed
          true -> :missing
        end

      %{
        type: type,
        required: output["required"] == true,
        version: version && %{id: version.public_id, number: version.number},
        check: check
      }
    end
  end

  # D6: a `reported` check is stored and not checked in this version.
  defp reported?(%{"check" => %{"reported" => _outcome}}), do: true
  defp reported?(_output), do: false

  defp inputs(work_item, version, stage, artifacts) do
    by_id = for a <- artifacts, v <- a.versions, into: %{}, do: {v.public_id, {a.type, v}}

    for input <- Map.get(stage, "inputs", []) do
      type = input["type"]

      person =
        artifacts
        |> Enum.filter(&(&1.type == type))
        |> Enum.flat_map(& &1.versions)
        |> Enum.filter(&(&1.writer == :person and &1.stage_id in [nil, stage["id"]]))
        |> Enum.max_by(& &1.number, fn -> nil end)

      gated =
        earlier_stage_ids(version, stage)
        |> Enum.find_value(fn stage_id ->
          case last_approval(work_item, stage_id) do
            %GateDecision{versions: covered} ->
              Enum.find_value(covered, fn id ->
                case by_id[id] do
                  {^type, found} -> found
                  _other -> nil
                end
              end)

            nil ->
              nil
          end
        end)

      chosen = person || gated

      %{
        type: type,
        required: input["required"] == true,
        version: chosen && %{id: chosen.public_id, number: chosen.number},
        source:
          cond do
            person -> :person
            gated -> :approved
            true -> nil
          end
      }
    end
  end

  # The ids of the stages before `stage`, nearest first.
  defp earlier_stage_ids(version, stage) do
    version.document["stages"]
    |> Enum.map(& &1["id"])
    |> Enum.take_while(&(&1 != stage["id"]))
    |> Enum.reverse()
  end

  defp approved_ids(work_item) do
    Repo.all(
      from d in GateDecision,
        where: d.work_item_id == ^work_item.id and d.kind == :approve,
        select: d.versions
    )
    |> List.flatten()
    |> MapSet.new()
  end

  defp approvals(work_item, stage, artifacts) do
    by_id =
      for a <- artifacts,
          v <- a.versions,
          into: %{},
          do:
            {v.public_id,
             %{type: a.type, name: a.name, number: v.number, newest: hd(a.versions).number}}

    Repo.all(
      from d in GateDecision,
        where:
          d.work_item_id == ^work_item.id and d.stage_id == ^stage["id"] and d.kind == :approve,
        order_by: [desc: d.inserted_at]
    )
    |> Enum.map(fn decision ->
      %{
        user_id: decision.user_id,
        note: decision.note,
        inserted_at: decision.inserted_at,
        versions:
          for id <- decision.versions, version = by_id[id], version != nil do
            Map.merge(version, %{id: id, newer?: version.newest > version.number})
          end
      }
    end)
  end

  defp gaps(%Escalation{gaps: gaps}, _work_item, _stage, _artifacts), do: gaps

  defp gaps(nil, _work_item, stage, artifacts) do
    case newest_made_in(artifacts, "verdict", stage["id"]) do
      nil -> nil
      version -> (Artifacts.read_json(version) || %{})["gaps"]
    end
  end

  defp waiting_workflow(%WorkItem{stage_state: :waiting_workflow} = work_item, stage) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}

    Enum.find(Runner.workflows(stage), &is_nil(Processes.workflow_declaration(workspace, &1)))
  end

  defp waiting_workflow(_work_item, _stage), do: nil

  ## Helpers

  # The work item's version and stage, once the runner placed it.
  defp placed(%WorkItem{stage_id: stage_id} = work_item) when is_binary(stage_id) do
    version = Processes.version_for(work_item)

    case Processes.stage(version, stage_id) do
      nil -> :not_placed
      stage -> {:ok, version, stage}
    end
  end

  defp placed(%WorkItem{}), do: :not_placed

  defp lock!(id),
    do: Repo.one!(from w in WorkItem, where: w.id == ^id, lock: "FOR UPDATE")

  defp note(nil), do: {:ok, nil}

  defp note(note) when is_binary(note) do
    case String.trim(note) do
      "" ->
        {:ok, nil}

      trimmed ->
        if String.length(trimmed) <= @max_note,
          do: {:ok, trimmed},
          else: {:error, {:invalid, :note}}
    end
  end

  defp note(_note), do: {:error, {:invalid, :note}}

  defp audit(scope, work_item, change, details) do
    Audit.record(Repo, scope, @action, work_item, %{details: Map.put(details, "change", change)})
  end

  defp told(%WorkItem{workspace_id: workspace_id, public_id: public_id}),
    do: [{:stage_changed, workspace_id, public_id}]

  # A hand-over inside a caller's transaction whose caller tells nothing of the stage.
  defp tell_now(work_item), do: Dispatches.broadcast(told(work_item))

  defp transact(fun) do
    case Repo.transact(fun) do
      {:ok, %WorkItem{} = work_item} = ok ->
        Dispatches.broadcast(told(work_item))
        ok

      other ->
        other
    end
  end

  defp in_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.Stages runs this inside the caller's transaction")
  end
end
