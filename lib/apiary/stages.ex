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
  #   * `confirmed/3`, from `Apiary.WorkItems.confirm/4`: a confirmation of Explore's
  #     proposal approves Explore's gate.
  #
  # ## A gate `none`
  #
  # A gate `none` records the approval of the stage's newest outputs, then the work item
  # enters the next stage (vault 0252), so a later stage reads those versions as its
  # inputs. The approval has no member and is `automatic` when the stage passed its gate;
  # it has the member who accepted the escalation that ended the stage otherwise. It
  # writes no entry in the audit trail: no person acted, or the accept wrote its entry.
  #
  # ## A person's change to an approved output
  #
  # A run of a later stage stores a new version of an approved output (vault 0261, 624
  # (a)). The version links to a person's note, its `decision` (`Apiary.Stages.Notes`),
  # which contains the change the person asked for. Every later
  # run reads that version in place of the approved one (`read_version/6`), and the next
  # approval by a person at a gate lists it (`approve/4`). A gate `none` lists no version
  # with a `decision`.
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
  # A stage waits at its gate while a required output is missing (`missing_outputs/1`);
  # `approve/4` returns `{:error, {:outputs_missing, types}}` for a stage with no
  # workflow, and `{:error, {:outputs_not_written, types}}` for a stage that runs one, or
  # `{:error, {:outputs_not_written, types, to}}` where Request changes at its gate
  # returns the work item to the stage whose name is `to` (`Runner.gate_return/2`).
  # Accept as it is that would take the stage to its gate is refused with `:invalid` while
  # one is missing (`resolve_escalation/5`).
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
  # The most bytes a session's result takes, encoded (`session_answer_limit/0`).
  @session_answer_bytes 1_048_576

  alias Apiary.{
    Access,
    Audit,
    Dispatches,
    Features,
    MachineTypes,
    ModelChoices,
    Processes,
    PublicId,
    Repo
  }

  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.Qory
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Cancel, Run, SessionRecord}
  alias Apiary.Stacks.Sources
  alias Apiary.Stages.{Approvers, Artifacts, Check, Escalation, GateDecision, Notes, Points}
  alias Apiary.Stages.{Runner, Session, Skip}
  alias Apiary.Stages.StopCause
  alias Apiary.WorkItems
  alias Apiary.WorkItems.{Explore, Moves, WorkItem}

  # The runs a workflow outside a loop may have in one round of its entry: its first,
  # and one after each set of answers, as today's Explore has in one take in.
  @question_runs 3
  # The types of a stage's run that a return lists as inputs (`returned_inputs/4`).
  @returned_types ["verdict", "verification"]
  @action :"gate.approve"
  @max_note 4000

  @typedoc "A resolution of an escalation."
  @type resolution ::
          :accept | :another_round | {:move_back, String.t()} | {:switch, String.t()} | :close

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
          | {:outputs_not_written, [String.t()]}
          | {:outputs_not_written, [String.t()], String.t()}
          | {:track_not_offered, String.t()}
          | {:track_not_offered, String.t(), String.t()}
          | {:already_on, String.t()}
          | :store_unavailable
          | {:invalid, :note}
          | :note_missing
          | term

  @typedoc """
  The stage the person acted on, as their page showed it: `expect_stage: stage_id`,
  required. An action on a work item that is no longer in that stage, or that names
  none, changes nothing and returns `{:error, :stage_changed}`. `track` is the id of the
  track an approval chooses (`approve/4`, `confirmed/3`); nil, or no `track`, for the
  default.
  """
  @type expect :: [expect_stage: String.t(), track: String.t() | nil]

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
  # round from where the stage's sequence runs again (`Apiary.Stages.Runner.step/4`). In a
  # stage with the condition `{feedback: new}`, another round while a member's feedback is
  # unhandled, and answers that resolve an open escalation or come with a comment or a
  # reply, start the stage again at its first entry (`Runner.feedback_entry?/3`).
  # `{:ok, run}`; `{:ok, nil}` when such feedback starts the stage again and the stage
  # waits for a workflow, so the member's feedback is kept; `{:error, :not_waiting}` when
  # any other round waits for a workflow; `:not_placed` for a work item the runner did not
  # place.
  @doc false
  @spec next_run(Ecto.UUID.t(), pos_integer) ::
          {:ok, DispatchRun.t() | nil} | {:error, :not_waiting} | :not_placed
  def next_run(id, take_in) when is_binary(id) and is_integer(take_in) do
    in_transaction!()
    work_item = %{lock!(id) | take_in: take_in}

    with {:ok, version, stage} <- placed(work_item) do
      {event, escalation} = next_event(work_item)
      if escalation, do: :ok = resolve!(escalation, :another_round, nil, nil)
      answer = %{escalation_answer: event == :answered and not is_nil(escalation)}
      {work_item, run} = apply_event(work_item, version, stage, event, nil, answer)
      tell_now(work_item)

      cond do
        run ->
          {:ok, run}

        work_item.stage_state == :waiting_workflow and
            Runner.feedback_entry?(
              stage,
              event,
              Map.merge(facts(work_item, version, stage), answer)
            ) ->
          {:ok, nil}

        true ->
          {:error, :not_waiting}
      end
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

  # The states a run reports for a session of a shared run that ended
  # (`next_session/2`). A session that paused sends no report.
  @session_states ~w(succeeded failed cancelled)

  # shared_workflows/1 is the workflows of the stage of `run`, a run of the queue, where
  # the stage has `shared_run: true` and the run is no run of Explore (`shared_stage/1`):
  # each workflow of its workflow entries once, those in a loop's body included, in the
  # sequence's order. Empty for any other run. The claim reads the time limit of each
  # (`Apiary.Dispatches.RunSettings.hold/1`).
  @doc false
  @spec shared_workflows(DispatchRun.t()) :: [String.t()]
  def shared_workflows(%DispatchRun{} = run) do
    case shared_stage(run) do
      nil -> []
      stage -> stage |> workflow_entries() |> Enum.map(&elem(&1, 1)["workflow"]) |> Enum.uniq()
    end
  end

  # session_flags/2 is what the documents of `run`, a run of the queue of a stage, have of
  # its stage and its entry (`Apiary.Dispatches.Handover`), for the access level the claim
  # computed for it (`level`, `Apiary.Runs.RunCredentials.run_access/1`): `shared_run`,
  # true where the stage has `shared_run: true` and the run is no run of Explore, the rule
  # that `next_session/2` takes reports by; and `full_suite` (`full_suite?/4`). Both false
  # for a run the stage runner did not queue.
  @doc false
  @spec session_flags(DispatchRun.t(), :read | :write_no_push | :write) :: %{
          shared_run: boolean,
          full_suite: boolean
        }
  def session_flags(
        %DispatchRun{stage_id: stage_id, process_version_id: version_id, stage_entry: entry} =
          run,
        level
      )
      when is_binary(stage_id) and is_binary(version_id) and is_integer(entry) do
    case Processes.stage(Processes.get_version!(version_id), stage_id) do
      nil ->
        %{shared_run: false, full_suite: false}

      stage ->
        %{
          shared_run: shared_stage(run) != nil,
          full_suite: full_suite?(run, Enum.at(stage["sequence"] || [], entry), nil, level)
        }
    end
  end

  def session_flags(%DispatchRun{}, _level), do: %{shared_run: false, full_suite: false}

  # claim_sessions!/3 keeps, at the claim of `run`, a run of the queue of a stage with
  # `shared_run: true` (`shared_stage/1`), what its later sessions read, inside the
  # caller's transaction, which holds the run and wrote its run record
  # (`Apiary.Dispatches.Handover`):
  #
  #   * on its run record, `session_settings` (`Apiary.Runs.Run`): for each workflow entry
  #     of the stage, those in a loop's body included, by its place, its `workflow`, its
  #     `time_limit_minutes` (the workflow's minutes in `limits`, the time limits as the
  #     claim read them, `Apiary.Dispatches.RunSettings.hold/1`, else read now; none with
  #     `factory` off), `full_suite` (`full_suite?/4`, with the run's access level, which
  #     every entry of the stage shares), and `model_choice`, the workflow's runtime and
  #     model in `models` as the claim formed them
  #     (`Apiary.Dispatches.RunSettings.build/2`, `sessions`), present for every entry of
  #     a claimed run, and `model_provider_credential_name`, the key the session starts
  #     on, for a session on a provider other than the default model provider credential's;
  #     without it, the session joins the group of the run's default model provider
  #     credential.
  #     `next_session/2` reads these, so a change to the time limits or the model choices
  #     after the claim changes nothing for the run;
  #   * its first session (`Apiary.Stages.Session`), sequence 1, at the run's position,
  #     with the run's workflow. The sessions of an earlier claim of the run that no
  #     report reached are replaced, as a run whose lease lapsed is claimed again.
  #
  # Nothing for any other run.
  @doc false
  @spec claim_sessions!(
          DispatchRun.t(),
          %{optional(String.t()) => pos_integer},
          %{optional(String.t()) => %{String.t() => map | String.t()}}
        ) :: :ok
  def claim_sessions!(%DispatchRun{} = run, limits, models \\ %{})
      when is_map(limits) and is_map(models) do
    case shared_stage(run) do
      nil ->
        :ok

      stage ->
        level = Apiary.Runs.RunCredentials.run_access(run)

        settings =
          Map.new(workflow_entries(stage), fn {place, entry, loop_entry} ->
            workflow = entry["workflow"]

            minutes =
              Map.get_lazy(limits, workflow, fn ->
                Apiary.Dispatches.RunSettings.time_limit_minutes(run, workflow)
              end)

            {place,
             Map.merge(
               %{
                 "workflow" => workflow,
                 "time_limit_minutes" => minutes,
                 "full_suite" => full_suite?(run, entry, loop_entry, level)
               },
               Map.take(Map.get(models, workflow, %{}), [
                 "model_choice",
                 "model_provider_credential_name"
               ])
             )}
          end)

        {1, _rows} =
          Repo.update_all(from(r in Run, where: r.dispatch_run_id == ^run.id),
            set: [session_settings: settings]
          )

        {_count, _rows} =
          Repo.delete_all(
            from s in Session,
              where: s.dispatch_run_id == ^run.id and is_nil(s.forager_session),
              where: is_nil(s.response)
          )

        insert_session!(
          run,
          1,
          %{
            workflow: run.workflow,
            entry: run.stage_entry,
            loop_entry: run.loop_entry,
            round: run.round
          },
          on_conflict: :nothing,
          conflict_target: [:dispatch_run_id, :sequence]
        )

        :ok
    end
  end

  # The workflow entries of `stage`, those in a loop's body included, in the sequence's
  # order: `{place, entry, loop_entry}`, `place` the key of `session_settings`
  # (`session_place/2`) and `loop_entry` the entry's index in its loop's body, nil outside
  # a loop.
  defp workflow_entries(stage) do
    (stage["sequence"] || [])
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"loop" => %{"body" => body}}, i} ->
        for {entry, j} <- Enum.with_index(body), do: {session_place(i, j), entry, j}

      {entry, i} ->
        [{session_place(i, nil), entry, nil}]
    end)
  end

  defp session_place(entry, nil), do: Integer.to_string(entry)
  defp session_place(entry, loop_entry), do: "#{entry}.#{loop_entry}"

  # full_suite?/4: whether a session of `entry`, a workflow entry, or a loop entry for a run
  # placed at a loop, of the run of the queue `run` with the access level `level`, runs the
  # full suite after it: for a run with `write` access that is no run of Explore, an entry
  # of a loop's body (`loop_entry` an index), a loop, or an entry with
  # `first_attempt: true`. A run that reads or does not push runs none.
  defp full_suite?(%DispatchRun{explore: true}, _entry, _loop_entry, _level), do: false
  defp full_suite?(_run, _entry, _loop_entry, level) when level != :write, do: false
  defp full_suite?(_run, _entry, loop_entry, _level) when is_integer(loop_entry), do: true
  defp full_suite?(_run, %{"loop" => _loop}, nil, _level), do: true
  defp full_suite?(_run, %{"first_attempt" => true}, nil, _level), do: true
  defp full_suite?(_run, _entry, nil, _level), do: false

  # shared_access/1 checks, at the claim of `run`, a run of the queue, that the workflow
  # entries of its stage, where the stage has `shared_run: true`, run with one access
  # level, with the levels the workflows declare in the workspace's harness now
  # (`Apiary.Processes.declared_access/1`, `Apiary.Processes.shared_access/2`): an update
  # from the harness can change a level after the process was saved. `:ok` for any other
  # run; `{:error, detail}` with the stage's name for a run whose entries differ, which
  # the claim ends `shared_access_differs` (`Apiary.Dispatches.Handover`).
  @doc false
  @spec shared_access(DispatchRun.t()) ::
          :ok
          | {:error,
             %{
               stage: String.t(),
               detail: :access | {:access, String.t(), String.t(), String.t()}
             }}
  def shared_access(%DispatchRun{} = run) do
    with %{} = stage <- shared_stage(run),
         workspace = Repo.get!(Workspace, run.workspace_id),
         {:error, detail} <- Processes.shared_access(stage, Processes.declared_access(workspace)) do
      {:error, %{stage: stage["name"], detail: detail}}
    else
      _same -> :ok
    end
  end

  # shared_models/1 checks, at the claim of `run`, a run of the queue, that the model
  # choices of the workflows of its stage, where the stage has `shared_run: true`, fit the
  # one run (`Apiary.Processes.shared_models/3`), with the choices resolved at the run's
  # target as the claim resolves them (`Apiary.ModelChoices.shared_models/3`): a changed
  # default provider, a cleared model choice or a change of the harness can break them
  # after the save. The providers the run can start on are those of the stage's first
  # workflow's choice, or, for a run that continues a paused run, the provider of the
  # session that paused (`Apiary.Runs.Run.session_provider_ids/2`). `:ok` for any other
  # run; `{:error, %{stage: name, detail: detail}}` for a run whose choices do not fit,
  # which the claim ends `too_many_providers`, `model_choice_missing` or
  # `session_key_missing` (`Apiary.Dispatches.Handover`), and which the lines of such a
  # run read again.
  @doc false
  @spec shared_models(DispatchRun.t()) ::
          :ok
          | {:error,
             %{
               stage: String.t(),
               detail:
                 {:too_many_providers, pos_integer, [String.t()]}
                 | {:model_choice_missing, String.t(), String.t(), String.t()}
                 | {:session_key_missing, :machine, String.t()}
                 | {:session_key_missing, :no_key, String.t(), String.t()}
                 | {:session_key_missing, :other_api, String.t(), String.t(), String.t(),
                    String.t()}
             }}
  def shared_models(%DispatchRun{} = run) do
    with %{} = stage <- shared_stage(run),
         workspace = Repo.get!(Workspace, run.workspace_id),
         target = Apiary.Dispatches.RunSettings.target_of(run),
         start_ids = start_provider_ids(run),
         models =
           ModelChoices.shared_models(workspace, target, shared_workflows(run), start_ids || []),
         {:error, detail} <- Processes.shared_models(stage, models, start_ids) do
      {:error, %{stage: stage["name"], detail: detail}}
    else
      _fits -> :ok
    end
  end

  # The providers a continuation starts on: those of the session that paused in the run
  # it continues; nil for a run that continues none.
  defp start_provider_ids(%DispatchRun{continues_id: id}) when is_binary(id) do
    case Repo.one(from r in Run, where: r.dispatch_run_id == ^id, limit: 1) do
      %Run{} = paused -> Run.session_provider_ids(paused, paused.paused_session)
      nil -> nil
    end
  end

  defp start_provider_ids(_run), do: nil

  # The stage of `run`, a run of the queue, where the stage has `shared_run: true` and the
  # run is no run of Explore; nil for any other run.
  defp shared_stage(%DispatchRun{
         step: "explore",
         work_item_id: work_item_id,
         stage_id: stage_id,
         process_version_id: version_id,
         explore: explore
       })
       when is_binary(work_item_id) and is_binary(stage_id) and is_binary(version_id) and
              explore != true do
    stage = Processes.stage(Processes.get_version!(version_id), stage_id)
    if stage && Processes.shared_run?(stage), do: stage
  end

  defp shared_stage(%DispatchRun{}), do: nil

  # next_session/2 steps the stage runner on the end of a session of `run`, a run of the
  # queue (or its id) of a stage with `shared_run: true` (`Apiary.Processes.shared_run?/1`),
  # whose entries run as sessions of that one run, and records the session
  # (`Apiary.Stages.Session`). `report` is the session's end as the run reports it:
  # `session`, the run's number for the session that ended, and `state` (`succeeded`,
  # `failed` or `cancelled`) and `reason`, nil for none.
  #
  # The step reads the session's end as the end of a run of today is read: the open
  # questions of the run's take in, else the newest `verdict` version that the run stored
  # after the previous step, else, for `failed` or `cancelled`, a stopped run with the
  # cause "The run ended without a result.". A session with none of these is a run
  # with no verdict, and the runner steps as for a run of today that ended with no
  # verdict: in a loop the ring goes on, so `implement-changes` with no verdict runs
  # `review-changes`; outside a loop the stage escalates `run_stopped`. A verdict the run
  # stored before the previous step does not count again.
  #
  # The result is the runner's outcome: `{:session, next}` where it queues a workflow of
  # the same stage, which runs as the run's next session; `:end` where it queues none (an
  # escalation, open questions, the gate, or the next stage, whose run is queued through
  # today's dispatch). `next` has `session`, Qory Apiary's number for it in the run,
  # `workflow`, `time_limit_minutes` and `full_suite` (the settings of its entry as the
  # claim kept them, `claim_sessions!/3`), `inputs` (the run's inputs,
  # `Apiary.Dispatches.Inputs.explore/4`), and `model_choice` and
  # `model_provider_credential_name`, the runtime and model of the entry's workflow and
  # the credential the session joins with, as the claim kept them (`claim_sessions!/3`);
  # each nil where the claim kept none. With no `model_provider_credential_name`, the
  # session joins with the group of the run's default model provider credential.
  #
  # The step is recorded with its result, and a repeat for the same `session` returns
  # that result and steps nothing. Errors, with nothing written:
  # `{:error, :not_found}` for an unknown run, a run of Explore, a run of a stage
  # without `shared_run`, and a run that no claim of a shared stage registered
  # (`claim_sessions!/3`); `{:error, :invalid_request}` for a report of another form;
  # `{:error, :run_ended}` for a run that ended, that the stage no longer runs, whose work
  # item is placed in another process version whose stage is gone or has other entries
  # than the run's, whose next entry has no settings the claim kept, or whose last step
  # returned `:end`;
  # `{:error, :run_cancelled}` for a run that a member cancelled;
  # `{:error, :session_mismatch}` for a `session` lower than the newest the run reported;
  # `{:error, :unavailable}` when the store cannot read the verdict's or the questions'
  # file; and `{:error, :ticket_gone}` or `{:error, :inputs_invalid}` for inputs that
  # cannot be formed (`Apiary.Dispatches.Inputs.explore/4`), or that do not fit the
  # result's 1 MiB with every comment left out (`session_response/5`).
  @doc false
  @spec next_session(DispatchRun.t() | Ecto.UUID.t(), map) ::
          {:session, map}
          | :end
          | {:error,
             :not_found
             | :invalid_request
             | :run_ended
             | :run_cancelled
             | :session_mismatch
             | :unavailable
             | :ticket_gone
             | :inputs_invalid}
  def next_session(%DispatchRun{id: id}, report), do: next_session(id, report)

  def next_session(id, %{session: number, state: state} = report)
      when is_binary(id) and is_integer(number) and number >= 1 and state in @session_states do
    reason = Map.get(report, :reason)

    if is_nil(reason) or is_binary(reason) do
      case Repo.transact(fn -> session_step(id, number, state, reason) end) do
        {:ok, response} ->
          Dispatches.broadcast(Map.get(response, :told, []))
          response.result

        {:error, _reason} = refused ->
          refused
      end
    else
      {:error, :invalid_request}
    end
  rescue
    _unreadable in [Apiary.Stages.VerdictUnreadable, Apiary.Stages.QuestionsUnreadable] ->
      {:error, :unavailable}
  end

  def next_session(_run, _report), do: {:error, :invalid_request}

  defp session_step(id, number, state, reason) do
    :ok = MachineTypes.hold()

    with {:ok, run} <- shared_run(id),
         work_item = lock!(run.work_item_id),
         run = Repo.get!(DispatchRun, id),
         :ok <- run_live(run),
         {:ok, settings} <- session_settings(run),
         sessions = sessions(run),
         {:step, pending} <- reported(sessions, number),
         {:ok, version, stage} <- session_stage(work_item, run),
         {:ok, pending} <- pending_session(pending, work_item) do
      previous = sessions |> Enum.map(& &1.verdict_number) |> Enum.reject(&is_nil/1)
      {result, seen} = session_result(work_item, run, state, Enum.max(previous, fn -> nil end))
      facts = facts(work_item, version, stage)
      outcome = Runner.step(stage, position(work_item), {:run, result}, facts)

      {work_item, next} =
        apply_outcome(work_item, version, stage, outcome, run.id, nil, :session)

      with {:ok, stored} <- session_response(next, work_item, run, settings, pending) do
        pending
        |> Ecto.Changeset.change(
          forager_session: number,
          state: state,
          reason: reason,
          verdict_number: seen,
          response: stored
        )
        |> Repo.update!()

        if next_session = session_spec(next),
          do: insert_session!(run, pending.sequence + 1, next_session)

        {:ok, %{result: response(stored), told: told(work_item)}}
      end
    else
      {:stored, stored} -> {:ok, %{result: response(stored)}}
      {:error, _reason} = refused -> refused
    end
  end

  # The run of the queue `id`, once it is a run of a stage with `shared_run: true` that is
  # no run of Explore (`shared_stage/1`).
  defp shared_run(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %DispatchRun{} = run <- Repo.get(DispatchRun, id),
         %{} <- shared_stage(run) do
      {:ok, run}
    else
      _other -> {:error, :not_found}
    end
  end

  # The settings of the entries of the run's stage, as its claim kept them on its run
  # record (`claim_sessions!/3`); `:not_found` for a run no such claim registered.
  defp session_settings(%DispatchRun{id: id}) do
    case Repo.one(from r in Run, where: r.dispatch_run_id == ^id, select: r.session_settings) do
      %{} = settings -> {:ok, settings}
      nil -> {:error, :not_found}
    end
  end

  defp run_live(%DispatchRun{state: :ended}), do: {:error, :run_ended}

  defp run_live(run),
    do: if(Cancel.dispatch_run_cancelled?(run), do: {:error, :run_cancelled}, else: :ok)

  defp sessions(%DispatchRun{id: id}),
    do: Repo.all(from s in Session, where: s.dispatch_run_id == ^id, order_by: s.sequence)

  # newest_session/1 is the newest session of `run`, a run of the queue of a stage with
  # `shared_run: true` (`Apiary.Stages.Session`): the session the run is in, or ended
  # last; nil for a run with none. Its `workflow`, `stage_entry`, `loop_entry` and `round`
  # are the run's place now, as the run's columns keep only its first session's.
  @doc false
  @spec newest_session(DispatchRun.t()) :: Session.t() | nil
  def newest_session(%DispatchRun{id: id}) when is_binary(id) do
    Repo.one(
      from s in Session,
        where: s.dispatch_run_id == ^id,
        order_by: [desc: s.sequence],
        limit: 1
    )
  end

  def newest_session(%DispatchRun{}), do: nil

  # session_credential/2 is the `model_provider_credential_name` that the claim of `run`,
  # a registered run of a stage with `shared_run: true`, kept for its session number
  # `session` (`claim_sessions!/3`): the key whose group that session starts on. The
  # session is the one a report numbered `session` ended, else the open session
  # (`open_session/1`), the one a run that paused was in. Nil for a session of the default
  # model provider credential's group, and for a run with no session settings. `sessions`,
  # the run's sessions as `session_rows_by_dispatch_run/1` reads them, is read here where
  # it is nil.
  @doc false
  @spec session_credential(map, pos_integer, [Session.t()] | nil) :: String.t() | nil
  def session_credential(run, session, sessions \\ nil)

  def session_credential(
        %{dispatch_run_id: dispatch_run_id, session_settings: %{} = settings},
        session,
        sessions
      )
      when is_binary(dispatch_run_id) and is_integer(session) do
    sessions =
      sessions || Map.get(session_rows_by_dispatch_run([dispatch_run_id]), dispatch_run_id, [])

    case Enum.find(sessions, &(&1.forager_session == session)) ||
           Enum.find(sessions, &is_nil(&1.forager_session)) do
      %Session{stage_entry: entry, loop_entry: loop_entry} when is_integer(entry) ->
        get_in(settings, [session_place(entry, loop_entry), "model_provider_credential_name"])

      _none ->
        nil
    end
  end

  def session_credential(_run, _session, _sessions), do: nil

  # session_rows_by_dispatch_run/1 is the stored `Session` rows of the runs of the queue
  # `dispatch_run_ids`, by run of the queue, each run's newest first: one read for every
  # run. Unlike `run_sessions/1`, which a page reads by public id, it keeps
  # `forager_session` and reads no session records or verdicts.
  @doc false
  @spec session_rows_by_dispatch_run([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Session.t()]}
  def session_rows_by_dispatch_run([]), do: %{}

  def session_rows_by_dispatch_run(dispatch_run_ids) when is_list(dispatch_run_ids) do
    Repo.all(
      from s in Session,
        where: s.dispatch_run_id in ^Enum.uniq(dispatch_run_ids),
        order_by: [asc: s.dispatch_run_id, desc: s.sequence]
    )
    |> Enum.group_by(& &1.dispatch_run_id)
  end

  # open_session/1 is the newest session of `run` that no report ended
  # (`newest_session/1`): the session a run that paused was in; nil for none.
  @doc false
  @spec open_session(DispatchRun.t()) :: Session.t() | nil
  def open_session(%DispatchRun{id: id}) when is_binary(id) do
    Repo.one(
      from s in Session,
        where: s.dispatch_run_id == ^id and is_nil(s.forager_session),
        order_by: [desc: s.sequence],
        limit: 1
    )
  end

  def open_session(%DispatchRun{}), do: nil

  # ended_after_session/1 is the number of the session after which `run` ended, for a run
  # that ran a session: one whose dispatch was handed over or whose run record registered
  # a start, and that has a session (`newest_session/1`). Nil for any other run, such as
  # one a claim ended, whose sessions an earlier claim that lapsed kept.
  @doc false
  @spec ended_after_session(DispatchRun.t()) :: pos_integer | nil
  def ended_after_session(%DispatchRun{id: id} = run) when is_binary(id) do
    ran? =
      Repo.exists?(
        from d in Apiary.Dispatches.Dispatch,
          where: d.dispatch_run_id == ^id and not is_nil(d.handed_over_at)
      ) or
        Repo.exists?(from r in Run, where: r.dispatch_run_id == ^id and not is_nil(r.started_at))

    if ran? do
      case newest_session(run) do
        %Session{sequence: sequence} -> sequence
        nil -> nil
      end
    end
  end

  def ended_after_session(%DispatchRun{}), do: nil

  # What a report of the session `number` does: a repeat of the newest session the run
  # reported returns that step's result; an older one is a mismatch; a newer one steps on
  # the session the run is in, the first with no report recorded yet. A run with no
  # session recorded is one that no claim of a shared stage registered.
  defp reported(sessions, number) do
    newest =
      sessions
      |> Enum.filter(& &1.forager_session)
      |> Enum.max_by(& &1.forager_session, fn -> nil end)

    cond do
      newest && number == newest.forager_session ->
        {:stored, newest.response}

      newest && number < newest.forager_session ->
        {:error, :session_mismatch}

      sessions == [] ->
        {:error, :not_found}

      true ->
        case Enum.find(sessions, &is_nil(&1.forager_session)) do
          nil -> {:error, :run_ended}
          pending -> {:step, pending}
        end
    end
  end

  # The work item's stage, while the run is the newest of that stage, the stage runs, and
  # the stage has the entries it had in the process version the run was claimed for: the
  # settings the claim kept are that version's (`claim_sessions!/3`). A work item moved to
  # another version whose stage is gone or has other entries ends the run as a stage that
  # no longer runs it does. Another version whose stage differs only in its entries'
  # machine types, such as a machine type's new key (`Apiary.Processes.rekey_machine/3`),
  # changes nothing for the run, which runs on the machine its claim took.
  defp session_stage(work_item, run) do
    with true <- current_run?(work_item, run),
         {:ok, version, stage} = placed <- placed(work_item),
         true <- same_entries?(version, stage, run) do
      placed
    else
      _other -> {:error, :run_ended}
    end
  end

  defp same_entries?(%{id: id}, _stage, %DispatchRun{process_version_id: id}), do: true
  defp same_entries?(_version, _stage, %DispatchRun{process_version_id: nil}), do: true

  defp same_entries?(_version, stage, %DispatchRun{} = run) do
    case Processes.stage(Processes.get_version!(run.process_version_id), run.stage_id) do
      nil -> false
      claimed -> entries(claimed) == entries(stage)
    end
  end

  # The entries of `stage`'s sequence, those in a loop's body included, without their
  # machine types.
  defp entries(stage), do: Enum.map(stage["sequence"] || [], &without_machine/1)

  defp without_machine(%{"loop" => %{"body" => body} = loop} = entry) when is_list(body),
    do: %{entry | "loop" => %{loop | "body" => Enum.map(body, &without_machine/1)}}

  defp without_machine(%{} = entry), do: Map.delete(entry, "machine")
  defp without_machine(entry), do: entry

  # The session the report ends, recorded by the claim or by the step before, while the
  # work item is at its position.
  defp pending_session(%Session{} = pending, work_item) do
    if position(work_item) ==
         %{entry: pending.stage_entry, loop_entry: pending.loop_entry, round: pending.round},
       do: {:ok, pending},
       else: {:error, :run_ended}
  end

  defp insert_session!(run, sequence, spec, opts \\ []) do
    %Session{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      dispatch_run_id: run.id,
      sequence: sequence,
      stage_entry: spec.entry,
      loop_entry: spec.loop_entry,
      round: spec.round,
      workflow: spec.workflow
    }
    |> Repo.insert!(opts)
  end

  # The result of the session, as `reported_result/2` reads a run's end, with the number of the
  # run's newest verdict version: a verdict counts only when it is newer than `previous`,
  # the number the previous step saw.
  defp session_result(work_item, run, state, previous) do
    open = open_questions(work_item, run)
    {verdict, seen} = session_verdict(run, previous)

    result =
      cond do
        open != [] ->
          {:questions, question_texts(open), escalate_points(verdict, open)}

        verdict ->
          open_points(verdict, open)

        state in ["failed", "cancelled"] ->
          {:stopped, Points.run_stopped(StopCause.no_result(), nil)}

        true ->
          {:verdict, nil, nil}
      end

    {result, seen}
  end

  defp session_verdict(run, previous) do
    case Artifacts.newest_of_run(run, "verdict", "main") do
      nil ->
        {nil, previous}

      %{number: number} when is_integer(previous) and number <= previous ->
        {nil, previous}

      version ->
        case Artifacts.stored_json(version) do
          {:ok, document} ->
            document = document || %{}
            {{:verdict, verdict(document["verdict"]), points(document["points"])}, version.number}

          {:error, :store_unavailable} ->
            raise Apiary.Stages.VerdictUnreadable
        end
    end
  end

  defp session_spec({:session, spec}), do: spec
  defp session_spec(_other), do: nil

  # The step's result as a session records it, with string keys: the next session, with
  # the settings of its entry as the claim kept them (`settings`), or the end of the run.
  # The session's inputs take the bytes of `session_answer_limit/0` that the rest of the
  # result leaves, with the oldest comments left out first (`Apiary.Dispatches.Inputs`);
  # inputs that cannot fit with every comment left out are `{:error, :inputs_invalid}`.
  defp session_response({:session, spec}, work_item, run, settings, pending) do
    with {:ok, entry} <- entry_settings(settings, spec),
         do: session_answer(work_item, run, pending, spec, entry)
  end

  defp session_response(_end, _work_item, _run, _settings, _pending),
    do: {:ok, %{"next" => "end"}}

  # The settings the claim kept for the entry of `spec`; a place the claim kept none for,
  # as of a version the claim did not read, ends the run as a stage that no longer runs
  # it does.
  defp entry_settings(settings, spec) do
    case Map.fetch(settings, session_place(spec.entry, spec.loop_entry)) do
      {:ok, %{"time_limit_minutes" => _minutes, "full_suite" => _full_suite} = entry} ->
        {:ok, entry}

      _other ->
        {:error, :run_ended}
    end
  end

  defp session_answer(work_item, run, pending, spec, entry) do
    workspace = Repo.get!(Workspace, work_item.workspace_id)

    target =
      if work_item.target_system,
        do: %{system: work_item.target_system, path: work_item.target_path}

    stored = %{
      "next" => "session",
      "session" => pending.sequence + 1,
      "workflow" => spec.workflow,
      "model_choice" => entry["model_choice"],
      "model_provider_credential_name" => entry["model_provider_credential_name"],
      "time_limit_minutes" => entry["time_limit_minutes"],
      "full_suite" => entry["full_suite"],
      "inputs" => %{}
    }

    rest = byte_size(Jason.encode!(stored)) - byte_size("{}")

    case Apiary.Dispatches.Inputs.explore(
           work_item,
           run,
           %{domain: Apiary.Lingo.Domain.name(workspace), target: target},
           max(session_answer_limit() - rest, 1)
         ) do
      {:ok, inputs} ->
        {:ok, Map.put(stored, "inputs", inputs |> Jason.encode!() |> Jason.decode!())}

      {:error, :answer_too_large} ->
        {:error, :inputs_invalid}

      {:error, _cause} = unformed ->
        unformed
    end
  end

  # session_answer_limit/0 is the most bytes a session's result takes, encoded: 1 MiB,
  # the largest `200` the gateway passes back to the next-session request. A test sets
  # `config :apiary, Apiary.Stages, session_answer_limit: bytes` (`Application.put_env/3`,
  # in a module that is not async), to see the inputs cut.
  defp session_answer_limit do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:session_answer_limit, @session_answer_bytes)
  end

  # A recorded result as `next_session/2` returns it.
  defp response(%{"next" => "session"} = stored) do
    {:session,
     %{
       session: stored["session"],
       workflow: stored["workflow"],
       model_choice: stored["model_choice"],
       model_provider_credential_name: stored["model_provider_credential_name"],
       time_limit_minutes: stored["time_limit_minutes"],
       full_suite: stored["full_suite"],
       inputs: stored["inputs"]
     }}
  end

  defp response(%{"next" => "end"}), do: :end

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

  # limits/1 is the lowered access level of the run of the queue `run`
  # (`Apiary.Stages.Runner.limits/4`), read at its claim without a lock, with
  # the harness's declaration of its workflow as the claim reads it; nil for a run the
  # stage runner did not queue, or with the workflow model off. A stage its version does
  # not have counts as a stage with no entry.
  @doc false
  @spec limits(DispatchRun.t()) ::
          %{access: :read | :write_no_push | :write | nil} | nil
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

  # run_access/2 is the access level of the run of the queue `run` whose harness walk
  # resolved `walk`, the harness's level: with the stage entry's level (`limits/1`) the
  # lower of the two, from lowest to highest `:read`, `:write_no_push` and `:write`; the
  # walk's with no entry level. A run of a stage with no limits (`limits/1` is nil: the
  # stage's version has no entry for its workflow, or the workflow model is off) has
  # `:read`. A run the stage runner did not queue has the walk's level.
  #
  # The claim computes the level once: the run's documents and its work credential row
  # keep it (`Apiary.Dispatches.Handover`, `Apiary.Runs.RunCredentials`). A run claimed as
  # write keeps renewing write tokens after a later process version lowers its entry, and
  # a waiting run gets the level of the entry of its process version (`process_version_id`)
  # when it is claimed.
  @doc false
  @spec run_access(:read | :write_no_push | :write, DispatchRun.t()) ::
          :read | :write_no_push | :write
  def run_access(:read, %DispatchRun{}), do: :read

  def run_access(walk, %DispatchRun{stage_id: stage_id} = run) when is_binary(stage_id) do
    case limits(run) do
      nil -> :read
      %{access: entry} when entry in [:read, :write_no_push] -> lower_level(walk, entry)
      _no_level -> walk
    end
  end

  def run_access(walk, %DispatchRun{}), do: walk

  @levels [:read, :write_no_push, :write]

  defp lower_level(one, other),
    do: Enum.min_by([one, other], fn level -> Enum.find_index(@levels, &(&1 == level)) end)

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
  # person confirmed in this transaction (`Apiary.WorkItems.confirm/4`), which passes
  # the stage of the confirmed run as `expect_stage` (`confirmed_stage_id/2`), and the
  # `track` the person chose, if any. At the gate it asks `work_item.confirm`
  # (`Apiary.Access`) of the locked work item again. The approval records its track as
  # `approve/4` does.
  @doc false
  @spec confirmed(Scope.t(), WorkItem.t(), expect) :: {:ok, WorkItem.t()} | {:error, term}
  def confirmed(%Scope{} = scope, %WorkItem{id: id}, opts \\ []) do
    in_transaction!()
    work_item = lock!(id)

    with {:ok, version, stage} <- placed(work_item),
         :ok <- expected(work_item, opts),
         :at_gate <- work_item.stage_state do
      with :ok <- Access.authorize(scope, :"work_item.confirm", work_item),
           {:ok, track} <- chosen_track(work_item, stage, opts),
           {:ok, work_item} <- approve_locked(scope, work_item, version, stage, nil, false, track) do
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
          enter_locked(%{work_item | process_version_id: version.id}, version, stage, true)

        {:ok, work_item}
      end
    end)
  end

  # resume/1 starts a stage that waits for a required input or for a workflow, once the
  # input exists or the harness declares the workflow. Only tests call it.
  # A stage in any other state, or of a work item that is not `:exploring`, is left as it
  # is. `{:error, :not_placed}` for a work item the runner has not placed.
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

  # check_workflows/2 reads the workflows the workspace's harness lists now, with their
  # access levels, as the scope's person, through the harness sources
  # (`Apiary.Stacks.Sources`), stores them as
  # the workspace's snapshot, and starts the work item's stage when it waits for a
  # workflow the read found: `{:ok, work_item}`; `{:error, :still_missing}` when the
  # stage still waits; `{:error, :not_live}` for a work item that is not `:exploring`, read
  # under its lock; the read's error otherwise. It reads nothing for a person who may not
  # approve the stage's gate (`gate.approve`, asked of the work item): Access's reason.
  # `read` is the read, given only by tests.
  @doc false
  @spec check_workflows(Scope.t(), WorkItem.t(), (Scope.t(), Workspace.t() -> term)) ::
          {:ok, WorkItem.t()} | {:error, term}
  def check_workflows(%Scope{} = scope, %WorkItem{id: id}, read \\ &Sources.chosen_declared/2) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id) || {:error, :not_found},
         :ok <- Access.authorize(scope, @action, found),
         {:ok, declared} <- read.(scope, workspace) do
      :ok = Processes.record_declared(workspace, declared)
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
  # gate it confirms today's proposal first (`Apiary.WorkItems.Moves`). The gate of any
  # stage is refused while a required output is missing (`missing_outputs/1`):
  # `{:error, {:outputs_missing, types}}` for a stage with no workflow, whose people make
  # its outputs, and `{:error, {:outputs_not_written, types}}` for a stage whose runs did
  # not write them, with the name of the stage that Request changes returns the work item
  # to as a third element where it returns it (`Runner.gate_return/2`).
  #
  # The decision records a track (`chosen_track/3`): the `track` of `opts` where the gate
  # offers it, else `{:error, {:track_not_offered, track}}`; with none, the track the stage's
  # runs proposed (`proposed_track/1`) where the gate offers it, else the track the work
  # item is on (`track/1`) where the gate offers it, else the gate's first track, else none.
  # A missing track never refuses an approval.
  @doc false
  @spec approve(Scope.t(), WorkItem.t(), String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def approve(%Scope{} = scope, %WorkItem{} = work_item, note, opts \\ []) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
           :ok <- at_gate(work_item, stage),
           :ok <- outputs_exist(work_item, version, stage),
           {:ok, track} <- chosen_track(work_item, stage, opts),
           {:ok, confirmed?} <- confirm_explore(scope, work_item, stage) do
        # A confirmation already wrote the act's entry in the audit trail.
        approve_locked(scope, lock!(work_item.id), version, stage, note, not confirmed?, track)
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
  # one entry in the trail. It covers the versions `recorded_versions/4` gives, which the
  # work item page frames (`gate_frames/3`).
  defp approve_locked(scope, work_item, version, stage, note, audit?, track) do
    artifacts = Artifacts.list(work_item)
    approvals = approvals_by_version(work_item)
    covered = Enum.map(recorded_versions(stage, artifacts, approvals, true), & &1.public_id)
    details = %{"stage_id" => stage["id"], "versions" => covered}

    with {:ok, _decision} <-
           decide(scope, work_item, version, stage, :approve, covered, nil, note, track: track),
         {:ok, _entry} <-
           if(audit?, do: audit(scope, work_item, "approve", details), else: {:ok, nil}) do
      {work_item, _run} = advance(work_item, version, stage)
      {:ok, work_item}
    end
  end

  # request_changes/4 runs the stage's sequence again from its first loop, or from its
  # start, with the person's note, which may point at one artifact version of the work
  # item (`av_…`). At the gate of a stage with an entry that has a return key, the work
  # item enters that key's earlier stage at its first entry instead, and no return is
  # counted (`Apiary.Stages.Runner`). A note that is missing or blank returns
  # `{:error, :note_missing}` and changes nothing: the note is what the next run reads.
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
           :ok <- if(is_nil(note), do: {:error, :note_missing}, else: :ok),
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
        {work_item, _run} =
          apply_event(work_item, version, stage, :request_changes, nil, %{feedback_note: true})

        {:ok, work_item}
      end
    end)
  end

  # resolve_escalation/5 acts on the work item's open escalation: accept it as it is, run
  # another round with the person's note, move the work item back to an earlier stage,
  # switch it to another track of the gate that recorded its track (`{:switch, track}`,
  # `switch_tracks/1`), or close it. A work item that is offered a switch (`switch_tracks/1`
  # is not empty) is offered no accept and no move back: both are refused with `:invalid`.
  # An accept that would take the stage to its gate returns `{:error, :invalid}` too while
  # a required output of the stage is missing (`accept_needs/4`).
  @doc false
  @spec resolve_escalation(Scope.t(), WorkItem.t(), resolution, String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def resolve_escalation(%Scope{} = scope, %WorkItem{} = work_item, resolution, note, opts \\ []) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
           %Escalation{} = escalation <- escalation!(work_item, version, stage),
           :ok <- switch_only(work_item, version, stage, resolution),
           :ok <- accept_outputs(work_item, version, stage, resolution),
           {:ok, work_item} <-
             resolve(scope, work_item, version, stage, escalation, resolution, note),
           {:ok, _entry} <-
             audit(
               scope,
               work_item,
               "escalation_#{resolution_name(resolution)}",
               Map.merge(
                 %{"stage_id" => stage["id"], "cause" => Atom.to_string(escalation.cause)},
                 switched(resolution)
               )
             ) do
        {:ok, work_item}
      end
    end)
  end

  # An accept that passes a gate `none` is the approval, recorded with the member
  # (`approve_none!/4`).
  defp resolve(scope, work_item, version, stage, escalation, resolution, note)
       when resolution in [:accept, :another_round] do
    :ok = resolve!(escalation, resolution, scope, note)
    event = {resolution, escalation.cause}
    by = if resolution == :accept, do: scope && scope.user && scope.user.id
    {work_item, _run} = apply_event(work_item, version, stage, event, nil, %{}, by)
    {:ok, work_item}
  end

  # A switch: the track is recorded as a move's decision out of `stage`, to the stage after
  # the gate that recorded the work item's track, for the escalation it resolves, so
  # `track/1` reads it as it reads an approval's and the departure lists `stage`'s outputs
  # as inputs (`inputs/1`). Then that stage is entered as a stage that no person moved the
  # work item into (`forced` false): the runner passes over each stage that does not run
  # on the new track and starts the first that does.
  defp resolve(scope, work_item, version, stage, escalation, {:switch, track}, note)
       when is_binary(track) do
    with {:ok, _gate, next} <- switch_target(work_item, version, stage, track),
         :ok <- resolve!(escalation, :switch, scope, note),
         {:ok, _decision} <-
           decide(scope, work_item, version, stage, :move, [], nil, nil,
             track: track,
             to_stage_id: next["id"],
             escalation_id: escalation.id
           ) do
      {work_item, _run} = enter_locked(work_item, version, next, false)
      {:ok, work_item}
    end
  end

  defp resolve(scope, work_item, version, stage, escalation, {:move_back, stage_id}, note) do
    with {:ok, target} <- earlier(version, stage, stage_id),
         {:ok, _decision} <-
           decide(scope, work_item, version, stage, :move, [], nil, nil,
             to_stage_id: target["id"],
             escalation_id: escalation.id
           ) do
      :ok = resolve!(escalation, :move_back, scope, note)
      {work_item, _run} = enter_locked(work_item, version, target, true)
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
  defp resolution_name({:switch, _track}), do: "switch"
  defp resolution_name(resolution) when is_atom(resolution), do: Atom.to_string(resolution)

  defp switched({:switch, track}), do: %{"track" => track}
  defp switched(_resolution), do: %{}

  # A work item that is offered a switch has no accept and no move back.
  defp switch_only(work_item, version, stage, resolution)
       when resolution == :accept or
              (is_tuple(resolution) and elem(resolution, 0) == :move_back) do
    if switch_offers(work_item, version, stage), do: {:error, :invalid}, else: :ok
  end

  defp switch_only(_work_item, _version, _stage, _resolution), do: :ok

  # An accept that takes the stage to its gate passes it as it is, so it needs every
  # required output, as an approval does (`accept_needs/4`).
  defp accept_outputs(work_item, version, stage, :accept) do
    facts = facts(work_item, version, stage)

    case accept_needs(work_item, stage, facts, facts.failed_checks) do
      [] -> :ok
      _missing -> {:error, :invalid}
    end
  end

  defp accept_outputs(_work_item, _version, _stage, _resolution), do: :ok

  # A move of a person (`move/5`) resolves the open escalation as a move back, so it is
  # refused where the escalation is offered a switch, as that resolution is.
  defp no_move_on_switch(%WorkItem{stage_state: :escalated} = work_item, version, stage),
    do: switch_only(work_item, version, stage, {:move_back, nil})

  defp no_move_on_switch(_work_item, _version, _stage), do: :ok

  # The gate that recorded the work item's track, and the stage that a switch enters, the
  # stage after that gate, for `track`: `{:error, {:track_not_offered, track, gate_name}}` for
  # a track the gate does not offer, `{:error, {:already_on, track_name}}` for the one the
  # work item is on, `{:error, :invalid}` where no switch is offered.
  defp switch_target(work_item, version, stage, track) do
    case switch_offers(work_item, version, stage) do
      {gate, others} ->
        cond do
          Enum.any?(others, &(&1.id == track)) -> {:ok, gate, next_stage(version, gate)}
          track(work_item) == track -> {:error, {:already_on, track_name(version, track)}}
          true -> {:error, {:track_not_offered, track, gate["name"]}}
        end

      nil ->
        {:error, :invalid}
    end
  end

  # `{gate, tracks}`: the gate that recorded the work item's current track (`track/1`) and
  # the other tracks it offers, where the gate offers tracks, the work item is not on the
  # gate's first track, and the gate is before `stage`; nil otherwise. The gate is the stage
  # of the newest decision with a track whose gate offers the current track, not `stage`,
  # whose gate may offer none: a switch is a move out of the stage it resolves in, so its
  # decision is not at a gate that offers tracks, and the gate is the one before it.
  defp switch_offers(work_item, version, stage) do
    ids = Enum.map(version.document["stages"], & &1["id"])

    with [%{track: current} | _older] = decisions <- track_decisions(work_item),
         {gate, [%{id: first} | _] = offered} <- recording_gate(decisions, current, version),
         true <- current != first,
         gate_at when is_integer(gate_at) <- Enum.find_index(ids, &(&1 == gate["id"])),
         stage_at when is_integer(stage_at) <- Enum.find_index(ids, &(&1 == stage["id"])),
         true <- gate_at < stage_at,
         [_ | _] = others <- Enum.reject(offered, &(&1.id == current)) do
      {gate, others}
    else
      _none -> nil
    end
  end

  # The newest of `decisions` made at a stage whose gate offers `current`, with that gate's
  # tracks; nil for none. The gate is read from the process version the decision was made
  # under, as `Apiary.Processes.assign/3` may pin the work item to another version since;
  # `version`, the work item's, stands for a decision that kept none. A switch is left
  # out: it is made out of the stage it resolves in, which may have a gate that offers the
  # same tracks, and records no gate's offer.
  defp recording_gate(decisions, current, version) do
    decisions
    |> Enum.filter(&is_nil(&1.escalation_id))
    |> Enum.find_value(fn %{stage_id: stage_id, process_version_id: version_id} ->
      recorded = recorded_version(version_id, version)

      with %{} = gate <- Processes.stage(recorded, stage_id),
           [_ | _] = offered <- gate_tracks(recorded, gate),
           true <- Enum.any?(offered, &(&1.id == current)) do
        {gate, offered}
      else
        _none -> nil
      end
    end)
  end

  defp recorded_version(nil, version), do: version
  defp recorded_version(id, %{id: id} = version), do: version
  defp recorded_version(id, version), do: Repo.get(Processes.Version, id) || version

  # move/4 moves the work item to the stage `stage_id` of its version, forward past a
  # stage or back, with the person's note, and starts that stage. A move forward records the
  # track that an approval at the gate it passes would record with none chosen
  # (`moved_track/4`), on the move's gate decision, so `track/1` reads it as it reads an
  # approval's. A move resolves an open escalation of the stage as `:move_back` with no
  # note: the move's decision keeps the note, so the next run reads it once (`notes/1`).
  @doc false
  @spec move(Scope.t(), WorkItem.t(), String.t(), String.t() | nil, expect) ::
          {:ok, WorkItem.t()} | {:error, refusal}
  def move(%Scope{} = scope, %WorkItem{} = work_item, stage_id, note, opts \\ []) do
    transact(fn ->
      with {:ok, note} <- note(note),
           {:ok, work_item, version, stage} <- hold(scope, work_item, opts),
           :ok <- no_move_on_switch(work_item, version, stage),
           target when is_map(target) <-
             Processes.stage(version, stage_id) || {:error, :unknown_stage},
           {:ok, track} <- moved_track(work_item, version, stage, target),
           {:ok, _decision} <-
             decide(scope, work_item, version, stage, :move, [], nil, note,
               track: track,
               to_stage_id: target["id"]
             ),
           {:ok, _entry} <-
             audit(scope, work_item, "move", %{
               "from" => stage["id"],
               "to" => target["id"],
               "note" => note
             }) do
        :ok = close_open(work_item, :move_back, scope, nil)
        {work_item, _run} = enter_locked(work_item, version, target, true)
        {:ok, work_item}
      end
    end)
  end

  # The track a move records: forward past the gate of `stage`, the track an approval there
  # would record with none chosen (`chosen_track/3`); nil for a move back or to the same
  # stage, which passes no gate.
  defp moved_track(work_item, version, stage, target) do
    ids = Enum.map(version.document["stages"], & &1["id"])

    if Enum.find_index(ids, &(&1 == target["id"])) > Enum.find_index(ids, &(&1 == stage["id"])),
      do: chosen_track(work_item, stage, []),
      else: {:ok, nil}
  end

  ## What an act would start

  # starts/2 is the workflow of the run that `act` would queue for the work item, by the
  # runner's rules (`Runner.step/4`) on the facts read now, with nothing written:
  # `{:run, workflow}`, or `:none` where `act` queues no run, or the work item is not
  # `:exploring` or not placed. A page reads it at a click, to confirm the spend first
  # (`ApiaryWeb.SpendDialog`). It reads no access: the act checks that. `act` is one of:
  #
  #   * `:approve` - the gate approved, at the gate: the next stage entered (`approve/4`);
  #   * `:request_changes` - at the gate (`request_changes/5`), with `noted` true: with
  #     no note, Request changes fails and starts nothing;
  #   * `:accept`, `:another_round` - the open escalation resolved so
  #     (`resolve_escalation/5`);
  #   * `{:move, stage_id}` - that stage of the version entered (`move/5`, and a move
  #     back that resolves an escalation);
  #   * `{:switch, track}` - the stage after the gate that recorded the work item's
  #     track entered on `track` (`resolve_escalation/5`);
  #   * `:found` - a stage that waits for a workflow, once the harness lists it
  #     (`check_workflows/3`);
  #   * `:next_run` - the next round of the stage (`next_run/2`).
  #
  # `noted` is whether the act comes with a note or a comment that is not blank, which is
  # stored as feedback before the step (`feedback_facts/3`): the note of Request changes,
  # Run another round, a switch or a move, or the comment sent with answers (`:next_run`).
  @doc false
  @spec starts(WorkItem.t(), term, boolean) :: {:run, String.t()} | :none
  def starts(%WorkItem{id: id}, act, noted \\ false) do
    act = if noted, do: {:noted, act}, else: act

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

  # The approval covers the versions the stage's gate shows (`approve_locked/7`), which
  # each later stage then reads as its inputs of those types: the next stage, and each
  # stage that a stage passing on enters.
  defp would_start(work_item, version, stage, :approve) do
    with :ok <- at_gate(work_item, stage),
         :ok <- outputs_exist(work_item, version, stage),
         %{} = next <- next_stage(version, stage) do
      approved = approved(work_item, stage, :person, & &1)
      stepped(work_item, version, next, :enter, approved, approved)
    else
      _no_run -> :none
    end
  end

  # Request changes has a note (`request_changes/5`), which is feedback, for this stage
  # and for the stage that a return enters. With no note it starts nothing.
  defp would_start(work_item, version, stage, {:noted, :request_changes}) do
    noted = &noted(&1, %{feedback_note: true})

    if at_gate(work_item, stage) == :ok,
      do: stepped(work_item, version, stage, :request_changes, noted, noted),
      else: :none
  end

  # With a note, Run another round, a move and a switch are feedback.
  defp would_start(work_item, version, stage, {:noted, act})
       when act == :another_round or (is_tuple(act) and elem(act, 0) in [:move, :switch]),
       do: resolved_starts(work_item, version, stage, act, &noted/1)

  defp would_start(work_item, version, stage, {:noted, :next_run}),
    do: next_run_starts(work_item, version, stage, %{feedback_comment: true})

  defp would_start(work_item, version, stage, {:noted, act}),
    do: would_start(work_item, version, stage, act)

  # An accept that fails the outputs check of `resolve_escalation/5` starts nothing.
  defp would_start(work_item, version, stage, :accept) do
    case accept_outputs(work_item, version, stage, :accept) do
      :ok -> resolved_starts(work_item, version, stage, :accept, & &1)
      {:error, :invalid} -> :none
    end
  end

  defp would_start(work_item, version, stage, act)
       when act == :another_round or
              (is_tuple(act) and elem(act, 0) in [:move, :switch]),
       do: resolved_starts(work_item, version, stage, act, & &1)

  # Once the harness lists the stage's workflows.
  defp would_start(work_item, version, stage, :found) do
    found = &%{&1 | undeclared: []}

    case on_found(work_item, fn -> found.(facts(work_item, version, stage)) end) do
      :resume -> stepped(work_item, version, stage, :resume, found)
      _no_run -> :none
    end
  end

  defp would_start(work_item, version, stage, :next_run),
    do: next_run_starts(work_item, version, stage, %{})

  defp would_start(_work_item, _version, _stage, _act), do: :none

  # What Accept as it is and Run another round of the open escalation, a move and a
  # switch start, on the facts as `adjust` changes them.
  defp resolved_starts(
         %WorkItem{stage_state: :escalated} = work_item,
         version,
         stage,
         resolution,
         adjust
       )
       when resolution in [:accept, :another_round] do
    %Escalation{cause: cause} =
      open_escalation(work_item) || placed_escalation(work_item, version, stage)

    stepped(work_item, version, stage, {resolution, cause}, adjust)
  end

  defp resolved_starts(work_item, version, _stage, {:move, stage_id}, adjust)
       when is_binary(stage_id),
       do: entered(work_item, version, Processes.stage(version, stage_id), adjust)

  # A switch enters the stage after the gate that recorded the track, on the new track.
  defp resolved_starts(work_item, version, stage, {:switch, track}, adjust)
       when is_binary(track) do
    case switch_target(work_item, version, stage, track) do
      {:ok, _gate, next} -> entered(work_item, version, next, &adjust.(%{&1 | track: track}))
      {:error, _refusal} -> :none
    end
  end

  defp resolved_starts(_work_item, _version, _stage, _act, _adjust), do: :none

  # The next round of the stage, as `next_run/2` steps it: answers that resolve an open
  # escalation are feedback, as is a comment sent with them (`comment`, with
  # `feedback_comment`).
  defp next_run_starts(work_item, version, stage, comment) do
    {event, escalation} = next_event(work_item)
    answer = event == :answered and not is_nil(escalation)

    adjust = fn facts ->
      facts = Map.merge(facts, Map.put(comment, :escalation_answer, answer))
      if answer or comment != %{}, do: noted(facts), else: facts
    end

    stepped(work_item, version, stage, event, adjust)
  end

  # The facts with a note or a comment of the act stored as feedback that no run handled
  # (`feedback_facts/3`), and `extra`.
  defp noted(facts, extra \\ %{}),
    do: facts |> Map.merge(%{feedback: true, feedback_noted: true}) |> Map.merge(extra)

  # The versions that a condition `{input: T, changed: true}` reads (`stored`), with the
  # versions of the stage's outputs that an approval covers, `approved_at`, a list of
  # `{type, stored_at}`, read as the stage's inputs of those types.
  defp stored_as_approved(%{stored: stored} = facts, approved_at) do
    stored =
      Enum.reduce(approved_at, stored, fn {type, at}, stored ->
        if Map.has_key?(stored, type),
          do: Map.update!(stored, type, &(&1 ++ [%{at: at, by: nil}])),
          else: stored
      end)

    %{facts | stored: stored}
  end

  defp stored_as_approved(facts, _approved_at), do: facts

  # The run that entering `stage` queues, on the facts read now as `later` changes them;
  # none for no stage.
  defp entered(work_item, version, stage, later \\ & &1)
  defp entered(_work_item, _version, nil, _later), do: :none

  defp entered(work_item, version, stage, later),
    do: stepped(work_item, version, stage, :enter, later, later)

  # The run that the runner's outcome of `event` queues, on the facts read now as `adjust`
  # changes them: its first `:queue`, or what its `:advance` enters, in the order
  # `apply_outcome/6` applies them. Each stage that an `:advance` enters reads its facts
  # as `later` changes them, and as an `:approve` before it does: the approval's outputs
  # count as approved, then `own` changes them, the change of the version added in this
  # stage, which that approval covers (`approved/5`).
  defp stepped(work_item, version, stage, event, adjust, later \\ & &1, own \\ & &1) do
    facts = adjust.(facts(work_item, version, stage))
    %{actions: actions} = Runner.step(stage, position(work_item), event, facts)
    queued(work_item, version, stage, actions, later, own)
  end

  # The run that the runner's `actions` for `stage` queue: their first `:queue`, or what
  # their `:advance` or `{:return, _}` enters, in the order `apply_outcome/6` applies them
  # (`stepped/7`).
  defp queued(work_item, version, stage, actions, later \\ & &1, own \\ & &1) do
    Enum.reduce_while(actions, {:none, later}, fn
      {:queue, %{workflow: workflow}}, _acc ->
        {:halt, {{:run, workflow}, later}}

      :approve, {none, later} ->
        {:cont, {none, approved(work_item, stage, :none, later, own)}}

      :advance, {_none, later} ->
        {:halt, {entered(work_item, version, next_stage(version, stage), later), later}}

      {:return, stage_id}, {_none, later} ->
        {:halt, {entered(work_item, version, Processes.stage(version, stage_id), later), later}}

      _other, acc ->
        {:cont, acc}
    end)
    |> elem(0)
  end

  # `later`, then the types of the versions an approval of the stage covers taken out of
  # the missing inputs: with `gate` `:person`, the versions its gate shows
  # (`approve_locked/7`, `gate_versions/3`); with `:none`, its newest outputs
  # (`approve_none!/4`). Each later stage reads them as its inputs of those types. Of those
  # types, each whose covered version has a file of more than 0 bytes counts for a later
  # stage's conditions, and the others do not (`counted/5`). Then `own`. `later` holds the
  # approvals of earlier stages: applied first, so the nearest approval wins, as a stage
  # reads its inputs (`read_version/6`).
  defp approved(work_item, stage, gate, later, own \\ & &1) do
    artifacts = Artifacts.list(work_item)

    shown =
      case gate do
        :person -> gate_versions(stage, artifacts, approvals_by_version(work_item))
        :none -> newest_outputs(stage, artifacts)
      end

    ids = Enum.map(shown, & &1.public_id)
    covered = for a <- artifacts, v <- a.versions, v.public_id in ids, uniq: true, do: a.type

    counting =
      for a <- artifacts, v <- a.versions, v.public_id in ids, counts?(v), uniq: true, do: a.type

    approved_at =
      for a <- artifacts, v <- a.versions, v.public_id in ids, do: {a.type, v.inserted_at}

    fn facts ->
      facts = later.(facts)

      own.(%{
        facts
        | missing_inputs: facts.missing_inputs -- covered,
          counted: Enum.uniq((facts.counted -- covered) ++ counting)
      })
      |> stored_as_approved(approved_at)
    end
  end

  ## Reading

  # status/2 is where the work item stands in its stage, as the work item page draws it;
  # nil for a work item the runner has not placed. `scope` decides whether its person may
  # approve the gate; with none, `approvable?` is false. Each of `outputs` has `names`,
  # the version of each name of its type that the gate shows, which a person's approval
  # records (`gate_names/4`). `missing_outputs` is the
  # required output types whose Exists check fails (`missing_outputs/1`); while it has
  # one, the gate of the stage is not approvable. `accept_needs` is the missing required
  # output types that Accept as it is requires (`accept_needs/4`). `accept_entry` is the
  # entry that an accept of the open escalation starts, where the accept does not take
  # the stage to its gate (`accept_entry/5`), else nil. `loop` is whether the work item is
  # in a loop of its stage: `rounds` is that loop's limit, or, past the last loop, the
  # limit of the loop it left, which a later entry's runs do not count by.
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
      # Read once: the shown state, the inputs and the condition inputs that count use them.
      approvals = approvals_by_version(work_item)
      state = shown_state(work_item, stage, artifacts, approvals)
      facts = condition_facts(work_item, version, stage, artifacts, false, approvals)
      outputs = outputs(work_item, version, stage, artifacts, facts, approvals)
      missing = missing(outputs)

      %{
        stage: %{id: stage["id"], name: stage["name"]},
        version: %{id: version.public_id, number: version.number},
        round: work_item.stage_round,
        rounds: shown_rounds(stage, work_item.stage_entry),
        loop: is_integer(work_item.loop_entry),
        state: state,
        gaps: shown_gaps(escalation, work_item, stage, artifacts, facts),
        outputs: outputs,
        missing_outputs: missing,
        accept_needs: accept_needs(work_item, stage, facts, missing),
        accept_entry:
          accept_entry(work_item, version, stage, escalation,
            strict: false,
            artifacts: artifacts,
            approvals: approvals,
            conditions: facts
          ),
        inputs: inputs(work_item, version, stage, artifacts, facts, approvals),
        escalation: escalation_map(escalation, work_item, stage, outputs, artifacts),
        waiting_workflow: waiting_workflow(work_item, stage, facts),
        gate: %{
          kind: get_in(stage, ["gate", "kind"]) || "person",
          approvers: Approvers.listed(stage),
          approvable?: state == :at_gate and Approvers.listed?(scope, stage) and missing == [],
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
  # person's change to it that no approval lists yet, else the version the gate of the
  # stage that made it approved; nil for none (`read_version/6`). A name whose newest
  # version is a withdrawal is left out (`Apiary.Artifacts.withdrawn?/1`).
  #
  # After a person moved the work item to an earlier stage, it ends with one entry for each
  # output of each stage the work item left that way (`moved_inputs/5`), marked
  # `from: :move`. After a return (`returned_inputs/5`), it ends with the newest `verdict`
  # and `verification` of the stage that returned it, marked `from: :return`. No other entry
  # has `from`, and the entries `status/1` and the stage's checks read are the unmarked ones.
  @doc false
  @spec inputs(WorkItem.t()) :: [map]
  def inputs(%WorkItem{} = work_item) do
    work_item = Repo.get!(WorkItem, work_item.id)

    case placed(work_item) do
      {:ok, version, stage} ->
        artifacts = Artifacts.list(work_item)
        approvals = approvals_by_version(work_item)
        facts = condition_facts(work_item, version, stage, artifacts, false, approvals)
        read = inputs(work_item, version, stage, artifacts, facts, approvals)
        moved = moved_inputs(work_item, version, stage, artifacts, read)
        read ++ moved ++ returned_inputs(work_item, stage, artifacts, read ++ moved)

      _other ->
        []
    end
  end

  # moved_inputs/5 is, for each stage that a person moved the work item out of to an earlier
  # stage in the take in, that is after the work item's stage and whose gate has not passed
  # since (`departures/2`): the newest version of each of its outputs made in it from the
  # time the work item last entered it to the time it left, marked `from: :move` and not
  # required. Newest departure first, outputs in the stage's order. An output whose version
  # `read` has already is left out. No approval lists such a version, unless it has a
  # `decision`: then it is a change.
  defp moved_inputs(work_item, version, stage, artifacts, read) do
    ids = Enum.map(version.document["stages"], & &1["id"])

    case departures(work_item, ids) do
      [] -> []
      departures -> moved_inputs(work_item, version, stage, artifacts, read, ids, departures)
    end
  end

  defp moved_inputs(work_item, version, stage, artifacts, read, ids, departures) do
    here = Enum.find_index(ids, &(&1 == stage["id"]))
    approvals = approvals_by_version(work_item)
    read_ids = for %{version: %{id: id}} <- read, do: id

    found =
      for departure <- departures,
          left = Processes.stage(version, departure.stage_id),
          Enum.find_index(ids, &(&1 == departure.stage_id)) > here,
          output <- Map.get(left, "outputs", []),
          found =
            newest_made_in(artifacts, output["type"], left["id"], &made_during?(&1, departure)),
          found.public_id not in read_ids,
          do: {output["type"], found}

    times = decision_times(work_item, for({_type, version} <- found, do: version))

    for {type, version} <- found do
      %{
        type: type,
        required: false,
        version: version_map(version, approvals, times),
        from: :move
      }
    end
  end

  # returned_inputs/4 is, for a work item whose stage was last entered by a return of a
  # later stage's run (`returned!/2`), the newest version of `verdict` and then of
  # `verification` made in the stage that run belongs to, marked `from: :return` and not
  # required; a type with no such version has no entry. A version in `listed` (the entries
  # already there) is left out. The entries last until the stage's gate passes again or the
  # work item leaves the stage by a move: an approval of the stage, or a move out of it,
  # made after the return (`left_since?/2`). A Request changes at the gate and a decision
  # in another stage end nothing. A newer return replaces them. They are not the stage's
  # outputs, so no approval lists them, and they are no person's note (`{feedback: new}`
  # stays false).
  defp returned_inputs(%WorkItem{take_in: take_in} = work_item, stage, artifacts, listed)
       when is_integer(take_in) do
    with %DispatchRun{} = run <- returning_run(work_item, stage),
         false <- left_since?(work_item, run) do
      listed_ids = for %{version: %{id: id}} <- listed, do: id
      approvals = approvals_by_version(work_item)

      found =
        for type <- @returned_types,
            found = newest_made_in(artifacts, type, run.stage_id),
            found.public_id not in listed_ids,
            do: {type, found}

      times = decision_times(work_item, for({_type, version} <- found, do: version))

      for {type, version} <- found do
        %{
          type: type,
          required: false,
          version: version_map(version, approvals, times),
          from: :return
        }
      end
    else
      _none -> []
    end
  end

  defp returned_inputs(%WorkItem{}, _stage, _artifacts, _listed), do: []

  # The newest run of the work item's take in that returned it to `stage` (`returned_to`),
  # by `returned_at`, nil for none.
  defp returning_run(%WorkItem{id: id, take_in: take_in}, stage) do
    Repo.one(
      from d in DispatchRun,
        where: d.work_item_id == ^id and d.take_in == ^take_in and d.returned_to == ^stage["id"],
        where: not is_nil(d.returned_at),
        order_by: [desc: d.returned_at, desc: d.id],
        limit: 1
    )
  end

  # Whether the work item's take in has, after the run's return, an approval of the stage
  # the return entered, or a move out of it.
  defp left_since?(%WorkItem{id: id, take_in: take_in}, %DispatchRun{} = run) do
    Repo.exists?(
      from d in GateDecision,
        where:
          d.work_item_id == ^id and d.take_in == ^take_in and d.stage_id == ^run.returned_to and
            d.kind in [:approve, :move] and d.inserted_at > ^run.returned_at
    )
  end

  # departures/2 is the decisions of the work item's take in that moved it out of a stage to
  # an earlier one (`move/5`, the move back of an escalation, a switch), by the stage left,
  # the newest of each, newest first, that nothing has ended: no approval of the stage, by
  # a person or automatic, and no move to a stage after it (`stage_ids` is the stages of the
  # process in order), made after it. A move with no `to_stage_id` counts as a move back and
  # ends nothing.
  defp departures(%WorkItem{id: id, take_in: take_in}, stage_ids) when is_integer(take_in) do
    decisions =
      Repo.all(
        from d in GateDecision,
          where: d.work_item_id == ^id and d.take_in == ^take_in and d.kind in [:approve, :move],
          order_by: [desc: d.inserted_at, desc: d.id]
      )

    index = &Enum.find_index(stage_ids, fn id -> id == &1 end)

    decisions
    |> Enum.filter(&(&1.kind == :move and moved_back?(&1, index)))
    |> Enum.uniq_by(& &1.stage_id)
    |> Enum.reject(fn departure ->
      Enum.any?(decisions, fn later ->
        DateTime.compare(later.inserted_at, departure.inserted_at) == :gt and
          ((later.kind == :approve and later.stage_id == departure.stage_id) or
             (later.kind == :move and moved_past?(later, departure.stage_id, index)))
      end)
    end)
  end

  defp departures(%WorkItem{}, _stage_ids), do: []

  defp moved_back?(%GateDecision{to_stage_id: nil}, _index), do: true

  defp moved_back?(%GateDecision{stage_id: left, to_stage_id: to}, index),
    do: is_integer(index.(to)) and is_integer(index.(left)) and index.(to) < index.(left)

  # Whether the move `decision` went to a stage after `stage_id`.
  defp moved_past?(%GateDecision{to_stage_id: to}, stage_id, index),
    do: is_binary(to) and is_integer(index.(to)) and index.(to) > index.(stage_id)

  # A version made from the time the work item last entered the stage (any time, for a
  # decision that kept none) to the time it left.
  defp made_during?(version, %GateDecision{left_stage_entered_at: entered, inserted_at: left}) do
    DateTime.compare(version.inserted_at, left) != :gt and
      (is_nil(entered) or DateTime.compare(version.inserted_at, entered) != :lt)
  end

  # artifact_index/1 is every artifact of the work item with its versions, newest first,
  # their writers, the approvals that cover each, whether a run a member cancelled
  # wrote it (`Apiary.Artifacts.cancelled?/1`) and whether it is a withdrawal
  # (`Apiary.Artifacts.withdraw/4`), a withdrawn name included: for each artifact, the public id of
  # the newest approved version, and whether a version of an earlier stage's artifact was
  # made after that approval ("changed after approval"). Each version has `decision` and
  # `decision_at`: the person's note that asked for it and the note's time, nil for none.
  # A version a cancelled run wrote stays in `versions`, and the artifact's stage and its
  # changed mark leave it out. `newest` is the public id of the newest version that
  # counts, nil for none: no cancelled run's.
  @doc false
  @spec artifact_index(WorkItem.t(), [Artifacts.Artifact.t()] | nil) :: [map]
  def artifact_index(%WorkItem{} = work_item, artifacts \\ nil) do
    work_item = Repo.get!(WorkItem, work_item.id)
    approvals = approvals_by_version(work_item)
    artifacts = artifacts || Artifacts.list(work_item)
    times = decision_times(work_item, Enum.flat_map(artifacts, & &1.versions))

    for artifact <- artifacts do
      versions = Enum.map(artifact.versions, &version_map(&1, approvals, times))

      newest = Artifacts.newest_counted(%{versions: versions})

      approved_version = Enum.find(versions, &(&1.approvals != []))

      newer? =
        approved_version != nil and newest != nil and newest.number > approved_version.number

      # A name that only cancelled runs wrote keeps the stage of its newest version.
      staged = newest || List.first(versions)

      %{
        type: artifact.type,
        name: artifact.name,
        stage_id: staged && staged.stage_id,
        approved_version: approved_version && approved_version.id,
        changed_after_approval: newer? and newest.stage_id != work_item.stage_id,
        newest: newest && newest.id,
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

  # skips/1 is the workflow entries the stage runner passed over in the work item's
  # current take in, because their condition was not met (`Apiary.Stages.Skip`), oldest
  # first: each with its stage, workflow, the condition that held it back as `input` (a
  # type) or `track` (an id, with `track_name`), `negated` (true for an `unless` that was
  # met), `changed` (true for a condition `{input: T, changed: true}`) and `after_attempt`,
  # the newest attempt of the take in when the runner passed it over (0 for none); for an
  # entry a first attempt passed over, `reason` is
  # `first_attempt_passed` and `cause_entry` is the first attempt's name, else its
  # workflow (both nil for a condition); with its `round`, `stage_entry` and `loop_entry`
  # (the entry's place, `loop_entry` nil outside a loop) and when it was passed over
  # (`inserted_at`). `earlier_skips/1` is those of the take ins before
  # the current one, each with its `take_in`; `stage_skips/1` the stages passed over whole
  # in the current take in (`skip_records/1`).
  @doc false
  @spec skips(WorkItem.t()) :: [map]
  def skips(%WorkItem{} = work_item), do: skip_records(work_item).skips

  @doc false
  @spec earlier_skips(WorkItem.t()) :: [map]
  def earlier_skips(%WorkItem{} = work_item), do: skip_records(work_item).earlier_skips

  @doc false
  @spec stage_skips(WorkItem.t()) :: [map]
  def stage_skips(%WorkItem{} = work_item), do: skip_records(work_item).stage_skips

  # skip_records/1 is `%{skips:, earlier_skips:, stage_skips:}`, each as the function of its
  # name returns it, read with one read of the work item's skips and one of its approvals
  # with a track. A stage passed over whole has no workflow: its entry in `stage_skips` has
  # its `stage_id`, the condition as `input` (a type) or `track` (an id, with `track_name`),
  # `negated` (true for an `unless` that was met), when it was passed over, and `approved`,
  # the approval that put the work item on the track that passed it over: the newest
  # approval with a track made in the take in before the stage was passed over, as
  # `%{kind, track_id, track_name, stage_id, user_id, at}`, `kind` `:approve` or `:move`; nil for none, and for a condition
  # that is no track's. `track_name` is the name the process version declares, else the id.
  # `track` is the id of the track the work item is on, as `track/1` reads it, nil for none.
  # A stage's record is deleted when the stage is entered again (`enter_locked/4`), so a
  # stage has at most one, and none once it ran or waits at its gate.
  @doc false
  @spec skip_records(WorkItem.t()) :: %{
          skips: [map],
          earlier_skips: [map],
          stage_skips: [map],
          track: String.t() | nil
        }
  def skip_records(%WorkItem{id: id, take_in: take_in} = work_item) when is_integer(take_in) do
    names = track_names(work_item)

    rows =
      Repo.all(
        from s in Skip,
          where: s.work_item_id == ^id and s.take_in <= ^take_in,
          order_by: [s.take_in, s.after_attempt, s.inserted_at, s.id]
      )

    approvals =
      Repo.all(
        from d in GateDecision,
          where:
            d.work_item_id == ^id and d.kind in [:approve, :move] and not is_nil(d.track) and
              d.take_in == ^take_in,
          order_by: [d.inserted_at, d.id]
      )

    {stages, entries} = Enum.split_with(rows, &is_nil(&1.workflow))

    entry = fn skip ->
      %{
        stage_id: skip.stage_id,
        workflow: skip.workflow,
        input: skip.input,
        track: skip.track,
        track_name: names[skip.track] || skip.track,
        negated: skip.negated,
        changed: skip.changed,
        reason: skip.reason,
        cause_entry: skip.cause_entry,
        round: skip.round,
        stage_entry: skip.stage_entry,
        loop_entry: skip.loop_entry,
        take_in: skip.take_in,
        after_attempt: skip.after_attempt,
        inserted_at: skip.inserted_at
      }
    end

    %{
      track: newest_track(approvals),
      skips: for(skip <- entries, skip.take_in == take_in, do: entry.(skip)),
      earlier_skips: for(skip <- entries, skip.take_in < take_in, do: entry.(skip)),
      stage_skips:
        for skip <- Enum.sort_by(stages, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}),
            skip.take_in == take_in do
          %{
            stage_id: skip.stage_id,
            input: skip.input,
            track: skip.track,
            track_name: names[skip.track] || skip.track,
            negated: skip.negated,
            changed: skip.changed,
            inserted_at: skip.inserted_at,
            approved: skip.track && approval_before(approvals, skip.inserted_at, names)
          }
        end
    }
  end

  def skip_records(%WorkItem{}), do: %{skips: [], earlier_skips: [], stage_skips: [], track: nil}

  # The track of the newest of `approvals`, oldest first; nil for none.
  defp newest_track(approvals) do
    case List.last(approvals) do
      nil -> nil
      decision -> decision.track
    end
  end

  # The newest of `approvals`, oldest first, made at or before `at`, as a map of the
  # approval; nil for none.
  defp approval_before(approvals, at, names) do
    case approvals
         |> Enum.filter(&(DateTime.compare(&1.inserted_at, at) != :gt))
         |> List.last() do
      nil ->
        nil

      decision ->
        %{
          kind: decision.kind,
          track_id: decision.track,
          track_name: names[decision.track] || decision.track,
          stage_id: decision.stage_id,
          user_id: decision.user_id,
          switch: decision.kind == :move and not is_nil(decision.escalation_id),
          at: decision.inserted_at
        }
    end
  end

  # The name of the track `id` that `version` declares; the id for a track it does not.
  defp track_name(version, id) do
    Enum.find_value(version.document["tracks"] || [], id, &(&1["id"] == id && &1["name"]))
  end

  # The names of the tracks the work item's process version declares, by id.
  defp track_names(work_item),
    do:
      Map.new(Processes.version_for(work_item).document["tracks"] || [], &{&1["id"], &1["name"]})

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
      {version.run_id, stored_verdict(version)}
    end
  end

  # The verdict a version of `verdict` stores: `:passed`; `:failed` for changes-requested
  # or escalate; nil for none, and for a file the store cannot read.
  defp stored_verdict(version) do
    case (Artifacts.read_json(version) || %{})["verdict"] do
      "passed" -> :passed
      value when value in ["changes-requested", "escalate"] -> :failed
      _none -> nil
    end
  end

  # run_sessions/1 is the sessions of each of the registered runs `ids` (their public ids,
  # `rn_…`) that ran as one run of a stage with `shared_run: true` (`Apiary.Stages.Session`),
  # in the order they ran, by the run's public id; a run with no session has no entry. Each
  # is `%{sequence:, workflow:, round:, stage_entry:, loop_entry:, state:, verdict:,
  # started_at:, ended_at:, stamped_from:, stamped_to:}`:
  #
  #   * `state` is the end the run reported for the session ("succeeded", "failed" or
  #     "cancelled"), nil for a session no report ended: the one the run is in, or was in
  #     when it stopped;
  #   * `verdict` is that of the run's `verdict` version that the session stored, read as
  #     `runs/1` reads a run's (`:passed`, `:failed` or nil): the version the step on the
  #     session's end read (`verdict_number`), or for a session no report ended the run's
  #     newest, where it is newer than the one the session before read; else nil;
  #   * `started_at` and `ended_at` are those of the session's `Apiary.Runs.SessionRecord`;
  #     with no record, or none of that time, when the row was written and, for a session a
  #     report ended, when the report was recorded. `ended_at` is nil for no end. With a
  #     record they are the machine's times, shown as they are; without
  #     one, they fall back to the row's stamps;
  #   * `stamped_from` and `stamped_to` are Qory Apiary's clock: when the row was written,
  #     and for a session a report ended, when the report was recorded (the row's
  #     `updated_at`); `stamped_to` is nil for a session no report ended. A version or a
  #     skip, which Qory Apiary also stamps, is compared with these, never with
  #     `started_at` and `ended_at`.
  @doc false
  @spec run_sessions([String.t()]) :: %{String.t() => [map]}
  def run_sessions([]), do: %{}

  def run_sessions(ids) when is_list(ids) do
    rows =
      Repo.all(
        from s in Session,
          join: r in subquery(Run.registered()),
          on: r.dispatch_run_id == s.dispatch_run_id,
          where: r.public_id in ^ids,
          order_by: [s.dispatch_run_id, s.sequence],
          select: {r.public_id, s}
      )

    run_ids = rows |> Enum.map(fn {_id, session} -> session.dispatch_run_id end) |> Enum.uniq()
    records = session_records(run_ids)
    versions = verdict_versions(run_ids)

    # Each session with the number of the verdict version it stored, nil for none.
    numbered =
      rows
      |> Enum.group_by(fn {id, _session} -> id end, fn {_id, session} -> session end)
      |> Map.new(fn {id, sessions} ->
        {numbered, _seen} =
          Enum.map_reduce(sessions, nil, fn session, seen ->
            # A session no report ended has the run's newest verdict, where it is newer
            # than the one the session before read, as the step on the run's end reads it.
            number = session.verdict_number || unreported(session, versions, seen)
            stored = if is_integer(number) and number != seen, do: number
            {{session, stored}, number || seen}
          end)

        {id, numbered}
      end)

    verdicts =
      for {_id, sessions} <- numbered,
          {session, number} <- sessions,
          version = number && versions[{session.dispatch_run_id, number}],
          version != nil,
          uniq: true,
          do: version

    read =
      verdicts |> Repo.preload(:files) |> Map.new(&{{&1.run_id, &1.number}, stored_verdict(&1)})

    Map.new(numbered, fn {id, sessions} ->
      {id,
       for {session, number} <- sessions do
         record = records[{session.dispatch_run_id, session.forager_session}]
         shown_session(session, record, number && read[{session.dispatch_run_id, number}])
       end}
    end)
  end

  # shared_sequences/1 is, by public id, the sequence of the stage of each of the
  # registered runs `ids` whose stage has `shared_run: true` in the run's process version.
  # The stage is read from the version's document by the run's `process_version_id` and
  # `stage_id`, so a later change of the work item's process changes nothing for a run.
  @doc false
  @spec shared_sequences([String.t()]) :: %{String.t() => list}
  def shared_sequences([]), do: %{}

  def shared_sequences(ids) when is_list(ids) do
    rows =
      Repo.all(
        from d in DispatchRun,
          join: r in subquery(Run.registered()),
          on: r.dispatch_run_id == d.id,
          where: r.public_id in ^ids,
          where: not is_nil(d.process_version_id) and not is_nil(d.stage_id),
          select: {r.public_id, d.process_version_id, d.stage_id}
      )

    versions = rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    documents =
      if versions == [],
        do: %{},
        else:
          Repo.all(
            from v in Processes.Version, where: v.id in ^versions, select: {v.id, v.document}
          )
          |> Map.new()

    for {id, version_id, stage_id} <- rows,
        stage = Processes.stage(documents[version_id], stage_id),
        Processes.shared_run?(stage),
        into: %{},
        do: {id, stage["sequence"] || []}
  end

  defp unreported(%Session{state: nil, dispatch_run_id: id}, versions, seen) do
    newest =
      for({{^id, number}, _version} <- versions, do: number) |> Enum.max(fn -> nil end)

    if newest && (is_nil(seen) or newest > seen), do: newest
  end

  defp unreported(_session, _versions, _seen), do: nil

  defp shown_session(session, record, verdict) do
    ended? = not is_nil(session.state)

    %{
      sequence: session.sequence,
      workflow: session.workflow,
      round: session.round,
      stage_entry: session.stage_entry,
      loop_entry: session.loop_entry,
      state: session.state,
      verdict: verdict,
      started_at: (record && record.started_at) || session.inserted_at,
      ended_at: if(ended?, do: (record && record.ended_at) || session.updated_at),
      stamped_from: session.inserted_at,
      stamped_to: if(ended?, do: session.updated_at)
    }
  end

  # The session records of the runs of the queue `run_ids`, by run and session number.
  defp session_records([]), do: %{}

  defp session_records(run_ids) do
    Repo.all(
      from r in SessionRecord,
        where: r.dispatch_run_id in ^run_ids,
        select: {{r.dispatch_run_id, r.session_number}, r}
    )
    |> Map.new()
  end

  # The `verdict` versions the runs of the queue `run_ids` stored, without their files, by
  # run and version number; `run_sessions/1` reads the files of those it shows.
  defp verdict_versions([]), do: %{}

  defp verdict_versions(run_ids) do
    Repo.all(
      from v in Apiary.Artifacts.Version,
        join: a in assoc(v, :artifact),
        where: v.run_id in ^run_ids and a.type == "verdict" and a.name == "main"
    )
    |> Map.new(&{{&1.run_id, &1.number}, &1})
  end

  # notes/1 is what the work item's next run reads as work item data, oldest first: what
  # people wrote (requests for changes, escalations resolved with a note, moves and the
  # answers to a run's questions) and the gaps of failed checks that started a round
  # (`:check`, with no person). What members gave Explore (`Apiary.Explore.Given`) are
  # notes of kind `:answer`: an answer, a review comment or a reply, the last two with
  # `comment` true. The page labels a comment by it; the run API sends no `comment`. A
  # request for changes, a move and an escalation have `id`, their public id (`gd_…`,
  # `es_…`); a run sends it as `decision` in a push (`Apiary.Stages.Notes`). An answer
  # and a check have `id` nil.
  #
  # Only open notes are listed. A note closes once its stage has an approval after it,
  # and a move once the stage it went to has one: a person's, or the automatic approval
  # of a gate `none`. A move kept with no `to_stage_id`, and an answer given at a run
  # with no stage, stay open. A closed note keeps its id, and a push may still send it as
  # `decision`: `Apiary.Stages.Notes.find/2` reads every note, open or closed.
  @doc false
  @spec notes(WorkItem.t()) :: [map]
  def notes(%WorkItem{} = work_item),
    do: work_item |> open_notes() |> Enum.map(&Map.delete(&1, :resolution))

  # open_notes/1 is `notes/1` with the `resolution` of each escalation's note, which
  # `feedback_facts/3` reads.
  defp open_notes(%WorkItem{id: id} = work_item) do
    passed = passed_at(id)

    decisions =
      Repo.all(
        from d in Notes.gate_decisions(id),
          select: %{
            id: d.public_id,
            kind: d.kind,
            stage_id: d.stage_id,
            to_stage_id: d.to_stage_id,
            user_id: d.user_id,
            note: d.note,
            artifact_version_id: d.artifact_version_id,
            inserted_at: d.inserted_at
          }
      )

    escalations =
      Repo.all(
        from e in Notes.escalations(id),
          select: %{
            id: e.public_id,
            kind: :escalation,
            stage_id: e.stage_id,
            user_id: e.resolved_by_id,
            note: e.note,
            artifact_version_id: nil,
            inserted_at: e.resolved_at,
            resolution: e.resolution
          }
      )

    checks =
      Repo.all(
        from c in Check,
          where: c.work_item_id == ^id,
          select: %{
            id: nil,
            kind: :check,
            stage_id: c.stage_id,
            user_id: nil,
            note: c.gaps,
            artifact_version_id: nil,
            inserted_at: c.inserted_at
          }
      )

    (decisions ++ escalations ++ checks ++ given_notes(work_item))
    |> Enum.filter(&open?(&1, passed))
    |> Enum.map(&Map.delete(&1, :to_stage_id))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  # The time of each stage's newest approval on the work item, by stage id.
  defp passed_at(work_item_id) do
    Repo.all(
      from d in GateDecision,
        where: d.work_item_id == ^work_item_id and d.kind == :approve,
        group_by: d.stage_id,
        select: {d.stage_id, max(d.inserted_at)}
    )
    |> Map.new()
  end

  # Whether a note is still open: the stage that closes it has no approval since. A
  # move's is the stage it went to; every other note's, its stage. Each row's
  # `inserted_at`, written under the work item's lock, orders a note and an approval; a
  # note and an approval with the same time leave the note open.
  defp open?(%{kind: :move, to_stage_id: nil}, _passed), do: true

  defp open?(%{kind: :move, to_stage_id: stage_id} = note, passed),
    do: not passed_after?(passed, stage_id, note.inserted_at)

  defp open?(%{stage_id: stage_id} = note, passed),
    do: not passed_after?(passed, stage_id, note.inserted_at)

  defp passed_after?(passed, stage_id, at) do
    case passed do
      %{^stage_id => %DateTime{} = last} -> DateTime.after?(last, at)
      _never -> false
    end
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
            id: nil,
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

  # A version of an artifact as the reads return it, with the approvals that cover it, and
  # `decision`, the id of the person's note that asked for it, with `decision_at`, the
  # time of that note from `times` (`Apiary.Stages.Notes.times/2`); nil for none.
  defp version_map(version, approvals, times) do
    decision = Map.get(version, :decision_id)

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
      approvals: Map.get(approvals, version.public_id, []),
      cancelled: Artifacts.cancelled?(version),
      withdrawn: Map.get(version, :withdrawn) == true,
      decision: decision,
      decision_at: decision && Map.get(times, decision)
    }
  end

  # The time of the note each of `versions` has as its `decision`.
  defp decision_times(work_item, versions),
    do: Notes.times(work_item.id, Enum.map(versions, &Map.get(&1, :decision_id)))

  # The approvals of the work item by the public id of each version they cover, oldest
  # first. `gate_none` is whether the stage's gate was `none` in the process version the
  # approval was recorded under, which a later version may change. The query reads only
  # that stage's gate kind, not the process document.
  defp approvals_by_version(work_item) do
    Repo.all(
      from d in GateDecision,
        join: v in Processes.Version,
        on: v.id == d.process_version_id,
        where: d.work_item_id == ^work_item.id and d.kind == :approve,
        order_by: d.inserted_at,
        select:
          {d,
           fragment(
             """
             COALESCE((SELECT s -> 'gate' ->> 'kind' = 'none'
                       FROM jsonb_array_elements(? -> 'stages') AS s
                       WHERE s ->> 'id' = ? LIMIT 1), false)
             """,
             v.document,
             d.stage_id
           )}
    )
    |> Enum.flat_map(fn {decision, gate_none} ->
      approval = %{
        user_id: decision.user_id,
        automatic: decision.automatic,
        gate_none: gate_none,
        stage_id: decision.stage_id,
        inserted_at: decision.inserted_at
      }

      for id <- decision.versions, do: {id, approval}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  ## Applying the runner's rules

  # `forced` is true where a person moved the work item into `stage`: the stage's own
  # condition then does not pass it over (`Runner`, `facts.forced`).
  defp enter_locked(work_item, version, stage, forced? \\ false) do
    # A stage entered again is no longer the stage that was passed over: its record of the
    # pass-over goes, and a new pass-over writes a new one. So do the records of the entries
    # a first attempt passed over. The records of entries passed over for a condition,
    # `{feedback: new}` among them, stay.
    Repo.delete_all(
      from s in Skip,
        where:
          s.work_item_id == ^work_item.id and s.stage_id == ^stage["id"] and
            s.take_in == ^work_item.take_in and
            (is_nil(s.workflow) or s.reason == "first_attempt_passed")
    )

    now = DateTime.utc_now()

    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [stage_entered_at: now]
      )

    apply_event(%{work_item | stage_entered_at: now}, version, stage, :enter, nil, %{
      forced: forced?
    })
  end

  # `more` is facts of the run that ended, beside the stage's (`facts/3`). `by` is the
  # member who accepted an escalation, for the approval at a gate `none`; nil for none.
  defp apply_event(work_item, version, stage, event, run_id \\ nil, more \\ %{}, by \\ nil) do
    facts = Map.merge(facts(work_item, version, stage), more)
    delete_first_attempt_skips(work_item, stage, event, facts)
    outcome = Runner.step(stage, position(work_item), event, facts)
    apply_outcome(work_item, version, stage, outcome, run_id, by)
  end

  # `mode` `:session`, for a step on a session of a shared run (`next_session/2`): a
  # workflow of the stage runs as the run's next session, `{:session, spec}` in place of a
  # run queued. The next stage's run is queued as for any mode.
  defp apply_outcome(work_item, version, stage, outcome, run_id, by, mode \\ :queue) do
    %{state: state, position: position, actions: actions} = outcome
    work_item = place!(work_item, version, stage["id"], state, position)

    Enum.reduce(actions, {work_item, nil}, fn
      {:queue, spec}, {work_item, _run} when mode == :session ->
        {work_item, {:session, spec}}

      {:queue, spec}, {work_item, _run} ->
        {:ok, run} = queue!(work_item, version, stage, spec)
        {work_item, run}

      {:skip, spec}, {work_item, run} ->
        skip!(work_item, version, stage, spec)
        {work_item, run}

      {:skip_stage, spec}, {work_item, run} ->
        skip!(
          work_item,
          version,
          stage,
          Map.merge(spec, %{
            workflow: nil,
            entry: nil,
            loop_entry: nil,
            round: 1
          })
        )

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

      :approve, {work_item, run} ->
        :ok = approve_none!(work_item, version, stage, by)
        {work_item, run}

      {:return, stage_id}, {work_item, _run} ->
        returned!(run_id, stage_id)
        enter_locked(work_item, version, Processes.stage(version, stage_id))

      :advance, {work_item, _run} ->
        advance(work_item, version, stage)
    end)
  end

  # A gate `none` records the approval of the stage's newest outputs (vault 0252): with no
  # member, `automatic`, when the stage passed its gate; with the member `by` who accepted
  # the escalation that ended the stage. The accept approves the newest versions that
  # exist, as the stage's checks did not run. A version with a `decision` is left out: only
  # a person's approval at a gate lists it (vault 0261, 624 (a); C-2 note, section 5).
  defp approve_none!(work_item, version, stage, by) do
    %GateDecision{
      public_id: PublicId.generate(GateDecision.prefix()),
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      user_id: by,
      automatic: is_nil(by),
      kind: :approve,
      take_in: work_item.take_in,
      versions:
        for(
          v <- newest_outputs(stage, Artifacts.list(work_item)),
          is_nil(v.decision_id),
          do: v.public_id
        ),
      inserted_at: DateTime.utc_now()
    }
    |> PublicId.Insert.insert!()

    :ok
  end

  # The run whose end returned the work item to the stage `stage_id` keeps it, so the
  # stage runner counts its entry's returns (`returns/2`). A person's Request changes has
  # no run, and counts none.
  defp returned!(nil, _stage_id), do: :ok

  defp returned!(run_id, stage_id) do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^run_id),
        set: [returned_to: stage_id, returned_at: DateTime.utc_now()]
      )

    :ok
  end

  ## Tracks

  @doc """
  track/1 is the id of the track `work_item` is on: the track of its newest approval, or move
  forward past a gate, that has one, at any stage, made in its current take in, or nil where
  none chose a track (a process with no tracks, or no approval yet). A later approval with
  another track changes it. A work item taken in again starts with none.
  """
  @spec track(WorkItem.t()) :: String.t() | nil
  def track(%WorkItem{} = work_item) do
    case track_decisions(work_item) do
      [%{track: track} | _older] -> track
      [] -> nil
    end
  end

  # The approvals and moves of the work item that have a track, made in its current take in,
  # newest first: each `track`, the `stage_id` the decision was made at, the
  # `process_version_id` it was made under and, for a switch, the `escalation_id` it
  # resolves; `[]` for none.
  defp track_decisions(%WorkItem{take_in: nil}), do: []

  defp track_decisions(%WorkItem{id: id, take_in: take_in}) do
    Repo.all(
      from d in GateDecision,
        where:
          d.work_item_id == ^id and d.kind in [:approve, :move] and not is_nil(d.track) and
            d.take_in == ^take_in,
        order_by: [desc: d.inserted_at, desc: d.id],
        select: %{
          track: d.track,
          stage_id: d.stage_id,
          escalation_id: d.escalation_id,
          process_version_id: d.process_version_id
        }
    )
  end

  @doc """
  offered_tracks/1 is the tracks the gate of `work_item`'s stage offers, in the gate's
  order, each `%{id, name, description}` as the process declares it (`description` nil for
  none). `[]` where the gate offers none, the process declares no tracks, or the work item
  is in no stage.
  """
  @spec offered_tracks(WorkItem.t()) :: [
          %{id: String.t(), name: String.t(), description: String.t() | nil}
        ]
  def offered_tracks(%WorkItem{} = work_item) do
    case placed(work_item) do
      {:ok, version, stage} -> gate_tracks(version, stage)
      :not_placed -> []
    end
  end

  @doc """
  switch_tracks/1 is the tracks that an escalation of `work_item` offers a switch to, each
  `%{id, name, description, gate, first, later}`: the other tracks of the gate that recorded
  the track the work item is on (`track/1`), where that gate offers tracks, the work item is
  not on its first track, and the gate is before the work item's stage. `gate` is the name
  of that gate's stage, `first` the name of the stage a switch to the track starts and
  `later` the names of the stages after it that run on the track (`nil` and `[]` where none
  runs). `[]` otherwise, and where the work item is in no stage. A work item offered a switch
  is offered no accept and no move back (`resolve_escalation/5`, `move/5`).
  """
  @spec switch_tracks(WorkItem.t()) :: [
          %{
            id: String.t(),
            name: String.t(),
            description: String.t() | nil,
            gate: String.t(),
            first: String.t() | nil,
            later: [String.t()]
          }
        ]
  def switch_tracks(%WorkItem{} = work_item) do
    with {:ok, version, stage} <- placed(work_item),
         {gate, others} <- switch_offers(work_item, version, stage) do
      artifacts = Artifacts.list(work_item)

      for track <- others do
        {first, later} = switch_plan(work_item, version, gate, track.id, artifacts)
        Map.merge(track, %{gate: gate["name"], first: first, later: later})
      end
    else
      _none -> []
    end
  end

  # The names of the stage a switch to `track` starts and of the stages after it that run
  # on `track`: from the stage after `gate`, the stages whose condition holds on the track
  # and that have a workflow to run there. `{nil, []}` where none does.
  defp switch_plan(work_item, version, gate, track, artifacts) do
    stages = version.document["stages"]
    at = Enum.find_index(stages, &(&1["id"] == gate["id"]))
    approvals = approvals_by_version(work_item)

    running =
      for stage <- Enum.drop(stages, at + 1),
          counted = counted(work_item, version, stage, artifacts, approvals),
          is_nil(Runner.unmet(stage, %{track: track, counted: counted})),
          Runner.workflows(stage, counted, track) != [],
          do: stage["name"]

    case running do
      [first | later] -> {first, later}
      [] -> {nil, []}
    end
  end

  @doc false
  # offered_tracks/2 is `offered_tracks/1` for a caller that has read the work item's
  # process version (`Apiary.Processes.version_for/1`): it reads nothing.
  @spec offered_tracks(WorkItem.t(), Processes.Version.t()) :: [
          %{id: String.t(), name: String.t(), description: String.t() | nil}
        ]
  def offered_tracks(%WorkItem{stage_id: stage_id}, version) when is_binary(stage_id) do
    case Processes.stage(version, stage_id) do
      nil -> []
      stage -> gate_tracks(version, stage)
    end
  end

  def offered_tracks(%WorkItem{}, _version), do: []

  defp gate_tracks(version, stage) do
    declared = Map.new(version.document["tracks"] || [], &{&1["id"], &1})

    for id <- stage["gate"]["tracks"] || [], track = declared[id] do
      %{id: id, name: track["name"], description: track["description"]}
    end
  end

  @doc """
  proposed_track/1 is the track that the runs of `work_item`'s stage proposed since the work
  item last entered the stage (`work_items.stage_entered_at`; all the runs of the take in for
  a work item with none): the `track.id` of the newest `verdict` named `main` with a track
  that any of those runs pushed. nil where the stage has no such run, no run pushed a
  verdict with a track, or the artifact store cannot be read. The track is not checked
  against the gate: `chosen_track/3` does that, and refuses the approval where the store
  cannot be read.
  """
  @spec proposed_track(WorkItem.t(), [Artifacts.Artifact.t()] | nil) :: String.t() | nil
  def proposed_track(%WorkItem{} = work_item, artifacts \\ nil) do
    case proposed_track_with_reason(work_item, artifacts) do
      %{id: id} -> id
      nil -> nil
    end
  end

  @doc false
  # proposed_track_with_reason/2 is `proposed_track/2` with the reason that the same verdict
  # gives for the track (`track.reason`): `%{id:, reason:}`, `reason` nil where the verdict
  # has none or a blank one; nil where `proposed_track/2` is nil. `artifacts`, the work
  # item's artifacts (`Apiary.Artifacts.list/1`) where the caller has read them, spare that
  # read.
  @spec proposed_track_with_reason(WorkItem.t(), [Artifacts.Artifact.t()] | nil) ::
          %{id: String.t(), reason: String.t() | nil} | nil
  def proposed_track_with_reason(%WorkItem{} = work_item, artifacts \\ nil) do
    case proposal(work_item, artifacts) do
      {:ok, found} -> found
      {:error, :store_unavailable} -> nil
    end
  end

  @doc false
  # full_suite_versions/2 is the verdict versions that belong to the build report version
  # `number` among `artifacts` (the work item's artifacts, `Apiary.Artifacts.list/1`), newest
  # first: the versions of the artifact `verdict`, name `main`, that the run which wrote the
  # report wrote, that are no withdrawal and that no cancelled run wrote
  # (`Artifacts.cancelled?/1`). [] where the report has no run, or that run pushed no
  # verdict. A verdict of another run or another stage is never the result of the work the
  # report is about.
  @spec full_suite_versions([Artifacts.Artifact.t()], pos_integer) :: [map]
  def full_suite_versions(artifacts, number) do
    with %{run_id: run_id} when is_binary(run_id) <- report_version(artifacts, number) do
      artifacts
      |> Stream.filter(&(&1.type == "verdict" and &1.name == "main"))
      |> Stream.flat_map(& &1.versions)
      |> Enum.filter(
        &(&1.run_id == run_id and not Map.get(&1, :withdrawn, false) and
            not Artifacts.cancelled?(&1))
      )
    else
      _none -> []
    end
  end

  defp report_version(artifacts, number) do
    artifacts
    |> Stream.filter(&(&1.type == "build-report" and &1.name == "main"))
    |> Stream.flat_map(& &1.versions)
    |> Enum.find(&(&1.number == number and not Artifacts.cancelled?(&1)))
  end

  @doc false
  # full_suite_read/1 is the full test suite result in the file of the verdict version
  # `version` (one of `full_suite_versions/2`): `{:ok, result}` with `%{state:, passed:,
  # failed:, skipped:, minutes:, reason:}`; `:none` for a file that has no result (no
  # version, no `full_suite`, or a result that is not whole); `{:error, :store_unavailable}`
  # where the store cannot read the file. `state` is `:passed`, `:failed` or `:not_run`.
  # `:passed` and `:failed` have `minutes`, a number, and the three counts, whole numbers
  # (12.0 is 12), or nil for all three where the file has none; `reason` is nil. `:not_run`
  # has `reason` and nil for the others: the reason with white space trimmed and one final
  # full stop dropped, which is a line of text, so a reason of no text is no result. The
  # version's file does not change, so `{:ok, _}` and `:none` may be kept by the version's
  # public id; the error may not.
  @spec full_suite_read(map | nil) ::
          {:ok,
           %{
             state: :passed | :failed | :not_run,
             passed: non_neg_integer | nil,
             failed: non_neg_integer | nil,
             skipped: non_neg_integer | nil,
             minutes: number | nil,
             reason: String.t() | nil
           }}
          | :none
          | {:error, :store_unavailable}
  def full_suite_read(nil), do: :none

  def full_suite_read(version) do
    case Artifacts.stored_json(version) do
      {:ok, %{"full_suite" => %{} = suite}} ->
        case suite_result(suite) do
          nil -> :none
          result -> {:ok, result}
        end

      {:ok, _no_suite} ->
        :none

      {:error, :store_unavailable} = unavailable ->
        unavailable
    end
  end

  @doc false
  # full_suite/3 is the result of the full test suite of the build report version `number`
  # among `artifacts`: the result in the newest of the report's verdicts
  # (`full_suite_versions/2`) that has one, so a later verdict of the run with no result does
  # not hide an earlier one. Returns `{result, reads}`, `result` as in `{:ok, result}` of
  # `full_suite_read/1` or nil for none. `reads` is the reads of verdict files kept by the
  # version's public id, `%{id => {:ok, result} | :none}`: a version in it is not read again,
  # and a file the store cannot read is not kept, so it is read again at the next call; it
  # ends the search with no result.
  @spec full_suite([Artifacts.Artifact.t()], pos_integer, map) :: {map | nil, map}
  def full_suite(artifacts, number, reads \\ %{}) do
    artifacts
    |> full_suite_versions(number)
    |> Enum.reduce_while({nil, reads}, fn version, {nil, reads} ->
      read = Map.get_lazy(reads, version.public_id, fn -> full_suite_read(version) end)

      case read do
        {:ok, result} -> {:halt, {result, Map.put(reads, version.public_id, read)}}
        :none -> {:cont, {nil, Map.put(reads, version.public_id, read)}}
        {:error, :store_unavailable} -> {:halt, {nil, reads}}
      end
    end)
  end

  defp suite_result(%{"state" => state} = suite) when state in ~w(passed failed) do
    keys = ~w(passed failed skipped)
    minutes = suite["minutes"]

    # The three counts come together or not at all; a count that is there is a whole number.
    counts =
      case Enum.filter(keys, &Map.has_key?(suite, &1)) do
        [] ->
          {:ok, [nil, nil, nil]}

        ^keys ->
          if Enum.all?(keys, &(suite_count(suite[&1]) != nil)),
            do: {:ok, Enum.map(keys, &suite_count(suite[&1]))}

        _some ->
          nil
      end

    with {:ok, [passed, failed, skipped]} <- counts,
         true <- is_number(minutes) and not Map.has_key?(suite, "reason") do
      %{
        state: String.to_existing_atom(state),
        passed: passed,
        failed: failed,
        skipped: skipped,
        minutes: minutes,
        reason: nil
      }
    else
      _not_whole -> nil
    end
  end

  defp suite_result(%{"state" => "not_run", "reason" => reason}) when is_binary(reason) do
    case reason |> String.trim() |> String.replace_suffix(".", "") do
      "" ->
        nil

      reason ->
        %{state: :not_run, passed: nil, failed: nil, skipped: nil, minutes: nil, reason: reason}
    end
  end

  defp suite_result(_suite), do: nil

  # A count the file has as 12.0 is the whole number 12.
  defp suite_count(count) when is_integer(count) and count >= 0, do: count

  defp suite_count(count) when is_float(count) and count >= 0 and count == trunc(count),
    do: trunc(count)

  defp suite_count(_count), do: nil

  # `{:ok, %{id:, reason:}}` or `{:ok, nil}` for the track proposed; `{:error,
  # :store_unavailable}` where a verdict's file cannot be read from the store.
  defp proposal(work_item, artifacts \\ nil)

  defp proposal(%WorkItem{stage_id: stage_id} = work_item, artifacts) when is_binary(stage_id) do
    runs =
      from d in DispatchRun,
        left_join: r in subquery(Run.registered()),
        on: r.dispatch_run_id == d.id,
        where:
          d.work_item_id == ^work_item.id and d.take_in == ^work_item.take_in and
            d.stage_id == ^stage_id,
        select: {d.id, r.id}

    runs =
      case work_item.stage_entered_at do
        nil -> runs
        entered -> from d in runs, where: d.inserted_at >= ^entered
      end

    run_ids =
      runs
      |> Repo.all()
      |> Enum.flat_map(fn {dispatch_run_id, run_id} -> [dispatch_run_id, run_id] end)
      |> Enum.reject(&is_nil/1)

    # The versions are newest first: the first with a track is the newest, and the rest are
    # not read.
    (artifacts || Artifacts.list(work_item))
    |> Stream.filter(&(&1.type == "verdict" and &1.name == "main"))
    |> Stream.flat_map(& &1.versions)
    |> Stream.filter(&(&1.run_id in run_ids))
    |> Enum.reduce_while({:ok, nil}, fn version, found ->
      case Artifacts.stored_json(version) do
        {:ok, %{"track" => %{"id" => id} = track}} when is_binary(id) ->
          {:halt, {:ok, %{id: id, reason: track_reason(track["reason"])}}}

        {:ok, _none} ->
          {:cont, found}

        {:error, :store_unavailable} = unavailable ->
          {:halt, unavailable}
      end
    end)
  end

  defp proposal(%WorkItem{}, _artifacts), do: {:ok, nil}

  defp track_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      reason -> reason
    end
  end

  defp track_reason(_reason), do: nil

  # The track an approval at `stage`'s gate records: the `track` of `opts` where the gate
  # offers it, else `{:error, {:track_not_offered, track}}`. With no `track`: the track the
  # stage's runs proposed (`proposed_track/1`) where the gate offers it, else the track the
  # work item is on (`track/1`) where the gate offers it, else the gate's first track, else
  # nil. A gate that offers none refuses a track that `opts` names and records none
  # otherwise. Where a verdict of the stage cannot be read from the artifact store, the
  # choice is `{:error, :store_unavailable}`: no track is guessed.
  defp chosen_track(work_item, stage, opts) do
    offered = for id <- stage["gate"]["tracks"] || [], do: id

    case Keyword.get(opts, :track) do
      nil ->
        with {:ok, found} <- proposal(work_item) do
          proposed = found && found.id
          current = track(work_item)

          {:ok,
           cond do
             proposed in offered -> proposed
             current in offered -> current
             true -> List.first(offered)
           end}
        end

      track when is_binary(track) ->
        if track in offered, do: {:ok, track}, else: {:error, {:track_not_offered, track}}

      _other ->
        {:error, :invalid}
    end
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

  # The facts the stage runner steps on (`Runner.step/4`). `read` has what the caller has
  # read already: `artifacts` (`Artifacts.list/1`), `approvals`
  # (`approvals_by_version/1`) and `conditions`, the condition facts (`condition_facts/6`)
  # read with `strict`, which is true by default; a page reads them with false, so the
  # read does not raise.
  defp facts(work_item, version, stage, read \\ []) do
    # The whole row: `Apiary.Processes.workflow_declaration/2` reads its stack.
    workspace = Repo.get!(Workspace, work_item.workspace_id)
    artifacts = Keyword.get_lazy(read, :artifacts, fn -> Artifacts.list(work_item) end)

    declarations =
      Map.new(Runner.workflows(stage), &{&1, Processes.workflow_declaration(workspace, &1)})

    # Read once per event: the outputs' checks and the runner both use it.
    approvals = Keyword.get_lazy(read, :approvals, fn -> approvals_by_version(work_item) end)
    strict? = Keyword.get(read, :strict, true)

    conditions =
      Keyword.get_lazy(read, :conditions, fn ->
        condition_facts(work_item, version, stage, artifacts, strict?, approvals)
      end)

    Map.merge(conditions, %{
      missing_inputs:
        for(
          %{required: true, version: nil, type: type} <-
            inputs(work_item, version, stage, artifacts, conditions, approvals),
          do: type
        ),
      undeclared:
        undeclared(
          workspace,
          Map.take(declarations, Runner.workflows_met(stage, conditions))
        ),
      declarations: declarations,
      failed_checks:
        missing(outputs(work_item, version, stage, artifacts, conditions, approvals)),
      machine: version.document["machine"],
      test: work_item.test,
      earlier: Map.new(earlier_stages(version, stage), &{&1["id"], &1["name"]}),
      returns: returns(work_item, stage)
    })
  end

  # The stages of the version before `stage`, in order.
  defp earlier_stages(version, stage) do
    stages = version.document["stages"] || []
    Enum.take_while(stages, &(&1["id"] != stage["id"]))
  end

  # The runs of `stage` in the work item's take in that returned the work item to an
  # earlier stage (`returned!/2`), counted by stage id, so a version that keeps the stage
  # under another index keeps the count; 0 at an entry with no return key.
  defp returns(work_item, stage) do
    with %{entry: entry, loop_entry: nil} <- position(work_item),
         true <- work_item.stage_id == stage["id"],
         %{"return" => %{}} <- Enum.at(stage["sequence"] || [], entry) do
      Repo.aggregate(
        from(d in DispatchRun,
          where: d.work_item_id == ^work_item.id and d.take_in == ^work_item.take_in,
          where: d.stage_id == ^stage["id"] and not is_nil(d.returned_to)
        ),
        :count
      )
    else
      _other -> 0
    end
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

  # The records of the entries a first attempt passed over (`Runner`), in the stage and the
  # take in, go when the stage runs those entries again: Request changes runs the sequence
  # from its start, so all of them go, and so does feedback that enters the stage again at
  # its first entry (`Runner.feedback_entry?/3`). Another round at the end of the sequence
  # runs only the stage's last loop, so only the records of that loop's body go and the
  # entries before it, which still do not run, keep theirs. Another round with no loop runs
  # the sequence from its start.
  defp delete_first_attempt_skips(work_item, stage, event, facts) do
    query =
      from s in Skip,
        where:
          s.work_item_id == ^work_item.id and s.stage_id == ^stage["id"] and
            s.take_in == ^work_item.take_in and s.reason == "first_attempt_passed"

    case {event, Runner.feedback_entry?(stage, event, facts)} do
      {:request_changes, _feedback} ->
        Repo.delete_all(query)

      {_event, true} ->
        Repo.delete_all(query)

      {{:another_round, _cause}, false} ->
        loop = List.last(Runner.loops(stage, facts))

        if loop && Runner.at_end?(stage, position(work_item)),
          do: Repo.delete_all(from s in query, where: s.stage_entry == ^loop),
          else: Repo.delete_all(query)

      _other ->
        :ok
    end
  end

  # A workflow entry the runner passed over, after the newest run of the take in.
  defp skip!(work_item, version, stage, spec) do
    newest =
      Repo.one(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id and r.take_in == ^work_item.take_in,
          select: max(r.attempt)
      )

    %Skip{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      take_in: work_item.take_in,
      stage_entry: spec.entry,
      loop_entry: spec.loop_entry,
      round: spec.round,
      workflow: spec.workflow,
      input: spec.input,
      track: spec.track,
      negated: spec.negated,
      changed: Map.get(spec, :changed, false),
      reason: Map.get(spec, :reason),
      cause_entry: Map.get(spec, :cause_entry),
      after_attempt: newest || 0,
      inserted_at: DateTime.utc_now()
    }
    |> Repo.insert!()
  end

  defp escalate!(work_item, version, stage, position, cause, points, run_id) do
    :ok = close_open(work_item, :close, nil, nil)

    %Escalation{
      public_id: PublicId.generate(Escalation.prefix()),
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
    |> PublicId.Insert.insert!()

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
  # (`Apiary.Explore.Questions.open_in_take_in/2`), asked by a run no member cancelled
  # (`Apiary.Explore.Questions.counted_take_in_runs/2`); a newest version whose file
  # cannot be read raises, so the end is not read as one with no open question.
  defp open_questions(work_item, %DispatchRun{take_in: take_in}) do
    case Apiary.Explore.Questions.current(work_item) do
      {:ok, {_version, document}} ->
        runs = Apiary.Explore.Questions.counted_take_in_runs(work_item.id, take_in)
        Apiary.Explore.Questions.open_in_take_in(document, runs)

      {:ok, nil} ->
        []

      {:error, :store_unavailable} ->
        raise Apiary.Stages.QuestionsUnreadable
    end
  end

  # A run that ended before its exit, or whose registered run failed, was lost or was
  # cancelled; or that a member cancelled, whatever its exit (`Apiary.Runs.Cancel`).
  defp stopped?(%DispatchRun{end_cause: :run_ended} = run) do
    case Repo.one(from r in Run.registered(), where: r.dispatch_run_id == ^run.id) do
      %Run{exit_state: state} when state in ["failed", "lost", "cancelled"] -> true
      %Run{} = registered -> Run.cancel_requested?(registered)
      nil -> false
    end
  end

  defp stopped?(%DispatchRun{}), do: true

  # The number of the newest version of the proposal named `main` that `run`, which ended
  # by its exit, pushed before its registered run failed; nil for none, and for a run a
  # member cancelled, whose proposal does not count.
  defp failed_proposal(%DispatchRun{id: id, end_cause: :run_ended}) do
    Repo.one(
      from v in Apiary.Artifacts.Version,
        join: a in Apiary.Artifacts.Artifact,
        on: a.id == v.artifact_id,
        join: r in subquery(Run.registered()),
        on: r.dispatch_run_id == v.run_id,
        where: v.run_id == ^id and a.type == "proposal" and a.name == "main",
        where: r.exit_state == "failed" and is_nil(r.cancel_requested_at),
        select: max(v.number)
    )
  end

  defp failed_proposal(%DispatchRun{}), do: nil

  # A run of a workflow other than Explore: the open questions of the run's take in
  # (`open_questions/2`), with the points of its verdict `escalate` where it pushed one,
  # else the newest verdict named `main` that the run pushed (`ended_verdict!/1`), else
  # stopped when its registered run failed, was lost or was cancelled, or a member
  # cancelled it (`stopped?/1`).
  defp reported_result(work_item, run) do
    open = open_questions(work_item, run)
    verdict = ended_verdict!(run)

    cond do
      open != [] ->
        {:questions, question_texts(open), escalate_points(verdict, open)}

      verdict ->
        open_points(verdict, open)

      stopped?(run) ->
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
  # pushed none, ended another way, or a member cancelled it (`Apiary.Runs.Cancel`),
  # whose verdict does not count. `Apiary.Explore.Outcome` reads it for Explore's
  # `escalate`.
  @doc false
  @spec reported_verdict(DispatchRun.t()) ::
          Runner.run_result() | {:error, :store_unavailable} | nil
  def reported_verdict(%DispatchRun{end_cause: :run_ended} = run) do
    if Cancel.dispatch_run_cancelled?(run), do: nil, else: newest_verdict(run)
  end

  def reported_verdict(%DispatchRun{}), do: nil

  defp newest_verdict(run) do
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

  # The verdict of a run of any workflow as `reported_verdict/1` reads it; a verdict whose
  # file the store cannot read raises, so the end is not read as one with no verdict.
  defp verdict!(run) do
    case reported_verdict(run) do
      {:error, :store_unavailable} -> raise Apiary.Stages.VerdictUnreadable
      verdict -> verdict
    end
  end

  # The verdict of a run's end as `verdict!/1` reads it; for a run of a stage with
  # `shared_run: true` whose sessions stepped the stage runner (`next_session/2`), only a
  # verdict newer than the newest one those steps saw, as a session's step reads it: a
  # verdict that a session's step used does not count again.
  defp ended_verdict!(run) do
    seen =
      Repo.one(
        from s in Session,
          where: s.dispatch_run_id == ^run.id and not is_nil(s.response),
          select: max(s.verdict_number)
      )

    if is_integer(seen) and not Cancel.dispatch_run_cancelled?(run),
      do: run |> session_verdict(seen) |> elem(0),
      else: verdict!(run)
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

  # The points of a verdict's file: its list of point objects, nil for none. A `run_again`
  # point may have `fix`, which the page shows in place of "Run another round."
  # (`Apiary.Stages.Points`).
  defp points(points) when is_list(points),
    do: for(%{} = point <- points, do: Map.take(point, ~w(text action question fix)))

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
  # last approval is at its gate again. `approvals` is `approvals_by_version/1`, read where
  # needed for nil.
  defp shown_state(work_item, stage, artifacts, approvals \\ nil)

  defp shown_state(%WorkItem{stage_state: :done} = work_item, stage, artifacts, approvals) do
    if reopened?(work_item, stage, artifacts, approvals), do: :at_gate, else: :done
  end

  defp shown_state(%WorkItem{stage_state: state}, _stage, _artifacts, _approvals), do: state

  # A withdrawal is a version too: a name the last approval covered whose newest version is
  # now a withdrawal reopens the gate. Where another name of the type is left, its version
  # is not among `covered`, so `newest -- covered` reopens the gate already;
  # `withdrawn_since?/2` matters only when no other name of the type is left. After a
  # person's approval, the gate compares the versions it shows (`gate_versions/3`), which
  # that approval covered. After a gate `none` approval, it compares the newest outputs,
  # where one with a `decision` does not reopen the gate: `approve_none!/4` leaves such a
  # version out, and only a person's approval lists it.
  # `approvals` is `approvals_by_version/1`, read here for nil.
  defp reopened?(work_item, stage, artifacts, approvals) do
    case last_approval(work_item, stage["id"]) do
      %GateDecision{versions: covered} = approval ->
        newest =
          if gate_none_approval?(approval) do
            for v <- newest_outputs(stage, artifacts),
                not is_binary(v.decision_id),
                do: v.public_id
          else
            Enum.map(
              gate_versions(stage, artifacts, approvals || approvals_by_version(work_item)),
              & &1.public_id
            )
          end

        newest -- covered != [] or withdrawn_since?(artifacts, covered)

      nil ->
        false
    end
  end

  # Whether `approve_none!/4` wrote `approval`: an automatic one, or one at a stage whose
  # gate was `none` in the process version the approval was recorded under.
  defp gate_none_approval?(%GateDecision{automatic: true}), do: true

  defp gate_none_approval?(%GateDecision{} = approval) do
    case Repo.get(Processes.Version, approval.process_version_id) do
      nil ->
        false

      version ->
        get_in(Processes.stage(version, approval.stage_id) || %{}, ["gate", "kind"]) == "none"
    end
  end

  # Whether an artifact with a version among `covered` now has a withdrawal as its newest
  # version (`Artifacts.withdrawn?/1`).
  defp withdrawn_since?(artifacts, covered) do
    Enum.any?(artifacts, fn artifact ->
      Artifacts.withdrawn?(artifact) and Enum.any?(artifact.versions, &(&1.public_id in covered))
    end)
  end

  defp last_approval(work_item, stage_id) do
    Repo.one(
      from d in GateDecision,
        where: d.work_item_id == ^work_item.id and d.stage_id == ^stage_id and d.kind == :approve,
        order_by: [desc: d.inserted_at],
        limit: 1
    )
  end

  # `track` is the track an approval or a move forward records, nil for the other kinds.
  # `to_stage_id` is the stage a move goes to, nil for the other kinds.
  defp decide(
         scope,
         work_item,
         version,
         stage,
         kind,
         covered,
         artifact_version_id,
         note,
         fields \\ []
       ) do
    %GateDecision{
      public_id: PublicId.generate(GateDecision.prefix()),
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      stage_id: stage["id"],
      process_version_id: version.id,
      user_id: scope.user.id,
      kind: kind,
      take_in: work_item.take_in,
      versions: covered,
      artifact_version_id: artifact_version_id,
      note: note,
      track: fields[:track],
      left_stage_entered_at: if(kind == :move, do: work_item.stage_entered_at),
      to_stage_id: fields[:to_stage_id],
      escalation_id: fields[:escalation_id],
      inserted_at: DateTime.utc_now()
    }
    |> PublicId.Insert.insert()
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

  # accepted/2 is the newest escalation of the work item at the stage `stage_id` that a
  # member accepted as it is: `%{by:, at:}`, the member's account id and when the member
  # accepted it; nil for none.
  @doc false
  @spec accepted(WorkItem.t(), String.t()) :: %{by: Ecto.UUID.t() | nil, at: DateTime.t()} | nil
  def accepted(%WorkItem{id: id}, stage_id) when is_binary(stage_id) do
    Repo.one(
      from e in Escalation,
        where: e.work_item_id == ^id and e.stage_id == ^stage_id and e.resolution == :accept,
        order_by: [desc: e.resolved_at],
        limit: 1,
        select: %{by: e.resolved_by_id, at: e.resolved_at}
    )
  end

  # accepted_findings/2 is each escalation of the work item at a stage of `stage_ids` that
  # it reached at the round limit and that a member accepted as it is in the current take in
  # (`resolved_at` at or after the work item's `taken_in_at`), oldest first:
  # `%{stage_id:, by:, at:, findings:}`, `by` the member's account id, `at` when the member
  # accepted it, and `findings` the `text` of each point of the verdict that the
  # escalation's run pushed last before the escalation, in the verdict's order, where that
  # verdict is `changes-requested`. A shared run pushes a verdict each round, so the newest
  # before the escalation is the one that reached the limit. `findings` is empty where that
  # verdict is missing, cannot be read, or is another verdict: a round limit reached by
  # failed checks after a `passed` verdict has no findings to accept.
  @doc false
  @spec accepted_findings(WorkItem.t(), [String.t()]) :: [
          %{
            stage_id: String.t(),
            by: Ecto.UUID.t() | nil,
            at: DateTime.t(),
            findings: [String.t()]
          }
        ]
  def accepted_findings(%WorkItem{id: id, taken_in_at: since}, stage_ids)
      when is_list(stage_ids) do
    query =
      from e in Escalation,
        where:
          e.work_item_id == ^id and e.stage_id in ^stage_ids and e.cause == :round_limit and
            e.resolution == :accept and not is_nil(e.resolved_at),
        order_by: [asc: e.resolved_at]

    accepts =
      if since,
        do: Repo.all(from e in query, where: e.resolved_at >= ^since),
        else: Repo.all(query)

    for escalation <- accepts do
      %{
        stage_id: escalation.stage_id,
        by: escalation.resolved_by_id,
        at: escalation.resolved_at,
        findings: findings(escalation)
      }
    end
  end

  defp findings(%Escalation{run_id: nil}), do: []

  defp findings(%Escalation{run_id: run_id, inserted_at: at}) do
    verdict =
      Repo.one(
        from v in Apiary.Artifacts.Version,
          join: a in assoc(v, :artifact),
          where: v.run_id == ^run_id and a.type == "verdict" and v.inserted_at <= ^at,
          order_by: [desc: v.inserted_at, desc: v.number],
          limit: 1,
          preload: [files: ^from(f in Apiary.Artifacts.ArtifactFile, order_by: f.filename)]
      )

    case verdict && Artifacts.stored_json(verdict) do
      {:ok, %{"verdict" => "changes-requested", "points" => points}} when is_list(points) ->
        for %{"text" => text} <- points, is_binary(text), do: text

      _none ->
        []
    end
  end

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
        PublicId.Insert.insert!(escalation)

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
      public_id: PublicId.generate(Escalation.prefix()),
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
      return_to: return_to(escalation, work_item, stage),
      inserted_at: escalation.inserted_at
    }
  end

  # The stage that the return key at the work item's entry is set to (choice 10), for an
  # escalation at the return limit, so Move back offers that stage first; nil otherwise.
  defp return_to(%Escalation{cause: :return_limit}, %WorkItem{stage_entry: entry}, stage)
       when is_integer(entry) do
    case Enum.at(stage["sequence"] || [], entry) do
      %{"return" => %{"stage" => stage_id}} -> stage_id
      _other -> nil
    end
  end

  defp return_to(_escalation, _work_item, _stage), do: nil

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
    do:
      (Cancel.dispatch_run_cancelled?(run) or not pushed_verdict?(run, artifacts)) and
        stopped?(run)

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

  # The newest version of each name of each output type made in the stage, in the
  # stage's order of types and `Artifacts.name_order/1` within a type: what an approval
  # at a gate `none` covers, so each scenario's film keeps its version beside the others.
  defp newest_outputs(stage, artifacts) do
    for output <- Map.get(stage, "outputs", []),
        {_name, version} <- newest_names(artifacts, output["type"], stage["id"]),
        do: version
  end

  # The version of each name of each output type of `stage` that its gate shows, in the
  # stage's order of types and `Artifacts.name_order/1` within a type (`gate_names/4`).
  # `approvals` is `approvals_by_version/1`.
  defp gate_versions(stage, artifacts, approvals) do
    for output <- Map.get(stage, "outputs", []),
        {_name, version} <- gate_names(artifacts, output["type"], stage["id"], approvals),
        do: version
  end

  # The version of each name of `type` that the gate of `stage_id` shows, as `{name,
  # version}` in `Artifacts.name_order/1`: the newest version of the name made in the
  # stage (`newest_names/3`), or a higher-numbered version of that artifact that a
  # person's approval lists or that is its change (`listed_higher/3`), which every later
  # run reads (`read_version/6`). So a person approves the text the runs use, also after a
  # move back (624 (a)).
  defp gate_names(artifacts, type, stage_id, approvals) do
    for {name, start} <- newest_names(artifacts, type, stage_id) do
      artifact = Enum.find(artifacts, &(&1.id == start.artifact_id))
      {name, listed_higher(artifact, start, approvals)}
    end
  end

  # The version of `type` that the gate shows for the output as a whole: that of the name
  # whose newest version made in the stage is the newest (`newest_made_in/3`), taken as
  # `gate_names/4` takes it.
  defp gate_version(artifacts, type, stage_id, approvals) do
    case newest_made_in(artifacts, type, stage_id) do
      nil ->
        nil

      start ->
        artifacts |> Enum.find(&(&1.id == start.artifact_id)) |> listed_higher(start, approvals)
    end
  end

  # The highest-numbered version of `artifact` above `start` that a person's approval lists
  # (`person_approval?/1`), or that is the artifact's change, which no approval lists yet
  # (`artifact_change/2`); else `start`. A withdrawal and a version by a run a member
  # cancelled are never taken.
  defp listed_higher(artifact, start, approvals) do
    change = artifact_change(artifact, listed(approvals))

    artifact.versions
    |> Enum.filter(fn v ->
      v.number > start.number and not v.withdrawn and not Artifacts.cancelled?(v) and
        ((change != nil and v.public_id == change.public_id) or
           Enum.any?(Map.get(approvals, v.public_id, []), &person_approval?/1))
    end)
    |> Enum.max_by(& &1.number, fn -> start end)
  end

  # Whether an approval of `approvals_by_version/1` is a person's: neither automatic nor at
  # a gate `none`, also where a member accepted the escalation that ended such a stage
  # (`approve_none!/4`).
  defp person_approval?(approval), do: not approval.automatic and not approval.gate_none

  # The versions an approval of `stage` records, in the order the gate shows them: the
  # versions its gate shows (`gate_versions/3`), then, with `changes?`, each version a
  # person's change made that no approval lists yet (`changed_versions/2`), as a person's
  # approval is the one that lists such a version (vault 0261, 624 (a)). An approval is
  # made only at the work item's stage, so only there are the changes the gate's. Of two
  # versions of one artifact, such as a run's version at the gate and a change after it,
  # the higher-numbered one is taken, in the place of the first.
  defp recorded_versions(stage, artifacts, approvals, changes?) do
    changed = if changes?, do: changed_versions(artifacts, listed(approvals)), else: []
    versions = gate_versions(stage, artifacts, approvals) ++ changed

    highest =
      versions
      |> Enum.group_by(& &1.artifact_id)
      |> Map.new(fn {id, of_artifact} -> {id, Enum.max_by(of_artifact, & &1.number)} end)

    versions |> Enum.uniq_by(& &1.artifact_id) |> Enum.map(&highest[&1.artifact_id])
  end

  # gate_frames/3 is the versions the work item page frames on the tab of the stage
  # `stage_id` of the process version `version`, the work item's
  # (`ApiaryWeb.WorkItemLive.StageTab.frames/1`), each with its artifact's type and name.
  # At the work item's stage, until its last stage is done, they are the versions an
  # approval would record now (`recorded_versions/4`, the set `approve_locked/7` lists).
  # At any other stage with a person's approval in this take in, they are the versions the
  # newest such approval recorded, in its order; with none, the versions its gate shows. []
  # for a stage the work item's process version does not have.
  @doc false
  @spec gate_frames(WorkItem.t(), Processes.Version.t(), String.t()) :: [
          %{type: String.t(), name: String.t(), version: Artifacts.Version.t()}
        ]
  def gate_frames(%WorkItem{} = work_item, %Processes.Version{} = version, stage_id)
      when is_binary(stage_id) do
    case Processes.stage(version, stage_id) do
      nil ->
        []

      stage ->
        artifacts = Artifacts.list(work_item)
        by_id = Map.new(artifacts, &{&1.id, &1})

        for version <- framed_versions(work_item, stage, artifacts) do
          %{
            type: by_id[version.artifact_id].type,
            name: by_id[version.artifact_id].name,
            version: version
          }
        end
    end
  end

  defp framed_versions(work_item, stage, artifacts) do
    here? = work_item.stage_id == stage["id"]

    approval =
      if not here? or work_item.stage_state == :done,
        do: last_person_approval(work_item, stage["id"])

    if approval do
      by_public_id = for a <- artifacts, v <- a.versions, into: %{}, do: {v.public_id, v}
      for id <- approval.versions, version = by_public_id[id], version != nil, do: version
    else
      recorded_versions(stage, artifacts, approvals_by_version(work_item), here?)
    end
  end

  # The newest approval of the stage `stage_id` in the work item's take in that a person
  # gave at the gate: not automatic, and at a gate that was not `none` in the process
  # version it was recorded under, as `approvals_by_version/1` reads it; nil for none.
  defp last_person_approval(%WorkItem{take_in: nil}, _stage_id), do: nil

  defp last_person_approval(work_item, stage_id) do
    Repo.one(
      from d in GateDecision,
        join: v in Processes.Version,
        on: v.id == d.process_version_id,
        where:
          d.work_item_id == ^work_item.id and d.stage_id == ^stage_id and d.kind == :approve and
            d.take_in == ^work_item.take_in and not d.automatic and
            not fragment(
              """
              COALESCE((SELECT s -> 'gate' ->> 'kind' = 'none'
                        FROM jsonb_array_elements(? -> 'stages') AS s
                        WHERE s ->> 'id' = ? LIMIT 1), false)
              """,
              v.document,
              d.stage_id
            ),
        order_by: [desc: d.inserted_at],
        limit: 1
    )
  end

  # The newest version of each name of `type` made in `stage_id`, as `newest_made_in/3`
  # takes one: `{name, version}`, in `Artifacts.name_order/1`.
  defp newest_names(artifacts, type, stage_id) do
    for artifact <- Enum.sort_by(artifacts, &Artifacts.name_order(&1.name)),
        artifact.type == type,
        version = newest_made_in([artifact], type, stage_id),
        version != nil,
        do: {artifact.name, version}
  end

  # A version a run a member cancelled wrote is never taken (`Artifacts.cancelled?/1`),
  # and neither is a withdrawal or a version of a withdrawn name (`Artifacts.withdrawn?/1`).
  defp newest_made_in(artifacts, type, stage_id, keep \\ fn _version -> true end) do
    artifacts
    |> Enum.filter(&(&1.type == type and not Artifacts.withdrawn?(&1)))
    |> Enum.flat_map(& &1.versions)
    |> Enum.filter(
      &(&1.stage_id == stage_id and not &1.withdrawn and not Artifacts.cancelled?(&1) and
          keep.(&1))
    )
    |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.number}, fn -> nil end)
  end

  # An output with a condition is required only while its condition does not hold it back
  # (`Runner.required?/2`), with `facts` as `condition_facts/6` reads them, read here for
  # nil. Each output's `version` is the one the gate shows (`gate_versions/3`).
  # `approvals` is `approvals_by_version/1`, read here for nil.
  defp outputs(work_item, version, stage, artifacts, facts \\ nil, approvals \\ nil) do
    approvals = approvals || approvals_by_version(work_item)
    facts = facts || condition_facts(work_item, version, stage, artifacts, true, approvals)

    for output <- Map.get(stage, "outputs", []) do
      type = output["type"]
      version = gate_version(artifacts, type, stage["id"], approvals)

      check =
        cond do
          reported?(output) -> :not_checked
          Artifacts.exists?(work_item, stage["id"], type) -> :passed
          true -> :missing
        end

      %{
        type: type,
        required: Runner.required?(output, facts),
        version: version && %{id: version.public_id, number: version.number},
        names:
          for(
            {name, named} <- gate_names(artifacts, type, stage["id"], approvals),
            do: %{name: name, id: named.public_id, number: named.number}
          ),
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
      {:ok, version, stage} ->
        missing(outputs(work_item, version, stage, Artifacts.list(work_item)))

      :not_placed ->
        []
    end
  end

  defp missing(outputs), do: for(%{required: true, check: :missing, type: t} <- outputs, do: t)

  # The required output types that Accept as it is requires: `missing`, where an accept
  # at the work item's place takes the stage to its gate (`Runner.accept_to_gate?/3`, on
  # `facts`); none where it starts the next entry, as the checks run at the sequence's
  # end. A work item with no place in the sequence, as the migration placed some, counts
  # as at its gate.
  defp accept_needs(_work_item, _stage, _facts, []), do: []

  defp accept_needs(work_item, stage, facts, missing) do
    case position(work_item) do
      nil -> missing
      position -> if Runner.accept_to_gate?(stage, position, facts), do: missing, else: []
    end
  end

  # accept_entry/5 is the name of the entry of the stage that an accept of the open
  # escalation `escalation` starts, else its workflow (`Runner.entry_name/2`), where the
  # accept does not take the stage to its gate (`Runner.accept_to_gate?/3`); else nil.
  # The entry is the one whose run the runner's step queues in the stage, after loops and
  # `when`/`unless` conditions, or whose workflow the stage then waits for
  # (`started_entry/2`). `read` is what `status/2` has read (`facts/4`): the gate test
  # reads only the condition facts, and the other facts are read only where the accept
  # does not go to the gate. The escalation card's accept button reads Start and this
  # entry (`ApiaryWeb.WorkItemLive.Workflow`).
  defp accept_entry(
         %WorkItem{stage_state: :escalated} = work_item,
         version,
         stage,
         %Escalation{cause: cause},
         read
       ) do
    with %{} = position <- position(work_item),
         false <- Runner.accept_to_gate?(stage, position, Keyword.fetch!(read, :conditions)) do
      facts = facts(work_item, version, stage, read)
      stage |> Runner.step(position, {:accept, cause}, facts) |> started_entry(stage)
    else
      _gate -> nil
    end
  end

  defp accept_entry(_work_item, _version, _stage, _escalation, _read), do: nil

  # The entry of `stage` that the runner's `outcome` of an accept starts: the entry of its
  # first `:queue`, where no `:advance` or `{:return, _}` comes first, as those enter
  # another stage; with none, the entry whose workflow the stage waits for
  # (`:waiting_workflow`), which the accept starts once the harness lists it. nil for
  # none.
  defp started_entry(%{actions: actions} = outcome, stage) do
    first =
      Enum.find(actions, fn action ->
        match?({:queue, _spec}, action) or action == :advance or
          match?({:return, _stage_id}, action)
      end)

    case {first, outcome} do
      {{:queue, spec}, _outcome} -> Runner.entry_name(stage, spec)
      {nil, %{state: :waiting_workflow, position: at}} -> Runner.entry_name(stage, at)
      _other -> nil
    end
  end

  # accept_starts/1 is what an accept of the work item's open escalation starts, read
  # once at the click, by the runner's rules on the facts read now: `entry`, the entry
  # whose name the accept button shows (`accept_entry/5`), nil where the accept takes the
  # stage to its gate; and `run`, the run it queues, as `starts/2` finds
  # it, from the same step. The spend dialog reads both, so its title, its button and its
  # line come from one step.
  @doc false
  @spec accept_starts(WorkItem.t()) :: %{entry: String.t() | nil, run: {:run, String.t()} | :none}
  def accept_starts(%WorkItem{id: id} = work_item) do
    with %WorkItem{state: :exploring, stage_state: :escalated} = work_item <-
           Repo.get(WorkItem, id),
         {:ok, version, stage} <- placed(work_item),
         %Escalation{cause: cause} <-
           open_escalation(work_item) || placed_escalation(work_item, version, stage),
         %{} = position <- position(work_item) do
      facts = facts(work_item, version, stage)

      if accept_needs(work_item, stage, facts, facts.failed_checks) == [] do
        outcome = Runner.step(stage, position, {:accept, cause}, facts)

        entry =
          if Runner.accept_to_gate?(stage, position, facts),
            do: nil,
            else: started_entry(outcome, stage)

        %{entry: entry, run: queued(work_item, version, stage, outcome.actions)}
      else
        %{entry: nil, run: :none}
      end
    else
      _other -> %{entry: nil, run: starts(work_item, :accept)}
    end
  end

  # A stage is approved only once every required output exists. The refusal is set by
  # who makes the outputs: people (a stage with no workflow, § 4) or the stage's runs.
  defp outputs_exist(work_item, version, stage) do
    case missing(outputs(work_item, version, stage, Artifacts.list(work_item))) do
      [] ->
        :ok

      types ->
        cond do
          Runner.people?(stage) ->
            {:error, {:outputs_missing, types}}

          to = changes_return(work_item, version, stage) ->
            {:error, {:outputs_not_written, types, to}}

          true ->
            {:error, {:outputs_not_written, types}}
        end
    end
  end

  # The name of the stage that Request changes at the gate returns the work item to
  # (`Runner.gate_return/2`, which `request_changes/5` reaches through `Runner.step/4`);
  # nil where it runs the stage again.
  defp changes_return(work_item, version, stage) do
    facts = facts(work_item, version, stage)

    case Runner.gate_return(stage, facts) do
      nil -> nil
      stage_id -> Map.get(facts.earlier, stage_id)
    end
  end

  # D6: a `reported` check is stored and not checked in this version.
  defp reported?(%{"check" => %{"reported" => _outcome}}), do: true
  defp reported?(_output), do: false

  # `required` is false for an input whose condition holds it back (`Runner.unmet/2`): the
  # stage does not wait for it. `facts` are those of `condition_facts/6`. `approvals` is
  # `approvals_by_version/1`.
  defp inputs(work_item, version, stage, artifacts, facts, approvals) do
    chosen =
      for input <- Map.get(stage, "inputs", []),
          do:
            {input, read_version(work_item, version, stage, artifacts, input["type"], approvals)}

    times = decision_times(work_item, for({_input, v} <- chosen, v != nil, do: v))

    for {input, version} <- chosen do
      %{
        type: input["type"],
        required: Runner.input_required?(input, facts),
        version: version && version_map(version, approvals, times)
      }
    end
  end

  # The version of `type` that `stage` reads, whether or not the stage lists it as an
  # input: a person's change to it that no approval lists yet (`changed_version/3`), else
  # the approved version:
  # what the gate of the nearest earlier stage that approved one approved, and what the
  # newest person's approval at this stage or a later one listed (`listed_later/4`). Of
  # those two, the higher-numbered where both are versions of one name, else the newer
  # version (`newest_listed/1`); nil for none. Where an approval lists several versions
  # of one artifact, as a person's approval that lists a change beside an older output
  # does, the read is the highest-numbered of them (`approved_version/3`). A withdrawn
  # name is never read (`Artifacts.withdrawn?/1`): neither a change nor an approved
  # version of it. `approvals` is `approvals_by_version/1`.
  defp read_version(work_item, version, stage, artifacts, type, approvals) do
    changed = changed_version(artifacts, type, listed(approvals))
    artifacts = Enum.reject(artifacts, &Artifacts.withdrawn?/1)

    by_id =
      for a <- artifacts, v <- a.versions, into: %{}, do: {v.public_id, {a.type, a.name, v}}

    earlier = earlier_stage_ids(version, stage)

    gated =
      Enum.find_value(earlier, fn stage_id ->
        case last_approval(work_item, stage_id) do
          %GateDecision{versions: covered} -> approved_version(covered, by_id, type)
          nil -> nil
        end
      end)

    later = listed_later(approvals, earlier, by_id, type)

    approved =
      newest_listed(for v <- [gated, later], v != nil, do: {elem(by_id[v.public_id], 1), v})

    changed || approved
  end

  # The version of `type` that the newest person's approval at a stage not in `earlier`
  # (this stage or a later one) listed, read from `approvals` (`approvals_by_version/1`), as
  # `approved_version/3` reads an approval; nil for none. Such a version is the approved
  # version for every run after that approval, after a move back too (624 (a)). An
  # approval at a gate `none` is no person's approval, also where a member accepted the
  # escalation that ended the stage (`approve_none!/4`). The approval's time tells one
  # approval from another: approvals of one work item are written under its lock.
  defp listed_later(approvals, earlier, by_id, type) do
    found =
      for {id, {^type, name, v}} <- by_id,
          approval <- Map.get(approvals, id, []),
          person_approval?(approval) and approval.stage_id not in earlier,
          do: {approval.inserted_at, {name, v}}

    case found do
      [] ->
        nil

      found ->
        at = found |> Enum.map(&elem(&1, 0)) |> Enum.max(DateTime)
        newest_listed(for {^at, pair} <- found, do: pair)
    end
  end

  # The version of `type` that an approval covering `covered` approved (`newest_listed/1`);
  # nil for none.
  defp approved_version(covered, by_id, type) do
    newest_listed(for id <- covered, {^type, name, v} <- [by_id[id]], do: {name, v})
  end

  # Of `{name, version}` pairs of one type: of each name, its highest-numbered version, and
  # of those the newest by time, as `changed_version/3` reads the changes; nil for none.
  defp newest_listed(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {_name, versions} -> Enum.max_by(versions, & &1.number) end)
    |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.number}, fn -> nil end)
  end

  # A person's change to an output (vault 0261, 624 (a)): a version that has a `decision`,
  # a person's note that contains the change asked for, in any stage, that no approval
  # lists (`listed`), and whose number is higher than that of every version of its
  # artifact that an approval lists. A push numbers its version under the work item's
  # lock, as an approval reads the versions it lists, so the numbers order the two where a
  # time taken before the lock would not. A version of a withdrawn name, a withdrawal and a
  # version by a run a member cancelled are never one. Nor is a version of the questions or
  # the review comments, which a person writes as an answer or a review comment
  # (`Artifacts.member_types/0`), not as a change.
  #
  # Each artifact's change is its highest-numbered one (`artifact_change/2`). The version of
  # `type` that every later run reads is the newest of those changes by time, across the
  # names of `type`; nil for none, and today's rule then applies (`read_version/6`).
  defp changed_version(artifacts, type, listed) do
    artifacts
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(&artifact_change(&1, listed))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.number}, fn -> nil end)
  end

  # The highest-numbered version of `artifact` that is a person's change
  # (`changed_version/3`), nil for none.
  defp artifact_change(artifact, listed) do
    artifact
    |> changes(listed)
    |> Enum.max_by(& &1.number, fn -> nil end)
  end

  # The versions of `artifact` that are a person's change (`changed_version/3`).
  defp changes(artifact, listed) do
    if artifact.type in Artifacts.member_types() or Artifacts.withdrawn?(artifact) do
      []
    else
      highest =
        artifact.versions
        |> Enum.filter(&MapSet.member?(listed, &1.public_id))
        |> Enum.map(& &1.number)
        |> Enum.max(fn -> 0 end)

      Enum.filter(artifact.versions, fn version ->
        is_binary(version.decision_id) and version.number > highest and not version.withdrawn and
          not Artifacts.cancelled?(version)
      end)
    end
  end

  # The change of each artifact (`artifact_change/2`), every name of a type included, in
  # the order of the types and then the names.
  defp changed_versions(artifacts, listed) do
    artifacts
    |> Enum.sort_by(&{&1.type, &1.name})
    |> Enum.map(&artifact_change(&1, listed))
    |> Enum.reject(&is_nil/1)
  end

  # The public ids of the versions that the approvals `approvals_by_version/1` returns list.
  defp listed(approvals), do: MapSet.new(Map.keys(approvals))

  # The input types of the conditions of `stage` that count: each whose version the stage
  # reads has a file of more than 0 bytes (`Runner.condition_inputs/1`).
  # `approvals` is `approvals_by_version/1`.
  defp counted(work_item, version, stage, artifacts, approvals) do
    for type <- Runner.condition_inputs(stage),
        read = read_version(work_item, version, stage, artifacts, type, approvals),
        read != nil and counts?(read),
        do: type
  end

  defp counts?(version), do: Enum.any?(version.files, &(&1.size > 0))

  # The facts of the conditions of `stage` (`Runner.facts/0`): the input types that count,
  # the track, and, for a stage whose workflow entry has a condition `{input: T, changed:
  # true}`, `stored` and `passed` (`changed_facts/7`), which a stage with none does not read.
  # A verdict whose file the store cannot read raises, as the runner's read of an end does,
  # unless `strict?` is false, as for a page: the run then does not count as passed.
  # `approvals` is `approvals_by_version/1`.
  defp condition_facts(work_item, version, stage, artifacts, strict?, approvals) do
    facts = %{
      counted: counted(work_item, version, stage, artifacts, approvals),
      track: track(work_item)
    }

    facts =
      if Runner.feedback_stage?(stage),
        do: Map.merge(facts, feedback_facts(work_item, stage, strict?)),
        else: facts

    case Runner.changed_inputs(stage) do
      [] ->
        facts

      types ->
        Map.merge(
          facts,
          changed_facts(work_item, version, stage, artifacts, types, strict?, approvals)
        )
    end
  end

  # feedback_facts/3 is, for the condition `{feedback: new}` (`Apiary.Stages.Runner`),
  # `feedback`: whether the work item has an open note (`open_notes/1`) that is feedback
  # (`feedback?/1`), or a run of its take in returned it to the stage (`returned_to`), and
  # no run handled it; `feedback_noted`: the same for feedback other than a plain answer;
  # and `feedback_comment`: the same for a review comment or a reply alone. A run of an
  # entry with `{feedback: new}` handles each such note or return older than its start
  # (`handled_at/5`). A plain answer, given while no escalation of the work item was
  # open, is the answer a run's question waited for: any run of the stage handles it.
  defp feedback_facts(work_item, stage, strict?) do
    handled = handled_at(work_item, stage, strict?, Runner.feedback_keys(stage), nil)

    unhandled =
      for note <- open_notes(work_item), feedback?(note), after?(note, handled), do: note

    returns =
      for at <- returned_at(work_item, stage), after?(%{inserted_at: at}, handled), do: at

    spans = escalation_spans(work_item)
    {plain, others} = Enum.split_with(unhandled, &plain_answer?(&1, spans))
    noted = others != [] or returns != []

    %{
      feedback: noted or unhandled_plain(work_item, stage, strict?, plain) != [],
      feedback_noted: noted,
      feedback_comment: Enum.any?(others, &(&1.kind == :answer and &1[:comment] == true))
    }
  end

  # When each run of the work item's take in returned it to `stage`.
  defp returned_at(%WorkItem{id: id, take_in: take_in}, stage) do
    Repo.all(
      from d in DispatchRun,
        where:
          d.work_item_id == ^id and d.take_in == ^take_in and d.returned_to == ^stage["id"] and
            not is_nil(d.returned_at),
        select: d.returned_at
    )
  end

  defp unhandled_plain(_work_item, _stage, _strict?, []), do: []

  defp unhandled_plain(work_item, stage, strict?, plain) do
    oldest = plain |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)
    handled = handled_at(work_item, stage, strict?, nil, oldest)
    Enum.filter(plain, &after?(&1, handled))
  end

  defp after?(_note, nil), do: true
  defp after?(note, handled), do: DateTime.after?(note.inserted_at, handled)

  # When each escalation of the work item was open: from its start to its resolution, nil
  # while it is open.
  defp escalation_spans(work_item) do
    Repo.all(
      from e in Escalation,
        where: e.work_item_id == ^work_item.id,
        select: {e.inserted_at, e.resolved_at}
    )
  end

  # An answer to a question, not a comment or a reply, given while no escalation was open.
  defp plain_answer?(%{kind: :answer} = note, spans) do
    note[:comment] != true and
      not Enum.any?(spans, fn {from, to} ->
        not DateTime.after?(from, note.inserted_at) and
          (is_nil(to) or not DateTime.before?(to, note.inserted_at))
      end)
  end

  defp plain_answer?(_note, _spans), do: false

  # The notes that are feedback: Request changes and a move with a note; an answer, a
  # review comment or a reply (kind `answer`), the comment of Run another round among
  # them; and the note of an escalation resolved otherwise than by an accept.
  defp feedback?(%{kind: kind, note: note}) when kind in [:request_changes, :move],
    do: is_binary(note) and String.trim(note) != ""

  defp feedback?(%{kind: :answer}), do: true
  defp feedback?(%{kind: :escalation, resolution: resolution}), do: resolution != :accept
  defp feedback?(_note), do: false

  # handled_at/5 is when the newest run that handled feedback started, nil for none: a run
  # of `stage` at the position of one of `keys` (`{entry, loop_entry, workflow}`, every
  # position for nil) that started after `since` (any time for nil) and ended with a
  # verdict `passed` or `changes-requested`. A run that stopped, escalated or gave no
  # verdict handled nothing. A run's start is when it was queued; in a run of a stage with
  # `shared_run: true`, each session counts separately, from when it started
  # (`handling_sessions/4`). A verdict whose file the store cannot read raises with
  # `strict?`, as `verdict!/1` does, and handles nothing without it. The runs and sessions
  # are read newest first, and the read stops at the first that handled feedback.
  defp handled_at(work_item, stage, strict?, keys, since) do
    sessions =
      Repo.all(
        from s in Session,
          join: d in DispatchRun,
          on: d.id == s.dispatch_run_id,
          where: d.work_item_id == ^work_item.id and d.stage_id == ^stage["id"],
          order_by: [s.dispatch_run_id, s.sequence],
          select: {d, s}
      )

    shared = MapSet.new(sessions, fn {run, _session} -> run.id end)

    ended =
      from d in DispatchRun,
        where:
          d.work_item_id == ^work_item.id and d.stage_id == ^stage["id"] and
            d.state == :ended and d.end_cause == :run_ended and
            not is_nil(d.stage_entry)

    runs =
      for run <- Repo.all(of_workflows(ended, keys)),
          not MapSet.member?(shared, run.id),
          at?({run.stage_entry, run.loop_entry, run.workflow}, keys),
          started_after?(run.queued_at, since),
          do: {run.queued_at, fn -> handled?(handled_verdict(run, strict?)) end}

    (runs ++ handling_sessions(sessions, keys, since, strict?))
    |> Enum.sort_by(&elem(&1, 0), {:desc, DateTime})
    |> Enum.find_value(fn {at, handled?} -> if handled?.(), do: at end)
  end

  defp of_workflows(query, nil), do: query

  defp of_workflows(query, keys) do
    workflows = Enum.map(keys, fn {_entry, _loop_entry, workflow} -> workflow end)
    from d in query, where: d.workflow in ^workflows
  end

  defp at?(_key, nil), do: true
  defp at?(key, keys), do: key in keys

  defp started_after?(_at, nil), do: true
  defp started_after?(at, since), do: DateTime.after?(at, since)

  # The sessions at a position of `keys`, after `since`, that stored a verdict: one newer
  # than the verdict the session before it saw (`verdict_number`). Each is its start and
  # a function that reads whether that verdict is `passed` or `changes-requested`, as the
  # step reads it (`session_verdict/2`).
  defp handling_sessions(sessions, keys, since, strict?) do
    sessions
    |> Enum.chunk_by(fn {run, _session} -> run.id end)
    |> Enum.flat_map(fn [{run, _first} | _rest] = chunk ->
      {found, _seen} =
        Enum.reduce(chunk, {[], nil}, fn {_run, session}, {found, seen} ->
          number = session.verdict_number
          key = {session.stage_entry, session.loop_entry, session.workflow}

          found =
            if not is_nil(session.response) and is_integer(number) and number != seen and
                 at?(key, keys) and started_after?(session.inserted_at, since),
               do: [
                 {session.inserted_at,
                  fn -> handled?(session_verdict_at(run, number, strict?)) end}
                 | found
               ],
               else: found

          {found, number || seen}
        end)

      found
    end)
  end

  defp handled?({:verdict, verdict, _points}), do: verdict in [:passed, :changes_requested]
  defp handled?(_result), do: false

  defp handled_verdict(run, true), do: verdict!(run)
  defp handled_verdict(run, false), do: reported_verdict(run)

  # The verdict of the version `number` of the verdict named `main` that `run` stored.
  defp session_verdict_at(run, number, strict?) do
    with %{} = version <- Artifacts.version_of_run(run, "verdict", "main", number) do
      case Artifacts.stored_json(version) do
        {:ok, document} ->
          document = document || %{}
          {:verdict, verdict(document["verdict"]), points(document["points"])}

        {:error, :store_unavailable} when strict? ->
          raise Apiary.Stages.VerdictUnreadable

        {:error, :store_unavailable} ->
          nil
      end
    end
  end

  # `stored`: for each type, the versions of it that a condition `{input: T, changed: true}`
  # reads: the version the stage reads (`read_version/6`, whatever the size of its files),
  # and each version that a run of the stage stored, so a version that an earlier entry of
  # the stage stored counts (triage-review's, for one). Each has when it was stored and the
  # place of the run that stored it (`Runner.stored_version/0`). `passed`: the runs of the
  # stage on the work item, in every take in, that ended `passed` as the runner reads the
  # end (`reported_verdict/1`), each with its place and when it was queued.
  defp changed_facts(work_item, version, stage, artifacts, types, strict?, approvals) do
    live = Enum.reject(artifacts, &Artifacts.withdrawn?/1)

    stored =
      for type <- types, into: %{} do
        read = read_version(work_item, version, stage, artifacts, type, approvals)

        made =
          for artifact <- live,
              artifact.type == type,
              v <- artifact.versions,
              v.writer == :run and v.stage_id == stage["id"] and not v.withdrawn and
                not Artifacts.cancelled?(v),
              do: %{at: v.inserted_at, by: run_place(v)}

        {type, if(read, do: [%{at: read.inserted_at, by: nil}], else: []) ++ made}
      end

    %{stored: stored, passed: passed_runs(work_item, stage, strict?)}
  end

  defp run_place(%{
         run: %DispatchRun{stage_entry: entry, loop_entry: loop_entry, workflow: workflow}
       })
       when is_integer(entry) and is_binary(workflow),
       do: {entry, loop_entry, workflow}

  defp run_place(_version), do: nil

  # The runs of `stage` on the work item that ended `passed`, as the runner reads the end:
  # a run that ended by its exit, which no member cancelled, whose newest verdict `main` says
  # `passed` (`reported_verdict/1`); a verdict whose file the store cannot read raises, as
  # `verdict!/1` does, with `strict?`, and is no pass without it. Only the runs of the
  # workflows of the entries that have a changed condition are read
  # (`Runner.changed_workflows/1`), each at its position in the stage.
  defp passed_runs(work_item, stage, strict?) do
    workflows = Runner.changed_workflows(stage)

    for run <-
          Repo.all(
            from d in DispatchRun,
              where:
                d.work_item_id == ^work_item.id and d.stage_id == ^stage["id"] and
                  d.state == :ended and d.end_cause == :run_ended and
                  not is_nil(d.stage_entry) and d.workflow in ^workflows,
              order_by: [d.queued_at, d.id]
          ),
        passed?(run, strict?) do
      %{
        entry: run.stage_entry,
        loop_entry: run.loop_entry,
        workflow: run.workflow,
        queued_at: run.queued_at
      }
    end
  end

  defp passed?(run, true), do: match?({:verdict, :passed, _points}, verdict!(run))
  defp passed?(run, false), do: match?({:verdict, :passed, _points}, reported_verdict(run))

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
        automatic: decision.automatic,
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
  defp shown_gaps(
         nil,
         %WorkItem{stage_state: :waiting_workflow} = work_item,
         stage,
         artifacts,
         facts
       ) do
    workspace = Repo.get!(Workspace, work_item.workspace_id)

    case {waiting_workflow(work_item, stage, facts), Processes.declared_snapshot(workspace)} do
      {workflow, %{read_at: read_at}} when is_binary(workflow) ->
        case Sources.chosen(workspace) do
          %{choice: :qory} -> not_in_qory(stage["name"], workflow)
          _repository -> not_listed(stage["name"], workflow, workspace.name, read_at)
        end

      _none ->
        gaps(nil, work_item, stage, artifacts)
    end
  end

  defp shown_gaps(escalation, work_item, stage, artifacts, _facts),
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

  # The first undeclared workflow of the stage whose condition is met, with `facts`.
  defp waiting_workflow(%WorkItem{stage_state: :waiting_workflow} = work_item, stage, facts) do
    workspace = Repo.get!(Workspace, work_item.workspace_id)

    declarations =
      Map.new(
        Runner.workflows_met(stage, facts),
        &{&1, Processes.workflow_declaration(workspace, &1)}
      )

    workspace |> undeclared(declarations) |> List.first()
  end

  defp waiting_workflow(_work_item, _stage, _facts), do: nil

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
