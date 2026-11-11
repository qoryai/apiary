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
  #   * `next_run/2`, from `Apiary.Dispatches.queue_next/3`: answers to a run's questions,
  #     a send of the review comments while those questions wait, Explore again after a
  #     run that stopped, or a send of the review comments at a stage's gate, run the
  #     stage's next round.
  #   * `run_ended/1`, from the end of a run (`Apiary.Dispatches.RunEnd.finish/5`) and from
  #     its settle (`Apiary.Dispatches.Settle.settle/1`), in their transaction: the runner
  #     reads what the run gave and acts. A run ended `run_ended` is read once its outcome
  #     is stored.
  #   * `confirmed/2`, from `Apiary.WorkItems.confirm/3`: a confirmation of Explore's
  #     proposal approves Explore's gate.
  #
  # ## After the last stage
  #
  # A work item closes when its last stage finishes, in the same transaction, as the
  # instance with the reason `last_stage_done`: `closed_by_id` stays empty and
  # `stage_state` stays `:done` (`Apiary.WorkItems.Finished`).
  #
  # ## Explore
  #
  # A run of explore-a-ticket pushes its `proposal` and its `questions` during the run
  # through the run API, and Core pushes nothing for it. At the end of every run of
  # Explore, and of a run of any other workflow that ended by its exit, the newest
  # questions of the work item with a question of the run's take in that waits for an
  # answer make the stage wait for answers, whatever else the run did
  # (`Apiary.Explore.Questions.open_in_take_in/2`; one left open in an earlier take in
  # does not count). A run that also pushed the verdict `escalate` keeps its escalation,
  # with the verdict's points, open while the stage waits for answers; the answers resolve
  # it as another round (`next_run/2`). Otherwise a run of Explore that ended by its exit
  # and whose newest verdict named `main` is `escalate` escalates, `escalate`, with the
  # verdict's points, as a run of any other workflow does (`reported_verdict/1`). Explore reads only
  # `escalate`: any other verdict counts as none. Otherwise a run of Explore that stopped
  # escalates, `run_stopped`, with the cause, and any other counts as a run with no
  # verdict, which goes on where the run's take in has a proposal or the run left open
  # questions (`Apiary.Explore.Outcome`), or where the run pushed `passed` or
  # `changes-requested`, to the stage's checks; it escalates, `run_stopped`, otherwise
  # (`Apiary.Stages.Runner`). Newest questions whose file cannot be read raise
  # `Apiary.Stages.QuestionsUnreadable` at those ends. At the end of a run of any
  # workflow, a verdict whose file the store cannot read raises
  # `Apiary.Stages.VerdictUnreadable`. A refusal or a lost run
  # (`Apiary.Dispatches.RunEnd`) rolls back and stores nothing, as the run of the queue is
  # still handed over: the lost-run check ends it again at a later tick
  # (`Apiary.Dispatches.RunEnd.lose/3`). An exit is stored with no outcome
  # (`Apiary.Dispatches.Settle`); the settle sweep settles it later, and then the stage
  # acts, unless the file becomes unreadable after Settle read it; then the exit rolls
  # back and the lost-run check ends it again. A settle that raises rolls back, and
  # the settle sweep settles the run again. A claim, a failed harness walk and a held run
  # whose build failed store the end and leave the stage as it is
  # (`run_ended_or_later/2`), and the stage sweep acts on the end later (`sweep/3`). Any
  # other workflow reports with artifacts: the open questions of the run's take in, else
  # the newest `verdict` the run pushed, else stopped when its registered run failed, was
  # lost or was cancelled (`reported_result/2`).
  #
  # ## What a person does
  #
  # `resolve_escalation/4` acts only on a stage that is `:escalated`: while an
  # escalation's stage waits for answers, it is `{:error, :not_escalated}`.
  #
  # `approve/3`, `request_changes/4`, `resolve_escalation/4` and `move/4` ask
  # `gate.approve` (`Apiary.Access`) of the work item, before its lock and again of the
  # locked row, which allows only the
  # stage's listed approvers where the stage lists them (by their account's id,
  # `Apiary.Stages.Approvers`), else `:not_approver`. Each writes one
  # entry in the audit trail, `gate.approve`, with `details.change` `approve`,
  # `request_changes`, `escalation_<resolution>` or `move`.
  #
  # A member's move that runs the stage's next round (`member_round/3`: an answer, a send
  # of the review comments, Run another round and Explore again) asks the same of the work item where the round resolves an open
  # escalation of the stage, while the stage is escalated or waits for answers beside it,
  # and where it runs a stage after Explore's again from its gate. The escalation then has
  # the person as `resolved_by`, and the trail the entry `escalation_another_round`; a run
  # again from the gate, the entry `another_round`.
  #
  # `add_version/5` stores a version a person adds on the work item, made in its current
  # stage, then acts on that stage (`version_added/1`): a stage that waits for inputs
  # starts once its last required input exists, and the Exists checks run again. A stage with
  # no workflow waits at its gate while a required output is missing
  # (`missing_outputs/1`); `approve/4` refuses it, `{:error, {:outputs_missing, types}}`,
  # and a gate `none` passes on once every required output exists.
  #
  # ## What is told
  #
  # `{:stage_changed, public_id}` on the work item's topic (`topic/1`), once the change
  # commits; on a hand-over inside another
  # module's transaction, through what that module tells (`Apiary.Dispatches.broadcast/1`),
  # or, for a take in and an answer, at once.
  @moduledoc false

  import Ecto.Query, warn: false

  require Logger

  # The ends of a run the stage runner ignores (`run_result/3`).
  @ignored_ends [:closed, :undone, :released, :superseded]
  # The ends one stage sweep reads at most (`sweep/3`).
  @stage_batch 100

  alias Apiary.{Access, Audit, Dispatches, Features, MachineTypes, Processes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.Qory
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run
  alias Apiary.Stacks.Sources
  alias Apiary.Stages.{Approvers, Artifacts, Check, Escalation, GateDecision, Points, Runner}
  alias Apiary.Stages.StopCause
  alias Apiary.WorkItems
  alias Apiary.WorkItems.{Explore, Moves, WorkItem}

  # The runs a workflow outside a loop may have in one round of its entry: its first,
  # and one after each set of answers, as today's Explore has in one take in.
  @question_runs 3
  @action :"gate.approve"
  @max_note 4000

  @typedoc "A resolution of an escalation."
  @type resolution :: :accept | :another_round | {:move_back, String.t()} | :close

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
          | :stage_changed
          | {:outputs_missing, [String.t()]}
          | {:invalid, :note}
          | term

  @typedoc """
  The stage the person acted on, as their page showed it: `expect_stage: stage_id`,
  required. An action on a work item that is no longer in that stage, or that names
  none, changes nothing and returns `{:error, :stage_changed}`.
  """
  @type expect :: [expect_stage: String.t()]

  # on?/0 is whether the workflow model is on for the instance.
  @doc false
  @spec on?() :: boolean
  def on?, do: Features.on?(:workflow_model)

  # topic/1 is the PubSub topic of one work item's stage, by the work item or its public
  # id: `{:stage_changed, public_id}` arrives there, and nothing else.
  @doc false
  @spec topic(WorkItem.t() | String.t()) :: String.t()
  def topic(%WorkItem{public_id: public_id}), do: topic(public_id)
  def topic(public_id) when is_binary(public_id), do: "stages:work_item:" <> public_id

  # subscribe/1 subscribes the caller to the work item's stage (`topic/1`).
  @doc false
  @spec subscribe(WorkItem.t() | String.t()) :: :ok | {:error, term}
  def subscribe(work_item), do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(work_item))

  ## Hand-over points

  # take_in/2 places the work item `id`, locked by the caller's transaction, at take in
  # `take_in` in the first stage of its workspace's current version, and starts it:
  # `{:ok, run}`, nil when the stage waits. The caller holds the table of machine types
  # from before it locks the work item (`Apiary.MachineTypes.hold/0`), so no key change
  # commits between the read of the current version and the commit.
  @doc false
  @spec take_in(Ecto.UUID.t(), pos_integer) :: {:ok, DispatchRun.t() | nil}
  def take_in(id, take_in) when is_binary(id) and is_integer(take_in) do
    in_transaction!()
    work_item = %{lock!(id) | take_in: take_in}
    version = Processes.current(Repo.get!(Workspace, work_item.workspace_id))
    [first | _rest] = version.document["stages"]
    :ok = close_open(work_item, :close, nil, nil)
    {work_item, run} = enter_locked(%{work_item | process_version_id: version.id}, version, first)
    tell_now(work_item)
    {:ok, run}
  end

  # next_run/2 runs the next round of the stage of the work item `id`, locked by the
  # caller's transaction: after answers, or a send of the review comments while the
  # questions wait, the same workflow; after an escalation or a run that stopped, another
  # round; at the gate, after a send of the review comments on the stage's outputs, another
  # round from where the stage's sequence runs again (`Apiary.Stages.Runner.step/4`).
  # `{:ok, run}`; `{:error, :not_waiting}` when the stage
  # waits for a workflow; `:not_placed` for a work item the runner did not place.
  @doc false
  @spec next_run(Ecto.UUID.t(), pos_integer) ::
          {:ok, DispatchRun.t()} | {:error, :not_waiting} | :not_placed
  def next_run(id, take_in) when is_binary(id) and is_integer(take_in) do
    in_transaction!()
    work_item = %{lock!(id) | take_in: take_in}

    with {:ok, version, stage} <- placed(work_item) do
      {event, escalation} = next_event(work_item)
      if escalation, do: :ok = resolve!(escalation, :another_round, nil, nil)
      {work_item, run} = apply_event(work_item, version, stage, event)
      tell_now(work_item)
      if run, do: {:ok, run}, else: {:error, :not_waiting}
    else
      _not_placed -> :not_placed
    end
  end

  # The event of the next round `next_run/2` runs, with the open escalation it resolves as
  # another round, or nil for none.
  defp next_event(%WorkItem{stage_state: :waiting_answers} = work_item),
    do: {:answered, open_escalation(work_item)}

  defp next_event(%WorkItem{stage_state: :escalated} = work_item) do
    case open_escalation(work_item) do
      %Escalation{cause: cause} = escalation -> {{:another_round, cause}, escalation}
      nil -> {{:another_round, :run_stopped}, nil}
    end
  end

  # A send of the review comments at the gate: at the end of the sequence, another round
  # runs it again, its last loop for a stage with one, else from its start. A run that stopped
  # runs another round too.
  defp next_event(%WorkItem{}), do: {{:another_round, :run_stopped}, nil}

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

  # run_ended/2 acts on the end of the run of the queue `run`, or its id, inside the
  # caller's transaction, which locked its work item `FOR UPDATE` before the run of the
  # queue (`hold_work_item/1`, or `Apiary.Dispatches.RunEnd.hold/1`, or
  # `Apiary.Environments.hold_build/2` for the runs a build held), with `context` what a
  # claim knew (`StopCause.context/0`): when the run is the newest of its work
  # item's stage, the stage is running, and what the run gave is known. The work items to
  # tell once the transaction commits (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec run_ended(DispatchRun.t() | Ecto.UUID.t(), StopCause.context()) ::
          [Apiary.Dispatches.Settle.told()]
  def run_ended(run, context \\ %{})
  def run_ended(%DispatchRun{id: id}, context), do: run_ended(id, context)

  def run_ended(id, context) when is_binary(id) do
    in_transaction!()

    with %DispatchRun{state: :ended, step: "explore", work_item_id: work_item_id} = run
         when is_binary(work_item_id) <- Repo.get(DispatchRun, id),
         %WorkItem{} = work_item <- lock!(work_item_id),
         true <- current_run?(work_item, run),
         {:ok, version, stage} <- placed(work_item),
         {:ok, result, run_facts} <- run_result(work_item, run, context) do
      event = {:run, result}
      {work_item, _run} = apply_event(work_item, version, stage, event, run.id, run_facts)
      told(work_item)
    else
      _other -> []
    end
  end

  # run_ended_or_later/2 is `run_ended/2` for an end that is stored whatever the stage
  # does: a claim's, a harness walk's that failed, and a held run's whose build failed.
  # Where the newest questions of the run's work item cannot be read, it writes nothing,
  # logs one warning with the run's id and gives none: the stage sweep acts on the end
  # later (`sweep/3`). Nothing is written before that read, so the caller's transaction
  # goes on.
  @doc false
  @spec run_ended_or_later(Ecto.UUID.t(), StopCause.context()) ::
          [Apiary.Dispatches.Settle.told()]
  def run_ended_or_later(id, context \\ %{}) when is_binary(id) do
    run_ended(id, context)
  rescue
    Apiary.Stages.QuestionsUnreadable ->
      Logger.warning("stage end left for later, newest questions unreadable dispatch_run=#{id}")
      []
  end

  # sweep/3 acts on the ends the stage runner has not read: each run of Explore that is
  # the newest of its work item's take in, ended, with its work item exploring and the
  # stage running, but a run ended `run_ended` with no outcome stored, which Settle stores
  # first (`Apiary.Dispatches.Settle`), and a run whose end the runner ignores. Such an
  # end is one that `run_ended_or_later/2` left, or whose act failed after the end was
  # stored. Every act of the runner on a run's end moves the stage or queues a newer run,
  # so an end acted on is not read again. At most `limit`, `@stage_batch` by default, by
  # id after `after_id`, or from the first for nil, each in a transaction that locks the
  # work item, then reads the run with no lock, with the context a claim gives
  # (`claim_context/1`); one that raises is logged in one line by its id and the
  # exception's module. `{told, next}`: the work items to tell, and the `after_id` of the
  # next sweep, the last id read when it read `limit`, nil when it read fewer. With the
  # workflow model off, none.
  @doc false
  @spec sweep(DateTime.t(), Ecto.UUID.t() | nil, pos_integer) ::
          {[Apiary.Dispatches.Settle.told()], Ecto.UUID.t() | nil}
  def sweep(%DateTime{} = _now, after_id, limit \\ @stage_batch) do
    if on?() do
      newest =
        from r in DispatchRun,
          where:
            r.work_item_id == parent_as(:run).work_item_id and
              r.take_in == parent_as(:run).take_in,
          select: max(r.attempt)

      ids =
        from(r in DispatchRun,
          as: :run,
          join: w in WorkItem,
          on: w.id == r.work_item_id,
          where: r.state == :ended and r.step == "explore",
          where: r.end_cause not in ^@ignored_ends,
          where: not (r.end_cause == :run_ended and is_nil(r.result_outcome)),
          # Read through the partial index `work_items_exploring_running_index`.
          where: w.state == :exploring and w.stage_state == :running,
          where: w.take_in == r.take_in and (is_nil(r.stage_id) or r.stage_id == w.stage_id),
          where: r.attempt == subquery(newest),
          order_by: r.id,
          limit: ^limit,
          select: r.id
        )
        |> stage_after(after_id)
        |> Repo.all()

      next = if length(ids) == limit, do: List.last(ids)
      {Enum.flat_map(ids, &sweep_one/1), next}
    else
      {[], nil}
    end
  end

  defp stage_after(query, nil), do: query
  defp stage_after(query, id), do: from(r in query, where: r.id > ^id)

  defp sweep_one(id) do
    {:ok, told} =
      Repo.transact(fn ->
        :ok = hold_work_item(id)
        {:ok, run_ended(id, claim_context(id))}
      end)

    Apiary.Runs.StuckLog.clear({:stage, id})
    told
  rescue
    exception ->
      module = exception.__struct__

      Apiary.Runs.StuckLog.log(:error, {:stage, id}, module, fn ->
        "stage end failed dispatch_run=#{id} error=#{inspect(module)}"
      end)

      []
  end

  # The context a claim gives its ends (`claim_ended/2`), made again for the run of the
  # queue `id`: the gateway and the keys of the pool of the run's newest dispatch, as
  # `Apiary.Dispatches.Handover.gateway/1` reads them now, in the shape the claim passes.
  # A run with no dispatch, or whose pool no longer resolves to a gateway, has none.
  @doc false
  @spec claim_context(Ecto.UUID.t()) :: StopCause.context()
  def claim_context(id) when is_binary(id) do
    pool =
      Repo.one(
        from d in Dispatches.Dispatch,
          join: n in Apiary.Nodes.Node,
          on: n.id == d.pool_id,
          where: d.dispatch_run_id == ^id,
          order_by: [desc: d.claimed_at],
          limit: 1,
          select: n
      )

    with %Apiary.Nodes.Node{} <- pool,
         {:ok, gateway, keys} <- Dispatches.Handover.gateway(pool) do
      %{gateway: gateway, keys: keys}
    else
      _none -> %{}
    end
  end

  # claim_ended/1 acts on the end of each run of the queue in `dispatch_run_ids`, which a
  # claim ended before they started, once the claim committed: each in a transaction that
  # locks its work item, then reads the run with no lock (`run_ended_or_later/2`). A
  # failure is logged, and the run's work item stays as it was until the stage sweep acts
  # on the run's end (`sweep/3`). The work items to tell (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec claim_ended([Ecto.UUID.t()], StopCause.context()) :: [Apiary.Dispatches.Settle.told()]
  def claim_ended(dispatch_run_ids, context \\ %{}) when is_list(dispatch_run_ids),
    do: Enum.flat_map(dispatch_run_ids, &claim_ended_one(&1, context))

  defp claim_ended_one(id, context) do
    {:ok, told} =
      Repo.transact(fn ->
        :ok = hold_work_item(id)
        {:ok, run_ended_or_later(id, context)}
      end)

    told
  rescue
    exception ->
      Logger.error(
        "a stage could not act on a run's end dispatch_run=#{id} error=#{inspect(exception.__struct__)}"
      )

      []
  end

  # limits/1 is the lowered time limit, in seconds, and access level of the run of the
  # queue `run` (`Apiary.Stages.Runner.limits/4`), read at its claim without a lock, with
  # the harness's declaration of its workflow as the claim reads it; nil for a run the
  # stage runner did not queue, or with the workflow model off. A stage its version does
  # not have counts as a stage with no entry.
  @doc false
  @spec limits(DispatchRun.t()) ::
          %{time_limit: pos_integer | nil, access: :read | :write | nil} | nil
  def limits(%DispatchRun{stage_id: stage_id, process_version_id: version_id} = run)
      when is_binary(stage_id) and is_binary(version_id) do
    with true <- on?(),
         %Processes.Version{} = version <- Repo.get(Processes.Version, version_id) do
      stage = Processes.stage(version, stage_id) || %{}
      workspace = Repo.get!(Workspace, run.workspace_id)
      declaration = run.workflow && Processes.workflow_declaration(workspace, run.workflow)
      position = %{entry: run.stage_entry, loop_entry: run.loop_entry, round: run.round}
      Runner.limits(stage, position, declaration, run_workflow(run))
    else
      _none -> nil
    end
  end

  def limits(%DispatchRun{}), do: nil

  # run_workflow/1 is the workflow a run of a stage starts, its `workflow`, with the
  # workflow model on: the name its harness walk, its documents, its time limits and its
  # model choice are read by. nil for a run the stage runner did not queue, or with the
  # workflow model off, which keep the workflow the Harness page saved
  # (`Apiary.Stacks.workflow/2`).
  @doc false
  @spec run_workflow(DispatchRun.t()) :: String.t() | nil
  def run_workflow(%DispatchRun{stage_id: stage_id, workflow: workflow})
      when is_binary(stage_id) and is_binary(workflow),
      do: if(on?(), do: workflow)

  def run_workflow(%DispatchRun{}), do: nil

  # Transition (D1): explore_workflow/1 is the workflow whose runs return today's explore
  # v1 result in `workspace`, a workspace or its id: the first workflow of the process of
  # the Qory harness's template that the template's stack lists, in stage order, at the
  # commit the runs of the workspace's current version compose, else at the commit of the
  # workspace's harness settings, as the stored files have it
  # (`Apiary.Processes.HarnessUpdate.qory_in_use/1`). It reads the database only. Nil for
  # none, and then no stage is Explore.
  # Where that commit's files are not kept, as before the first read of the harness or
  # after the instance's harness address changed, the newest commit kept stands in
  # (`Apiary.Harnesses.Qory.newest/0`).
  @doc false
  @spec explore_workflow(Workspace.t() | Ecto.UUID.t()) :: String.t() | nil
  def explore_workflow(workspace) do
    commit = Processes.HarnessUpdate.qory_in_use(workspace)
    commit = if Processes.template_process(commit), do: commit, else: Qory.newest()
    listed = Processes.qory_workflows(commit)

    case Processes.template_process(commit) do
      %{"stages" => stages} when is_list(stages) ->
        stages |> Enum.flat_map(&Runner.workflows/1) |> Enum.find(&(&1 in listed))

      _none ->
        nil
    end
  end

  # take_in_starts/2 is the run a take in of the ticket `item_id` (`tk_…`) into
  # `workspace` would queue, read before the take in with nothing written but the version
  # `Apiary.Processes.current/1` makes for a workspace with none, as a page shows it
  # (`ApiaryWeb.SpendDialog.take_in_line/3`). It follows the take in's rule
  # (`Apiary.Dispatches.queue/2`). With the workflow model, the take in enters the first
  # stage of the workspace's current version (`take_in/2`): the runner's step on that
  # entry, on the facts of the ticket's work item, which Take in again and Take in here
  # bring back, or of a new one with no artifacts. `{:run, workflow}`, or `:none` where
  # the stage waits, as for a required input with no version. Without it, a run of
  # `explore_workflow/1`.
  @doc false
  @spec take_in_starts(Workspace.t(), String.t()) :: {:run, String.t() | nil} | :none
  def take_in_starts(%Workspace{} = workspace, item_id) when is_binary(item_id) do
    if on?() do
      version = Processes.current(workspace)

      case version.document["stages"] do
        [first | _rest] ->
          entered(%{taken_in(workspace, item_id) | workspace_id: workspace.id}, version, first)

        _none ->
          :none
      end
    else
      {:run, explore_workflow(workspace)}
    end
  end

  # The work item of the ticket `item_id` in the organisation of `workspace`, in any of
  # its workspaces and states; for a ticket with none, a work item whose id no row has, so
  # that every artifact, decision and check the runner reads of it is none.
  defp taken_in(%Workspace{organisation_id: organisation_id}, item_id) do
    Repo.one(
      from i in Apiary.Sources.Item,
        join: w in WorkItem,
        on:
          w.organisation_id == i.organisation_id and w.adapter_id == i.adapter_id and
            w.external_ref == i.external_ref,
        where: i.public_id == ^item_id and i.organisation_id == ^organisation_id,
        limit: 1,
        select: w
    ) || %WorkItem{id: Ecto.UUID.generate(), organisation_id: organisation_id}
  end

  # confirmed/3 approves Explore's gate for the work item whose proposal the scope's
  # person confirmed in this transaction (`Apiary.WorkItems.confirm/3`), which passes
  # the stage of the confirmed run as `expect_stage` (`confirmed_stage_id/2`). At the
  # gate it asks `work_item.confirm` (`Apiary.Access`) of the locked work item again.
  @doc false
  @spec confirmed(Scope.t(), WorkItem.t(), expect) :: {:ok, WorkItem.t()} | {:error, term}
  def confirmed(%Scope{} = scope, %WorkItem{id: id}, opts \\ []) do
    in_transaction!()
    work_item = lock!(id)

    with {:ok, version, stage} <- placed(work_item),
         :ok <- expected(work_item, opts),
         :at_gate <- work_item.stage_state do
      with :ok <- Access.authorize(scope, :"work_item.confirm", work_item),
           {:ok, work_item} <- approve_locked(scope, work_item, version, stage, nil, false) do
        tell_now(work_item)
        {:ok, work_item}
      end
    else
      {:error, :stage_changed} = refused -> refused
      _not_at_gate -> {:ok, work_item}
    end
  end

  # member_round/3 runs `move`, a member's move that queues the next round of the work
  # item's stage (`Apiary.WorkItems.Moves`: an answer, a send of the review comments, Run
  # another round, Explore again), inside one transaction, on the work item of the scope's
  # workspace locked. Where the stage is escalated, or waits for answers with an
  # escalation kept open beside its questions, that round resolves the escalation as
  # another round, the same act as `resolve_escalation/5`; where a stage after Explore's
  # waits at its gate, it runs that stage again. Each asks `gate.approve` and a place
  # among the stage's approvers, else nothing runs (`:not_approver`). The trail then has
  # a `gate.approve` entry, `escalation_another_round` with the escalation's
  # `resolved_by` set to the person, or `another_round` for a run again from the gate.
  # Where a stage after Explore's waits for anything else than answers or a run, such as
  # its inputs, while Explore's proposal still waits at Confirm, no round of that stage
  # starts from Explore's proposal (`:not_waiting`). Elsewhere `move` runs as it is: an
  # answer to the questions a stage waits for, with no escalation open, is every member's.
  @doc false
  @spec member_round(Scope.t(), WorkItem.t(), (-> {:ok, WorkItem.t()} | {:error, term})) ::
          {:ok, WorkItem.t()} | {:error, term}
  def member_round(%Scope{} = scope, %WorkItem{id: id} = work_item, move) do
    transact(fn ->
      case lock_scoped(scope, id) do
        %WorkItem{} = row -> round_locked(scope, work_item, row, move)
        nil -> move.()
      end
    end)
  end

  # The work item `id` of the scope's workspace, locked `FOR UPDATE`; nil for none, whose
  # move then refuses it, holding no row.
  defp lock_scoped(scope, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} <- in_workspace(workspace, uuid) do
      lock!(uuid)
    else
      _none -> nil
    end
  end

  # An escalated stage with no open escalation stored, as the migration placed it, has
  # one stored first (`escalation!/3`), so the round resolves it.
  defp round_locked(scope, work_item, %WorkItem{stage_state: :escalated} = row, move) do
    with {:ok, held, version, stage} <- hold(scope, work_item, expect_stage: row.stage_id),
         %Escalation{} = escalation <- escalation!(held, version, stage),
         do: resolved_by(scope, work_item, escalation, move)
  end

  defp round_locked(scope, work_item, %WorkItem{stage_state: :waiting_answers} = row, move) do
    case open_escalation(row) do
      %Escalation{} = escalation ->
        with {:ok, _work_item, _version, _stage} <-
               hold(scope, work_item, expect_stage: escalation.stage_id),
             do: resolved_by(scope, work_item, escalation, move)

      nil ->
        move.()
    end
  end

  defp round_locked(scope, work_item, %WorkItem{stage_state: state} = row, move) do
    explore = explore_stage_id(row)

    cond do
      is_nil(row.stage_id) or row.stage_id == explore or state == :running ->
        move.()

      state == :at_gate ->
        with {:ok, _work_item, _version, _stage} <-
               hold(scope, work_item, expect_stage: row.stage_id),
             {:ok, work_item} <- move.(),
             {:ok, _entry} <-
               audit(scope, work_item, "another_round", %{"stage_id" => row.stage_id}),
             do: {:ok, work_item}

      is_binary(explore) ->
        {:error, :not_waiting}

      true ->
        move.()
    end
  end

  # Runs `move`, whose next round resolves `escalation` as another round (`next_run/2`),
  # then records the scope's person as the one who resolved it, with the trail's
  # `gate.approve` entry. A move that resolved it otherwise leaves it as it is.
  defp resolved_by(scope, work_item, escalation, move) do
    with {:ok, work_item} <- move.(),
         {1, _rows} <-
           Repo.update_all(
             from(e in Escalation,
               where: e.id == ^escalation.id and e.resolution == :another_round
             ),
             set: [resolved_by_id: scope.user.id]
           ),
         {:ok, _entry} <-
           audit(scope, work_item, "escalation_another_round", %{
             "stage_id" => escalation.stage_id,
             "cause" => Atom.to_string(escalation.cause)
           }) do
      {:ok, work_item}
    else
      {0, _rows} -> {:ok, Repo.get!(WorkItem, work_item.id)}
      {:error, _reason} = refused -> refused
    end
  end

  # confirmed_stage_id/2 is the stage whose proposal a confirmation of the run `attempt`
  # of the work item's take in confirms: the stage that run ran in, or, for a run with no
  # stage, the stage that runs `explore_workflow/1` (`explore_stage_id/1`).
  @doc false
  @spec confirmed_stage_id(WorkItem.t(), pos_integer) :: String.t() | nil
  def confirmed_stage_id(%WorkItem{id: id, take_in: take_in} = work_item, attempt) do
    Repo.one(
      from d in DispatchRun,
        where: d.work_item_id == ^id and d.take_in == ^take_in and d.attempt == ^attempt,
        where: d.step == "explore",
        select: d.stage_id
    ) || explore_stage_id(work_item)
  end

  # run_stage_id/2 is the stage a version that the run of the queue `run` pushes for
  # `work_item` is made in: the run's stage, or, for a run of Explore with no stage, one
  # queued before the workflow model was on, the stage that runs `explore_workflow/1`
  # (`explore_stage_id/1`), as `confirmed_stage_id/2` reads it. So the Exists check of
  # that stage finds the proposal the run pushed. nil for another run with no stage.
  @doc false
  @spec run_stage_id(DispatchRun.t(), WorkItem.t()) :: String.t() | nil
  def run_stage_id(%DispatchRun{stage_id: stage_id}, %WorkItem{}) when is_binary(stage_id),
    do: stage_id

  def run_stage_id(%DispatchRun{} = run, %WorkItem{} = work_item),
    do: if(explore_run?(run), do: explore_stage_id(work_item))

  # explore_stage_id/1 is the id of the stage of the work item's process version that runs
  # `explore_workflow/1`; nil for none.
  @doc false
  @spec explore_stage_id(WorkItem.t()) :: String.t() | nil
  def explore_stage_id(%WorkItem{} = work_item) do
    case Processes.version_for(work_item) do
      %{document: %{"stages" => _stages}} = version ->
        explore_stage_in(version, explore_workflow(work_item.workspace_id))

      _none ->
        nil
    end
  end

  # explore_stage_in/2 is the id of the stage of the process version `version` that runs
  # the workflow `explore` (`explore_workflow/1`); nil for none. A list reads `explore`
  # once for all its work items.
  @doc false
  @spec explore_stage_in(map | nil, String.t() | nil) :: String.t() | nil
  def explore_stage_in(%{document: %{"stages" => stages}}, explore) when is_list(stages),
    do: Enum.find_value(stages, &(explore in Runner.workflows(&1) && &1["id"]))

  def explore_stage_in(_version, _explore), do: nil

  ## What a person does

  # enter/3 moves the work item into the stage `stage_id` of its version and starts it.
  # `cause` is what moved it, for the caller's records. Checks no access: `move/4` is the
  # person's move. `{:error, :not_live}` for a work item that is not `:exploring`.
  @doc false
  @spec enter(WorkItem.t(), String.t(), atom) :: {:ok, WorkItem.t()} | {:error, refusal}
  def enter(%WorkItem{id: id}, stage_id, _cause) when is_binary(stage_id) do
    transact(fn ->
      work_item = lock!(id)
      version = Processes.version_for(work_item)

      with :ok <- live(work_item),
           stage when is_map(stage) <-
             Processes.stage(version, stage_id) || {:error, :unknown_stage} do
        :ok = close_open(work_item, :move_back, nil, nil)

        {work_item, _run} =
          enter_locked(%{work_item | process_version_id: version.id}, version, stage)

        {:ok, work_item}
      end
    end)
  end

  # resume/1 starts a stage that waits for a required input or for a workflow, once the
  # input exists or the harness declares the workflow: after a person adds an input, or
  # the harness changes. A stage in any other state, or of a work item that is not
  # `:exploring`, is left as it is. `{:error, :not_placed}` for a work item the runner has
  # not placed.
  @doc false
  @spec resume(WorkItem.t()) :: {:ok, WorkItem.t()} | {:error, refusal}
  def resume(%WorkItem{id: id}) do
    transact(fn ->
      work_item = lock!(id)

      case placed(work_item) do
        {:ok, version, stage} ->
          if work_item.state == :exploring and
               work_item.stage_state in [:waiting_inputs, :waiting_workflow] do
            {work_item, _run} = apply_event(work_item, version, stage, :resume)
            {:ok, work_item}
          else
            {:ok, work_item}
          end

        :not_placed ->
          {:error, :not_placed}
      end
    end)
  end

  # add_version/5 stores a version a person adds on the work item, as the scope's person
  # (`Apiary.Artifacts.push/5`, `{:person, scope}`, which refuses the questions and the
  # review comments as `{:unknown_type, name}`), with the `stage_id` of the stage the
  # work item is in, whatever `opts` gives, then acts on that stage (`version_added/1`):
  # `{:ok, version}`, or the push's refusal, with no action on the stage. The stage is read
  # before the push takes the work item's lock, so the push checks it again under the lock
  # (`expect_stage`): `{:error, :stage_changed}` when the work item moved in between.
  @doc false
  @spec add_version(Scope.t(), WorkItem.t(), term, [map], keyword) ::
          {:ok, map} | {:error, term}
  def add_version(%Scope{} = scope, %WorkItem{id: id}, type, files, opts \\ []) do
    case Repo.get(WorkItem, id) do
      nil ->
        {:error, :not_found}

      work_item ->
        opts =
          Keyword.merge(opts, stage_id: work_item.stage_id, expect_stage: work_item.stage_id)

        with {:ok, version} <- Artifacts.push({:person, scope}, work_item, type, files, opts) do
          _placed_or_not = version_added(work_item)
          {:ok, version}
        end
    end
  end

  # version_added/1 acts on the work item's stage after a person added a version in it. A
  # stage that waits for inputs starts once its last required input exists (`resume/1`).
  # At the gate of a stage with no workflow the Exists checks run again: a gate `none`
  # passes on once every required output exists, and a person gate keeps waiting. A stage
  # in any other state, or of a work item that is not `:exploring`, is left as it is.
  # `{:error, :not_placed}` for a work item the runner has not placed.
  @doc false
  @spec version_added(WorkItem.t()) :: {:ok, WorkItem.t()} | {:error, :not_placed}
  def version_added(%WorkItem{id: id}) do
    transact(fn ->
      work_item = lock!(id)

      case placed(work_item) do
        {:ok, version, stage} ->
          case on_version_added(work_item, stage) do
            nil ->
              {:ok, work_item}

            event ->
              {work_item, _run} = apply_event(work_item, version, stage, event)
              {:ok, work_item}
          end

        :not_placed ->
          {:error, :not_placed}
      end
    end)
  end

  # The runner's event for a version a person added in the work item's stage
  # (`version_added/1`): `:resume` for a stage that waits for inputs, `:version_added` at
  # the gate of a stage with no workflow; nil where the stage is left as it is.
  defp on_version_added(%WorkItem{state: :exploring, stage_state: :waiting_inputs}, _stage),
    do: :resume

  defp on_version_added(%WorkItem{state: :exploring, stage_state: :at_gate}, stage),
    do: if(Runner.people?(stage), do: :version_added)

  defp on_version_added(%WorkItem{}, _stage), do: nil

  # check_workflows/2 reads the workflow names the workspace's harness lists now, as the
  # scope's person, through the harness sources (`Apiary.Stacks.Sources`), stores them as
  # the workspace's snapshot, and starts the work item's stage when it waits for a
  # workflow the read found: `{:ok, work_item}`; `{:error, :still_missing}` when the
  # stage still waits; `{:error, :not_live}` for a work item that is not `:exploring`, read
  # under its lock; the read's error otherwise. It reads nothing for a person who may not
  # approve the stage's gate (`gate.approve`, asked of the work item): Access's reason.
  # `read` is the read, given only by tests.
  @doc false
  @spec check_workflows(Scope.t(), WorkItem.t(), (Scope.t(), Workspace.t() -> term)) ::
          {:ok, WorkItem.t()} | {:error, term}
  def check_workflows(%Scope{} = scope, %WorkItem{id: id}, read \\ &Sources.chosen_workflows/2) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id) || {:error, :not_found},
         :ok <- Access.authorize(scope, @action, found),
         {:ok, names} <- read.(scope, workspace) do
      :ok = Processes.record_declared(workspace, names)
      start_found(id)
    else
      :error -> {:error, :not_found}
      {:error, _reason} = refused -> refused
      other -> {:error, other}
    end
  end

  defp start_found(id) do
    transact(fn ->
      work_item = lock!(id)

      with :ok <- live(work_item),
           {:ok, version, stage} <- placed(work_item) do
        case on_found(work_item, fn -> facts(work_item, version, stage) end) do
          nil ->
            {:ok, work_item}

          :still_missing ->
            {:error, :still_missing}

          :resume ->
            {work_item, _run} = apply_event(work_item, version, stage, :resume)
            {:ok, work_item}
        end
      else
        :not_placed -> {:error, :not_placed}
        {:error, :not_live} = refused -> refused
      end
    end)
  end

  # The step after a read of the harness's workflows (`start_found/1`) for a stage that
  # waits for a workflow: `:resume` where the facts that `facts` returns have no
  # undeclared workflow, else `:still_missing`; nil for a stage in another state.
  defp on_found(%WorkItem{stage_state: :waiting_workflow}, facts),
    do: if(facts.().undeclared == [], do: :resume, else: :still_missing)

  defp on_found(%WorkItem{}, _facts), do: nil

  # approve/3 approves the gate of the work item's stage, with the scope's person's
  # `note`: the decision covers the newest version of each output made in the stage, and
  # the work item enters the next stage, or its stage is done after the last. At Explore's
  # gate it confirms today's proposal first (`Apiary.WorkItems.Moves`). The gate of a stage
  # with no workflow is refused while a required output is missing,
  # `{:error, {:outputs_missing, types}}` (`missing_outputs/1`).
  @doc false
  @spec approve(Scope.t(), WorkItem.t(), String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def approve(%Scope{} = scope, %WorkItem{} = work_item, note, opts \\ []) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
           :ok <- at_gate(work_item, stage),
           :ok <- outputs_exist(work_item, stage),
           {:ok, confirmed?} <- confirm_explore(scope, work_item, stage) do
        # A confirmation already wrote the act's entry in the audit trail.
        approve_locked(scope, lock!(work_item.id), version, stage, note, not confirmed?)
      end
    end)
  end

  # Today's confirmation, where Explore's proposal waits for it at the gate of the stage
  # that runs `explore_workflow/1`: the gate approves what a member confirms, so the two are
  # one act. The gate of any other stage confirms nothing.
  defp confirm_explore(scope, work_item, stage) do
    if explore_workflow(work_item.workspace_id) in Runner.workflows(stage),
      do: confirm_today(scope, work_item),
      else: {:ok, false}
  end

  defp confirm_today(scope, work_item) do
    case Explore.current(work_item, DateTime.utc_now()) do
      %{status: :confirm, step: %{attempt: attempt}} ->
        case Moves.confirm(scope, work_item, attempt) do
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
  @spec request_changes(Scope.t(), WorkItem.t(), String.t() | nil, String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def request_changes(
        %Scope{} = scope,
        %WorkItem{} = work_item,
        note,
        artifact_version_id,
        opts \\ []
      ) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
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
  # or close it.
  @doc false
  @spec resolve_escalation(Scope.t(), WorkItem.t(), resolution, String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def resolve_escalation(%Scope{} = scope, %WorkItem{} = work_item, resolution, note, opts \\ []) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
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

  defp resolve(scope, work_item, _version, _stage, escalation, :close, note) do
    :ok = resolve!(escalation, :close, scope, note)

    with {:ok, _ended} <- Moves.close(scope, work_item), do: {:ok, lock!(work_item.id)}
  end

  defp resolve(_scope, _work_item, _version, _stage, _escalation, _resolution, _note),
    do: {:error, :invalid}

  defp resolution_name({:move_back, _stage_id}), do: "move_back"
  defp resolution_name(resolution) when is_atom(resolution), do: Atom.to_string(resolution)

  # move/4 moves the work item to the stage `stage_id` of its version, forward past a
  # stage or back, with the person's note, and starts that stage.
  @doc false
  @spec move(Scope.t(), WorkItem.t(), String.t(), String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def move(%Scope{} = scope, %WorkItem{} = work_item, stage_id, note, opts \\ []) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
           target when is_map(target) <-
             Processes.stage(version, stage_id) || {:error, :unknown_stage},
           {:ok, _decision} <- decide(scope, work_item, version, stage, :move, [], nil, note),
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

  ## What an act would start

  # starts/2 is the workflow of the run that `act` would queue for the work item, by the
  # runner's rules (`Runner.step/4`) on the facts read now, with nothing written:
  # `{:run, workflow}`, or `:none` where `act` queues no run, or the work item is not
  # `:exploring` or not placed. A page reads it at a click, to confirm the spend first
  # (`ApiaryWeb.SpendDialog`). It reads no access: the act checks that. `act` is one of:
  #
  #   * `:approve` - the gate approved, at the gate: the next stage entered (`approve/4`);
  #   * `:request_changes` - at the gate (`request_changes/5`);
  #   * `:accept`, `:another_round` - the open escalation resolved so
  #     (`resolve_escalation/5`);
  #   * `{:move, stage_id}` - that stage of the version entered (`move/5`, and a move
  #     back that resolves an escalation);
  #   * `:found` - a stage that waits for a workflow, once the harness lists it
  #     (`check_workflows/3`);
  #   * `{:version_added, type}` - a version of `type` added in the stage
  #     (`add_version/5`), counted as existing;
  #   * `:next_run` - the next round of the stage (`next_run/2`).
  @doc false
  @spec starts(WorkItem.t(), term) :: {:run, String.t()} | :none
  def starts(%WorkItem{id: id}, act) do
    with %WorkItem{state: :exploring} = work_item <- Repo.get(WorkItem, id),
         {:ok, version, stage} <- placed(work_item) do
      would_start(work_item, version, stage, act)
    else
      _other -> :none
    end
  end

  # at_stage?/2 is whether the work item, read now, is open and in the stage with
  # `stage_id`: a page reads it at a click, so a click on a stage the work item has left
  # confirms no spend.
  @doc false
  @spec at_stage?(WorkItem.t(), String.t() | nil) :: boolean
  def at_stage?(%WorkItem{id: id}, stage_id) when is_binary(stage_id),
    do: match?(%WorkItem{state: :exploring, stage_id: ^stage_id}, Repo.get(WorkItem, id))

  def at_stage?(%WorkItem{}, nil), do: false

  # The approval covers the stage's newest outputs (`approve_locked/6`), which each later
  # stage then reads as its inputs of those types: the next stage, and each stage that a
  # stage passing on enters.
  defp would_start(work_item, version, stage, :approve) do
    with :ok <- at_gate(work_item, stage),
         :ok <- outputs_exist(work_item, stage),
         %{} = next <- next_stage(version, stage) do
      artifacts = Artifacts.list(work_item)
      ids = Enum.map(newest_outputs(work_item, stage, artifacts), & &1.public_id)
      covered = for a <- artifacts, v <- a.versions, v.public_id in ids, uniq: true, do: a.type
      approved = &%{&1 | missing_inputs: &1.missing_inputs -- covered}

      stepped(work_item, version, next, :enter, approved, approved)
    else
      _no_run -> :none
    end
  end

  defp would_start(work_item, version, stage, :request_changes) do
    if at_gate(work_item, stage) == :ok,
      do: stepped(work_item, version, stage, :request_changes, & &1),
      else: :none
  end

  defp would_start(%WorkItem{stage_state: :escalated} = work_item, version, stage, resolution)
       when resolution in [:accept, :another_round] do
    %Escalation{cause: cause} =
      open_escalation(work_item) || placed_escalation(work_item, version, stage)

    stepped(work_item, version, stage, {resolution, cause}, & &1)
  end

  defp would_start(work_item, version, _stage, {:move, stage_id}) when is_binary(stage_id),
    do: entered(work_item, version, Processes.stage(version, stage_id))

  # Once the harness lists the stage's workflows.
  defp would_start(work_item, version, stage, :found) do
    found = &%{&1 | undeclared: []}

    case on_found(work_item, fn -> found.(facts(work_item, version, stage)) end) do
      :resume -> stepped(work_item, version, stage, :resume, found)
      _no_run -> :none
    end
  end

  # The added version counts as existing: as an input of the stage, or as an output at
  # its gate.
  defp would_start(work_item, version, stage, {:version_added, type}) when is_binary(type) do
    case on_version_added(work_item, stage) do
      :resume ->
        stepped(work_item, version, stage, :resume, fn facts ->
          %{facts | missing_inputs: facts.missing_inputs -- [type]}
        end)

      :version_added ->
        stepped(work_item, version, stage, :version_added, fn facts ->
          %{facts | failed_checks: facts.failed_checks -- [type]}
        end)

      nil ->
        :none
    end
  end

  defp would_start(work_item, version, stage, :next_run) do
    {event, _escalation} = next_event(work_item)
    stepped(work_item, version, stage, event, & &1)
  end

  defp would_start(_work_item, _version, _stage, _act), do: :none

  # The run that entering `stage` queues, on the facts read now as `later` changes them;
  # none for no stage.
  defp entered(work_item, version, stage, later \\ & &1)
  defp entered(_work_item, _version, nil, _later), do: :none

  defp entered(work_item, version, stage, later),
    do: stepped(work_item, version, stage, :enter, later, later)

  # The run that the runner's outcome of `event` queues, on the facts read now as `adjust`
  # changes them: its first `:queue`, or what its `:advance` enters, in the order
  # `apply_outcome/5` applies them. Each stage that an `:advance` enters reads its facts
  # as `later` changes them.
  defp stepped(work_item, version, stage, event, adjust, later \\ & &1) do
    facts = adjust.(facts(work_item, version, stage))
    %{actions: actions} = Runner.step(stage, position(work_item), event, facts)

    Enum.reduce_while(actions, :none, fn
      {:queue, %{workflow: workflow}}, _none ->
        {:halt, {:run, workflow}}

      :advance, _none ->
        {:halt, entered(work_item, version, next_stage(version, stage), later)}

      _other, none ->
        {:cont, none}
    end)
  end

  ## Reading

  # status/2 is where the work item stands in its stage, as the work item page draws it;
  # nil for a work item the runner has not placed. `scope` decides whether its person may
  # approve the gate; with none, `approvable?` is false. `missing_outputs` is the
  # required output types whose Exists check fails (`missing_outputs/1`); while it has
  # one, the gate of a stage with no workflow is not approvable. `loop` is whether the
  # work item is in a loop of its stage: `rounds` is that loop's limit, or, past the last
  # loop, the limit of the loop it left, which a later entry's runs do not count by.
  # `escalation` is the open escalation with its `points` (`shown_points/5`), also while
  # the stage waits for answers; `gaps` is why a stage waits for a workflow, else the
  # failed checks that started its round, nil with an escalation.
  @doc false
  @spec status(WorkItem.t(), Scope.t() | nil) :: map | nil
  def status(%WorkItem{} = work_item, scope \\ nil) do
    work_item = Repo.get(WorkItem, work_item.id)

    with %WorkItem{} <- work_item,
         {:ok, version, stage} <- placed(work_item) do
      artifacts = Artifacts.list(work_item)
      escalation = open_escalation(work_item) || placed_escalation(work_item, version, stage)
      state = shown_state(work_item, stage, artifacts)
      outputs = outputs(work_item, stage, artifacts)
      missing = missing(outputs)

      %{
        stage: %{id: stage["id"], name: stage["name"]},
        version: %{id: version.public_id, number: version.number},
        round: work_item.stage_round,
        rounds: shown_rounds(stage, work_item.stage_entry),
        loop: is_integer(work_item.loop_entry),
        state: state,
        gaps: shown_gaps(escalation, work_item, stage, artifacts),
        outputs: outputs,
        missing_outputs: missing,
        inputs: inputs(work_item, version, stage, artifacts),
        escalation: escalation_map(escalation, work_item, stage, outputs, artifacts),
        waiting_workflow: waiting_workflow(work_item, stage),
        gate: %{
          kind: get_in(stage, ["gate", "kind"]) || "person",
          approvers: Approvers.listed(stage),
          approvable?:
            state == :at_gate and Approvers.listed?(scope, stage) and
              not (Runner.people?(stage) and missing != []),
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

  # artifact_index/1 is every artifact of the work item with its versions, newest first,
  # their writers and the approvals that cover each: for each artifact, the public id of
  # the newest approved version, and whether a version of an earlier stage's artifact was
  # made after that approval ("changed after approval").
  @doc false
  @spec artifact_index(WorkItem.t()) :: [map]
  def artifact_index(%WorkItem{} = work_item) do
    work_item = Repo.get!(WorkItem, work_item.id)
    approvals = approvals_by_version(work_item)

    for artifact <- Artifacts.list(work_item) do
      versions = Enum.map(artifact.versions, &version_map(&1, approvals))
      newest = List.first(versions)
      approved_version = Enum.find(versions, &(&1.approvals != []))
      newer? = approved_version != nil and newest.number > approved_version.number

      %{
        type: artifact.type,
        name: artifact.name,
        stage_id: newest && newest.stage_id,
        approved_version: approved_version && approved_version.id,
        changed_after_approval: newer? and newest.stage_id != work_item.stage_id,
        versions: versions
      }
    end
  end

  # runs/1 is the work item's runs of stages, newest first: each with the public id of its
  # registered run (`rn_…`, nil before a claim registers it), its workflow, stage, round,
  # `take_in` and `attempt` (its place in the take in, from 1), `of` (the attempts its
  # take in may reach), `status` (the state of the run of the
  # queue: waiting, claimed, handed_over or ended), `end_cause` (why the run of the queue
  # ended, nil while it has not), `verdict` from its verdict artifact
  # (`:passed`; `:failed` for changes-requested or escalate; nil for none), and when it
  # started and ended, nil for not yet. A run of Explore with no verdict whose outcome is
  # its proposal (`Apiary.Explore.Outcome`) has the verdict `:passed`, as the work item
  # page showed it when Core wrote that verdict for it. A run that an escalation
  # `run_stopped` came from has none, whatever it pushed: one run never reads as passed
  # and stopped.
  @doc false
  @spec runs(WorkItem.t()) :: [map]
  def runs(%WorkItem{id: id} = work_item) do
    verdicts = run_verdicts(work_item)
    stopped = stopped_runs(work_item)

    Repo.all(
      from d in DispatchRun,
        left_join: r in subquery(Run.registered()),
        on: r.dispatch_run_id == d.id,
        where: d.work_item_id == ^id and not is_nil(d.stage_id),
        order_by: [desc: d.take_in, desc: d.attempt],
        select: {d, r}
    )
    |> Enum.map(fn {dispatch_run, run} ->
      %{
        id: run && run.public_id,
        workflow: dispatch_run.workflow,
        stage_id: dispatch_run.stage_id,
        round: dispatch_run.round,
        take_in: dispatch_run.take_in,
        attempt: dispatch_run.attempt,
        of: dispatch_run.of,
        status: dispatch_run.state,
        end_cause: dispatch_run.end_cause,
        verdict:
          unless MapSet.member?(stopped, dispatch_run.id) do
            verdicts[dispatch_run.id] || (run && verdicts[run.id]) || proposed(dispatch_run)
          end,
        started_at: run && run.started_at,
        ended_at: ended_at(dispatch_run, run)
      }
    end)
  end

  defp proposed(%DispatchRun{result_outcome: :proposal} = run),
    do: if(explore_run?(run), do: :passed)

  defp proposed(%DispatchRun{}), do: nil

  # The runs of the queue of the work item that an escalation `run_stopped` came from,
  # resolved or not.
  defp stopped_runs(%WorkItem{id: id}) do
    Repo.all(
      from e in Escalation,
        where: e.work_item_id == ^id and e.cause == :run_stopped and not is_nil(e.run_id),
        select: e.run_id
    )
    |> MapSet.new()
  end

  defp ended_at(%DispatchRun{state: :ended}, %Run{exited_at: %DateTime{} = at}), do: at
  defp ended_at(%DispatchRun{state: :ended, updated_at: at}, _run), do: at
  defp ended_at(_dispatch_run, _run), do: nil

  # The verdict of each run that stored one, by the run's id: the newest of its versions.
  defp run_verdicts(work_item) do
    for artifact <- Artifacts.list(work_item),
        artifact.type == "verdict" and artifact.name == "main",
        version <- Enum.reverse(artifact.versions),
        is_binary(version.run_id),
        into: %{} do
      verdict =
        case (Artifacts.read_json(version) || %{})["verdict"] do
          "passed" -> :passed
          value when value in ["changes-requested", "escalate"] -> :failed
          _none -> nil
        end

      {version.run_id, verdict}
    end
  end

  # notes/1 is what the work item's next run reads as work item data, oldest first: what
  # people wrote (requests for changes, escalations resolved with a note, moves and the
  # answers to a run's questions) and the gaps of failed checks that started a round
  # (`:check`, with no person). What members gave Explore (`Apiary.Explore.Given`) are
  # notes of kind `:answer`: an answer, a review comment or a reply, the last two with
  # `comment` true, as the run API sends them.
  @doc false
  @spec notes(WorkItem.t()) :: [map]
  def notes(%WorkItem{id: id} = work_item) do
    decisions =
      Repo.all(
        from d in GateDecision,
          where: d.work_item_id == ^id and d.kind in [:request_changes, :move],
          select: %{
            kind: d.kind,
            stage_id: d.stage_id,
            user_id: d.user_id,
            note: d.note,
            artifact_version_id: d.artifact_version_id,
            inserted_at: d.inserted_at
          }
      )

    escalations =
      Repo.all(
        from e in Escalation,
          where: e.work_item_id == ^id and not is_nil(e.resolved_at) and not is_nil(e.note),
          select: %{
            kind: :escalation,
            stage_id: e.stage_id,
            user_id: e.resolved_by_id,
            note: e.note,
            artifact_version_id: nil,
            inserted_at: e.resolved_at
          }
      )

    checks =
      Repo.all(
        from c in Check,
          where: c.work_item_id == ^id,
          select: %{
            kind: :check,
            stage_id: c.stage_id,
            user_id: nil,
            note: c.gaps,
            artifact_version_id: nil,
            inserted_at: c.inserted_at
          }
      )

    answers = given_notes(work_item)

    Enum.sort_by(decisions ++ escalations ++ checks ++ answers, & &1.inserted_at, DateTime)
  end

  # What members gave Explore as notes, each with the stage of the run it was given at.
  defp given_notes(work_item) do
    case Apiary.Explore.Given.all(work_item) do
      [] ->
        []

      given ->
        stages =
          Map.new(
            Repo.all(
              from r in DispatchRun,
                where: r.work_item_id == ^work_item.id,
                select: {{r.take_in, r.attempt}, r.stage_id}
            )
          )

        for entry <- given do
          %{
            kind: :answer,
            comment: entry.kind != :answer,
            stage_id: Map.get(stages, {entry.take_in, entry.attempt}),
            user_id: entry.by_id,
            note: entry.text,
            artifact_version_id: nil,
            inserted_at: entry.at
          }
        end
    end
  end

  # A version of an artifact as the reads give it, with the approvals that cover it.
  defp version_map(version, approvals) do
    %{
      id: version.public_id,
      number: version.number,
      writer: version.writer,
      run_id: version.run_id,
      user_id: version.user_id,
      stage_id: version.stage_id,
      note: Map.get(version, :note),
      inserted_at: version.inserted_at,
      files: Map.get(version, :files, []),
      approvals: Map.get(approvals, version.public_id, [])
    }
  end

  # The approvals of the work item by the public id of each version they cover, oldest
  # first.
  defp approvals_by_version(work_item) do
    Repo.all(
      from d in GateDecision,
        where: d.work_item_id == ^work_item.id and d.kind == :approve,
        order_by: d.inserted_at
    )
    |> Enum.flat_map(fn decision ->
      approval = %{
        user_id: decision.user_id,
        stage_id: decision.stage_id,
        inserted_at: decision.inserted_at
      }

      for id <- decision.versions, do: {id, approval}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  ## Applying the runner's rules

  defp enter_locked(work_item, version, stage), do: apply_event(work_item, version, stage, :enter)

  # `more` is facts of the run that ended, beside the stage's (`facts/3`).
  defp apply_event(work_item, version, stage, event, run_id \\ nil, more \\ %{}) do
    facts = Map.merge(facts(work_item, version, stage), more)
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

      {:escalate, cause, points}, {work_item, run} ->
        :ok = escalate!(work_item, version, stage, position, cause, points, run_id)
        {work_item, run}

      {:checks_failed, round, gaps}, {work_item, run} ->
        %Check{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          stage_id: stage["id"],
          process_version_id: version.id,
          round: round,
          gaps: gaps,
          inserted_at: DateTime.utc_now()
        }
        |> Repo.insert!()

        {work_item, run}

      :advance, {work_item, _run} ->
        advance(work_item, version, stage)
    end)
  end

  # The next stage of the version after `stage`, entered; after the last, the stage is
  # done and the work item closes.
  defp advance(work_item, version, stage) do
    case next_stage(version, stage) do
      nil -> {finish(work_item, version, stage), nil}
      next -> enter_locked(work_item, version, next)
    end
  end

  # The stage of the version after `stage`; nil after the last.
  defp next_stage(version, stage) do
    stages = version.document["stages"]
    index = Enum.find_index(stages, &(&1["id"] == stage["id"]))
    Enum.at(stages, index + 1)
  end

  # The last stage is done: in the same transaction the instance closes the work item,
  # which the caller holds, and `stage_state` stays `:done` (`Apiary.WorkItems.Finished`).
  # The stage's runs have ended, so the close changes no queue.
  defp finish(work_item, version, stage) do
    work_item = place!(work_item, version, stage["id"], :done, position(work_item))
    now = DateTime.utc_now()

    {:ok, _workspace_ids} =
      WorkItems.close_locked([work_item], {:instance, "last_stage_done"}, now)

    %{work_item | state: :closed, closed_at: now}
  end

  defp facts(work_item, version, stage) do
    # The whole row: `Apiary.Processes.workflow_declaration/2` reads its stack.
    workspace = Repo.get!(Workspace, work_item.workspace_id)
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
      undeclared: undeclared(workspace, declarations),
      declarations: declarations,
      failed_checks: missing(outputs(work_item, stage, artifacts)),
      machine: version.document["machine"],
      test: work_item.test
    }
  end

  # The stage's workflows that hold it back: with a snapshot of the names the workspace's
  # harness listed, each that is in neither it nor the declarations
  # (`Apiary.Processes.workflow_declaration/2`: the Qory harness's and the saved workflow);
  # with no snapshot, none, and the run starts.
  defp undeclared(workspace, declarations) do
    case Processes.declared_snapshot(workspace) do
      %{names: names} -> for {name, nil} <- declarations, name not in names, do: name
      nil -> []
    end
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

  # A run's `of`: in a loop, the attempt plus the rounds left; outside a loop, the runs
  # its entry may have in one round, as many as a take in of today's Explore
  # (`@question_runs`), so a workflow may ask questions and run again with the answers.
  defp queue!(work_item, version, stage, spec) do
    rounds_left =
      case Runner.rounds(stage, spec.entry) do
        nil -> @question_runs - 1 - runs_of_entry(work_item, stage, spec)
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
        machine_type: MachineTypes.run_key(spec.machine_type, version.document["machine"])
      }
    })
  end

  # The runs queued before for the entry of `spec`, in its round, in the take in. A run
  # that continues a paused run (`Apiary.Dispatches.requeue_for_pause/2`) is no new run.
  defp runs_of_entry(work_item, stage, spec) do
    Repo.aggregate(
      from(d in DispatchRun,
        where: d.work_item_id == ^work_item.id and d.take_in == ^work_item.take_in,
        where: d.stage_id == ^stage["id"] and d.stage_entry == ^spec.entry,
        where: d.round == ^spec.round and is_nil(d.continues_id)
      ),
      :count
    )
  end

  defp escalate!(work_item, version, stage, position, cause, points, run_id) do
    :ok = close_open(work_item, :close, nil, nil)

    %Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      round: position.round,
      cause: cause,
      points: points,
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

  # What the run gave, as the runner reads it, with the facts of the run for the runner
  # (`Apiary.Stages.Runner.facts/0`); `:unsettled` while a run ended by its exit has no
  # outcome stored yet (`Apiary.Dispatches.Settle`), and while whether it is a run of
  # Explore is not known yet (`known_explore/1`).
  defp run_result(_work_item, %DispatchRun{end_cause: :run_ended, result_outcome: nil}, _ctx),
    do: :unsettled

  defp run_result(_work_item, %DispatchRun{end_cause: cause}, _context)
       when cause in @ignored_ends,
       do: :ignored

  defp run_result(work_item, %DispatchRun{} = run, context) do
    case known_explore(run) do
      nil -> :unsettled
      %DispatchRun{explore: true} = run -> explore_result(work_item, run, context)
      %DispatchRun{end_cause: :run_ended} = run -> {:ok, reported_result(work_item, run), %{}}
      run -> {:ok, {:stopped, stopped_points(run, work_item, context)}, %{}}
    end
  end

  # Whether `run` is a run of Explore whose take in has a proposal, or that left open
  # questions, as Settle stored its outcome (`Apiary.Explore.Outcome` returns these only
  # for a run of Explore).
  defp explore_result?(%DispatchRun{result_outcome: outcome}),
    do: outcome in [:proposal, :questions]

  # explore_run?/1 is whether the run of the queue `run` is a run of Explore, as its
  # record keeps it (`Apiary.Dispatches.DispatchRun`), else as `explore_at_queue/3` reads
  # it now, with nothing written: nil where that is not known yet, which reads as neither
  # (`known_explore/1`).
  @doc false
  @spec explore_run?(DispatchRun.t()) :: boolean | nil
  def explore_run?(%DispatchRun{explore: explore}) when is_boolean(explore), do: explore

  def explore_run?(%DispatchRun{} = run),
    do: explore_at_queue(run.step, run.workflow, run.workspace_id)

  # known_explore/1 is `run` once whether it is a run of Explore is known: as its record
  # keeps it, else as `explore_at_queue/3` reads it now, written to its record. Nil where
  # that is still not known, as no files of the Qory harness are kept yet: the claim
  # leaves such a run queued, and the stage runner leaves its end for its sweep.
  @doc false
  @spec known_explore(DispatchRun.t()) :: DispatchRun.t() | nil
  def known_explore(%DispatchRun{explore: explore} = run) when is_boolean(explore), do: run

  def known_explore(%DispatchRun{id: id} = run) do
    case explore_at_queue(run.step, run.workflow, run.workspace_id) do
      nil ->
        nil

      explore ->
        {_count, _rows} =
          Repo.update_all(from(r in DispatchRun, where: r.id == ^id and is_nil(r.explore)),
            set: [explore: explore]
          )

        %{run | explore: explore}
    end
  end

  # explore_at_queue/3 is whether a run of `step` and `workflow`, queued in the workspace
  # `workspace_id` now, is a run of Explore, as the run keeps it
  # (`Apiary.Dispatches.DispatchRun`): one of the step `explore` with no workflow, or of
  # `explore_workflow/1`; nil where no files of the Qory harness are kept yet, and the
  # run's end reads it then.
  @doc false
  @spec explore_at_queue(String.t(), String.t() | nil, Ecto.UUID.t()) :: boolean | nil
  def explore_at_queue("explore", nil, _workspace_id), do: true

  def explore_at_queue("explore", workflow, workspace_id) do
    case explore_workflow(workspace_id) do
      nil -> if Qory.newest(), do: false
      explore -> workflow == explore
    end
  end

  def explore_at_queue(_step, _workflow, _workspace_id), do: false

  # Explore: open questions first, with the points of the verdict `escalate` where the run
  # pushed one, then the verdict `escalate` of a run that ended by its exit (`verdict!/1`),
  # then a run that stopped, else a run with no verdict. A verdict other than `escalate`
  # counts as none. A run whose registered run failed after it pushed a proposal stopped,
  # and its cause shows the proposal's version
  # (`StopCause.failed_after_proposal/1`); where the run pushed none, it reads as any
  # stopped run. Beside it, the facts of the run for the runner: whether its take in has a
  # proposal or it left open questions (`explore_result?/1`), and whether it pushed
  # `passed` or `changes-requested`, so that a run with neither stops its stage.
  defp explore_result(work_item, run, context) do
    open = open_questions(work_item, run)
    verdict = verdict!(run)

    result =
      cond do
        open != [] ->
          {:questions, question_texts(open), escalate_points(verdict, open)}

        match?({:verdict, :escalate, _points}, verdict) ->
          open_points(verdict, open)

        stopped?(run) ->
          case failed_proposal(run) do
            nil ->
              {:stopped, stopped_points(run, work_item, context)}

            version ->
              {:stopped, Points.run_stopped(StopCause.failed_after_proposal(version), nil)}
          end

        true ->
          {:verdict, nil, nil}
      end

    pushed =
      open == [] and
        match?({:verdict, value, _points} when value in [:passed, :changes_requested], verdict)

    {:ok, result, %{explore_result: explore_result?(run), explore_verdict: pushed}}
  end

  # The open questions of the work item's newest questions that are of the run's take in
  # (`Apiary.Explore.Questions.open_in_take_in/2`); a newest version whose file cannot be
  # read raises, so the end is not read as one with no open question.
  defp open_questions(work_item, %DispatchRun{take_in: take_in}) do
    case Apiary.Explore.Questions.current(work_item) do
      {:ok, {_version, document}} ->
        runs = Apiary.Explore.Questions.take_in_runs(work_item.id, take_in)
        Apiary.Explore.Questions.open_in_take_in(document, runs)

      {:ok, nil} ->
        []

      {:error, :store_unavailable} ->
        raise Apiary.Stages.QuestionsUnreadable
    end
  end

  # A run that ended before its exit, or whose registered run failed, was lost or was
  # cancelled.
  defp stopped?(%DispatchRun{end_cause: :run_ended} = run) do
    match?(
      %Run{exit_state: state} when state in ["failed", "lost", "cancelled"],
      Repo.one(from r in Run.registered(), where: r.dispatch_run_id == ^run.id)
    )
  end

  defp stopped?(%DispatchRun{}), do: true

  # The number of the newest version of the proposal named `main` that `run`, which ended
  # by its exit, pushed before its registered run failed; nil for none.
  defp failed_proposal(%DispatchRun{id: id, end_cause: :run_ended}) do
    Repo.one(
      from v in Apiary.Artifacts.Version,
        join: a in Apiary.Artifacts.Artifact,
        on: a.id == v.artifact_id,
        join: r in subquery(Run.registered()),
        on: r.dispatch_run_id == v.run_id,
        where: v.run_id == ^id and a.type == "proposal" and a.name == "main",
        where: r.exit_state == "failed",
        select: max(v.number)
    )
  end

  defp failed_proposal(%DispatchRun{}), do: nil

  # A run of a workflow other than Explore: the open questions of the run's take in
  # (`open_questions/2`), with the points of its verdict `escalate` where it pushed one,
  # else the newest verdict named `main` that the run pushed (`verdict!/1`), else stopped
  # when its registered run failed, was lost or was cancelled.
  defp reported_result(work_item, run) do
    open = open_questions(work_item, run)

    cond do
      open != [] ->
        {:questions, question_texts(open), escalate_points(verdict!(run), open)}

      verdict = verdict!(run) ->
        open_points(verdict, open)

      match?(
        %Run{exit_state: state} when state in ["failed", "lost", "cancelled"],
        Repo.one(from r in Run.registered(), where: r.dispatch_run_id == ^run.id)
      ) ->
        {:stopped, stopped_points(run, work_item, %{})}

      true ->
        {:verdict, nil, nil}
    end
  end

  # reported_verdict/1 is the newest version of the `verdict` named `main` that `run`
  # pushed, where `run` ended by its exit, as the stage runner reads it:
  # `{:verdict, verdict, points}`, with a nil verdict for a value other than `passed`,
  # `changes-requested` or `escalate`, or for a file that is not a JSON object;
  # `{:error, :store_unavailable}` when the store cannot read its file; nil where the run
  # pushed none or ended another way. `Apiary.Explore.Outcome` reads it for Explore's
  # `escalate`.
  @doc false
  @spec reported_verdict(DispatchRun.t()) ::
          Runner.run_result() | {:error, :store_unavailable} | nil
  def reported_verdict(%DispatchRun{end_cause: :run_ended} = run) do
    case Artifacts.newest_of_run(run, "verdict", "main") do
      nil ->
        nil

      version ->
        with {:ok, document} <- Artifacts.stored_json(version) do
          document = document || %{}
          {:verdict, verdict(document["verdict"]), points(document["points"])}
        end
    end
  end

  def reported_verdict(%DispatchRun{}), do: nil

  # The verdict of a run of any workflow as `reported_verdict/1` reads it; a verdict whose
  # file the store cannot read raises, so the end is not read as one with no verdict.
  defp verdict!(run) do
    case reported_verdict(run) do
      {:error, :store_unavailable} -> raise Apiary.Stages.VerdictUnreadable
      verdict -> verdict
    end
  end

  # The points of a verdict `escalate`, with the open questions `open` (`open_points/2`);
  # nil for any other verdict and for none.
  defp escalate_points(verdict, open) do
    case open_points(verdict, open) do
      {:verdict, :escalate, points} -> points
      _other -> nil
    end
  end

  # The verdict `escalate` with each `answer` point whose question is not among the open
  # questions `open` turned into a `run_again` point with the same sentence: a question
  # withdrawn after the verdict can no longer be answered. No point is dropped.
  defp open_points({:verdict, :escalate, points}, open) when is_list(points) do
    ids = MapSet.new(open, & &1["id"])

    {:verdict, :escalate,
     for point <- points do
       if point["action"] == "answer" and not MapSet.member?(ids, point["question"]),
         do: point |> Map.delete("question") |> Map.put("action", "run_again"),
         else: point
     end}
  end

  defp open_points(verdict, _open), do: verdict

  # The points of a verdict's file: its list of point objects, nil for none. A run's
  # point never has `fix`, which only Core writes (`Apiary.Stages.Points`).
  defp points(points) when is_list(points),
    do: for(%{} = point <- points, do: Map.take(point, ~w(text action question)))

  defp points(_none), do: nil

  defp verdict("passed"), do: :passed
  defp verdict("changes-requested"), do: :changes_requested
  defp verdict("escalate"), do: :escalate
  defp verdict(_none), do: nil

  # The point of why `run` stopped, with its fix where it has one
  # (`Apiary.Stages.StopCause.parts/3`, `Apiary.Stages.Points.run_stopped/2`).
  defp stopped_points(run, work_item, context) do
    {cause, fix} = StopCause.parts(run, work_item, context)
    Points.run_stopped(cause, fix)
  end

  # The questions of a `questions` version that wait for an answer, as the questions a
  # stage waits on show them: the text of each, one after the other.
  defp question_texts(questions) do
    questions
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"question" => text} when is_binary(text) -> [text]
      text when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  ## Gates

  # The work item in the scope's workspace, locked, with its version and stage, once the
  # scope may take `gate.approve` on it (`Apiary.Access`): asked before the lock, so a
  # person Access refuses never holds the row, and again of the locked row, so the
  # approvers of the stage the row is in under its lock decide.
  defp hold(scope, %WorkItem{id: id}, opts) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id),
         :ok <- Access.authorize(scope, @action, found),
         work_item = lock!(found.id),
         :ok <- Access.authorize(scope, @action, work_item),
         :ok <- expected(work_item, opts),
         :ok <- live(work_item),
         {:ok, version, stage} <- placed(work_item) do
      {:ok, work_item, version, stage}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      :not_placed -> {:error, :not_placed}
      {:error, _reason} = refused -> refused
    end
  end

  defp live(%WorkItem{state: :exploring}), do: :ok
  defp live(%WorkItem{}), do: {:error, :not_live}

  # A person's action applies only to the stage their page showed: a work item that moved
  # on since, or an action that names no stage, is refused (`t:expect/0`).
  defp expected(%WorkItem{stage_id: stage_id}, opts) do
    case Keyword.get(opts, :expect_stage) do
      expected when is_binary(expected) and expected == stage_id -> :ok
      _other -> {:error, :stage_changed}
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
  # placing open work items placed as escalated without one; else `{:error, :not_escalated}`,
  # as for a stage that waits for answers with an escalation open: open questions come
  # first.
  defp escalation!(work_item, version, stage) do
    cond do
      work_item.stage_state != :escalated ->
        {:error, :not_escalated}

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

  defp escalation_map(nil, _work_item, _stage, _outputs, _artifacts), do: nil

  defp escalation_map(%Escalation{} = escalation, work_item, stage, outputs, artifacts) do
    run = escalation.run_id && Repo.get(DispatchRun, escalation.run_id)
    # A run that ended before its record kept whether it is a run of Explore reads it as
    # `explore_run?/1` does, with nothing written.
    run = run && %{run | explore: explore_run?(run)}
    stopped = run_stopped?(run, artifacts)

    %{
      cause: escalation.cause,
      points: shown_points(escalation, run, stopped, work_item, stage, outputs),
      no_verdict: escalation.cause == :run_stopped and is_struct(run) and not stopped,
      round: escalation.round,
      run: run && %{id: run.id, attempt: run.attempt, workflow: run.workflow},
      build_run: build_run(run, escalation),
      set_up_step: StopCause.set_up_step(run),
      inserted_at: escalation.inserted_at
    }
  end

  # The escalation's points. An escalation with none (one open when points replaced its
  # gaps, or `placed_escalation/3`) shows the points the stage runner writes for its cause
  # (`Apiary.Stages.Runner`), from what the stage reads now: the round limit, with the
  # failed checks where the work item is past the sequence's end; the failed checks (none
  # where every output exists now, as the failed types are not kept); why the run stopped
  # (`run_stopped?/2`), with no claim context (`stopped_run_points/2`); else no verdict,
  # also with no run. A run's `escalate` with no points shows none.
  defp shown_points(
         %Escalation{points: [_ | _] = points},
         _run,
         _stopped,
         _work_item,
         _stage,
         _outputs
       ),
       do: points

  defp shown_points(
         %Escalation{cause: :round_limit, round: round},
         _run,
         _stopped,
         work_item,
         stage,
         outputs
       )
       when is_integer(round) and round > 0 do
    rounds = shown_rounds(stage, work_item.stage_entry) || round
    checks = if past_end?(stage, work_item), do: missing(outputs), else: []
    Points.round_limit(round, rounds) ++ Points.check_failed(checks)
  end

  defp shown_points(
         %Escalation{cause: :check_failed},
         _run,
         _stopped,
         _work_item,
         _stage,
         outputs
       ),
       do: Points.check_failed(missing(outputs))

  defp shown_points(%Escalation{cause: :run_stopped}, run, stopped, work_item, _stage, _outputs) do
    if stopped,
      do: stopped_run_points(run, work_item),
      else: Points.no_verdict()
  end

  defp shown_points(_escalation, _run, _stopped, _work_item, _stage, _outputs), do: []

  # Whether the work item is past its sequence's last entry, where the stage runner runs
  # the checks (`Runner.at_end?/2`): a loop that reaches its round limit there writes the
  # failed checks with it, one that reaches it in its body does not.
  defp past_end?(stage, %WorkItem{stage_entry: entry}) when is_integer(entry),
    do: Runner.at_end?(stage, %{entry: entry})

  defp past_end?(_stage, _work_item), do: false

  # Whether the escalation's run stopped as the stage runner read its end: a run with no
  # end did not; a run of a workflow other than Explore that ended by its exit and pushed
  # a verdict named `main` ended with that verdict (`reported_result/2`), so its
  # `run_stopped` is one of no verdict; else `stopped?/1`. `artifacts` is the work item's
  # artifacts with their versions (`Artifacts.list/1`).
  defp run_stopped?(%DispatchRun{end_cause: nil}, _artifacts), do: false

  defp run_stopped?(%DispatchRun{explore: false, end_cause: :run_ended} = run, artifacts),
    do: not pushed_verdict?(run, artifacts) and stopped?(run)

  defp run_stopped?(%DispatchRun{} = run, _artifacts), do: stopped?(run)
  defp run_stopped?(nil, _artifacts), do: false

  defp pushed_verdict?(%DispatchRun{id: id}, artifacts) do
    Enum.any?(artifacts, fn artifact ->
      artifact.type == "verdict" and artifact.name == "main" and
        Enum.any?(artifact.versions, &(&1.run_id == id))
    end)
  end

  # The point of why `run` stopped, as its end wrote it: for a run of Explore that pushed a
  # proposal before its registered run failed, the proposal's version
  # (`explore_result/3`); else its stop cause, without the claim's gateway and keys, which
  # the run does not keep (`stopped_points/3`).
  defp stopped_run_points(%DispatchRun{explore: true} = run, work_item) do
    case failed_proposal(run) do
      nil -> stopped_points(run, work_item, %{})
      version -> Points.run_stopped(StopCause.failed_after_proposal(version), nil)
    end
  end

  defp stopped_run_points(run, work_item), do: stopped_points(run, work_item, %{})

  # For a run that stopped because its environment's build failed, the public id of the
  # run whose page has the build's log (`StopCause.build_run/1`); nil otherwise.
  defp build_run(%DispatchRun{end_cause: :build_failed}, %Escalation{work_item_id: id}),
    do: StopCause.build_run(Repo.get!(WorkItem, id))

  defp build_run(_run, _escalation), do: nil

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

  # missing_outputs/1 is the required output types of the work item's stage whose Exists
  # check fails, in the stage's order; [] for a work item the runner has not placed.
  @doc false
  @spec missing_outputs(WorkItem.t()) :: [String.t()]
  def missing_outputs(%WorkItem{} = work_item) do
    work_item = Repo.get!(WorkItem, work_item.id)

    case placed(work_item) do
      {:ok, _version, stage} -> missing(outputs(work_item, stage, Artifacts.list(work_item)))
      :not_placed -> []
    end
  end

  defp missing(outputs), do: for(%{required: true, check: :missing, type: t} <- outputs, do: t)

  # A stage with no workflow is approved only once every required output exists (§ 4).
  defp outputs_exist(work_item, stage) do
    with true <- Runner.people?(stage),
         [_one | _more] = types <- missing(outputs(work_item, stage, Artifacts.list(work_item))) do
      {:error, {:outputs_missing, types}}
    else
      _none -> :ok
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
        version: chosen && version_map(chosen, approvals_by_version(work_item))
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

  # A stage that waits for a workflow shows why; any other with no escalation, the gaps
  # of the failed checks that started its round. An escalation has its points instead.
  defp shown_gaps(nil, %WorkItem{stage_state: :waiting_workflow} = work_item, stage, artifacts) do
    workspace = Repo.get!(Workspace, work_item.workspace_id)

    case {waiting_workflow(work_item, stage), Processes.declared_snapshot(workspace)} do
      {workflow, %{read_at: read_at}} when is_binary(workflow) ->
        case Sources.chosen(workspace) do
          %{choice: :qory} -> not_in_qory(stage["name"], workflow)
          _repository -> not_listed(stage["name"], workflow, workspace.name, read_at)
        end

      _none ->
        gaps(nil, work_item, stage, artifacts)
    end
  end

  defp shown_gaps(escalation, work_item, stage, artifacts),
    do: gaps(escalation, work_item, stage, artifacts)

  # not_listed/4 is why a stage waits for a workflow its harness did not list.
  @doc false
  @spec not_listed(String.t(), String.t(), String.t(), DateTime.t()) :: String.t()
  def not_listed(stage, workflow, workspace, %DateTime{} = read_at) do
    time = Calendar.strftime(read_at, "%Y-%m-%d %H:%M UTC")

    "#{stage} uses #{workflow}, which #{workspace}'s harness did not list at #{time}. " <>
      "Check again, or choose another workflow for #{stage}."
  end

  # not_in_qory/2 is why a stage waits for a workflow on the Qory harness, which is never
  # read: its workflows are fixed (`Apiary.Processes.qory_workflows/1`).
  @doc false
  @spec not_in_qory(String.t(), String.t()) :: String.t()
  def not_in_qory(stage, workflow) do
    "Choose another workflow for #{stage} in Workspace settings › Workflows. " <>
      "To keep #{workflow}, change the harness in Workspace settings › Harness to one " <>
      "that lists it under workflows. #{stage} uses #{workflow}, which the Qory harness " <>
      "does not list."
  end

  defp gaps(%Escalation{}, _work_item, _stage, _artifacts), do: nil

  # With no escalation, the failed checks that started the round, unless the stage made
  # a verdict after them.
  defp gaps(nil, work_item, stage, artifacts) do
    check =
      Repo.one(
        from c in Check,
          where: c.work_item_id == ^work_item.id and c.stage_id == ^stage["id"],
          where: c.round == ^(work_item.stage_round || 0),
          order_by: [desc: c.inserted_at],
          limit: 1
      )

    verdict = newest_made_in(artifacts, "verdict", stage["id"])

    if check &&
         (is_nil(verdict) or DateTime.compare(check.inserted_at, verdict.inserted_at) == :gt),
       do: check.gaps
  end

  defp waiting_workflow(%WorkItem{stage_state: :waiting_workflow} = work_item, stage) do
    workspace = Repo.get!(Workspace, work_item.workspace_id)

    declarations =
      Map.new(Runner.workflows(stage), &{&1, Processes.workflow_declaration(workspace, &1)})

    workspace |> undeclared(declarations) |> List.first()
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
        # Counted in code points, as the database's `char_length` counts them.
        if String.valid?(trimmed) and length(String.codepoints(trimmed)) <= @max_note,
          do: {:ok, trimmed},
          else: {:error, {:invalid, :note}}
    end
  end

  defp note(_note), do: {:error, {:invalid, :note}}

  defp audit(scope, work_item, change, details) do
    Audit.record(Repo, scope, @action, work_item, %{details: Map.put(details, "change", change)})
  end

  defp told(%WorkItem{workspace_id: workspace_id, public_id: public_id}),
    do: [{:work_item, workspace_id, public_id}]

  # A hand-over inside a caller's transaction: the caller tells the work item changed once
  # it commits (`{:work_items_changed, ids}`), and this tells its stage changed, before the
  # commit, which a reader of the stage may see before the change.
  defp tell_now(%WorkItem{public_id: public_id}), do: tell_stage(public_id)

  # tell_stage/1 tells the work item `public_id` that its stage changed, on its topic.
  @doc false
  @spec tell_stage(String.t()) :: :ok | {:error, term}
  def tell_stage(public_id) when is_binary(public_id),
    do: Phoenix.PubSub.broadcast(Apiary.PubSub, topic(public_id), {:stage_changed, public_id})

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
