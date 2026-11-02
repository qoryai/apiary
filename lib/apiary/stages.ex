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

  alias Apiary.{Access, Audit, Dispatches, Features, Processes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run
  alias Apiary.Stacks.Sources
  alias Apiary.Stages.{Artifacts, Check, Escalation, GateDecision, Runner, StopCause}
  alias Apiary.WorkItems.{Explore, Moves, Proposal, WorkItem}

  # The runs a workflow outside a loop may have in one round of its entry: its first,
  # and one after each set of answers, as today's Explore has in one take in.
  @question_runs 3
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
  # `{:ok, run}`, nil when the stage waits.
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
  # caller's transaction: after answers, the same workflow; after an escalation or a run
  # that stopped, another round. `{:ok, run}`; `{:error, :not_waiting}` when the stage
  # waits for a workflow; `:not_placed` for a work item the runner did not place.
  @doc false
  @spec next_run(Ecto.UUID.t(), pos_integer) ::
          {:ok, DispatchRun.t()} | {:error, :not_waiting} | :not_placed
  def next_run(id, take_in) when is_binary(id) and is_integer(take_in) do
    in_transaction!()
    work_item = %{lock!(id) | take_in: take_in}

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
         {:ok, result} <- run_result(work_item, run, context) do
      {work_item, _run} = apply_event(work_item, version, stage, {:run, result}, run.id)
      told(work_item)
    else
      _other -> []
    end
  end

  # claim_ended/1 acts on the end of each run of the queue in `dispatch_run_ids`, which a
  # claim ended before they started, once the claim committed: each in a transaction that
  # locks its work item, then the run (`run_ended/1`). A failure is logged, and the run's
  # work item stays as it was. The work items to tell (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec claim_ended([Ecto.UUID.t()], StopCause.context()) :: [Apiary.Dispatches.Settle.told()]
  def claim_ended(dispatch_run_ids, context \\ %{}) when is_list(dispatch_run_ids),
    do: Enum.flat_map(dispatch_run_ids, &claim_ended_one(&1, context))

  defp claim_ended_one(id, context) do
    {:ok, told} =
      Repo.transact(fn ->
        :ok = hold_work_item(id)
        {:ok, run_ended(id, context)}
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
  # queue `run` (`Apiary.Stages.Runner.limits/3`), read at its claim without a lock, with
  # the harness's declaration of its workflow as the claim reads it; nil for a run the
  # stage runner did not queue, or with the workflow model off.
  @doc false
  @spec limits(DispatchRun.t()) ::
          %{time_limit: pos_integer | nil, access: :read | :write | nil} | nil
  def limits(%DispatchRun{stage_id: stage_id, process_version_id: version_id} = run)
      when is_binary(stage_id) and is_binary(version_id) do
    with true <- on?(),
         %Processes.Version{} = version <- Repo.get(Processes.Version, version_id),
         %{} = stage <- Processes.stage(version, stage_id) do
      workspace = Repo.get!(Workspace, run.workspace_id)
      declaration = run.workflow && Processes.workflow_declaration(workspace, run.workflow)
      position = %{entry: run.stage_entry, loop_entry: run.loop_entry, round: run.round}
      Runner.limits(stage, position, declaration)
    else
      _none -> nil
    end
  end

  def limits(%DispatchRun{}), do: nil

  # run_workflow/1 is the workflow a run of a stage starts, its `workflow`, with the
  # workflow model on: the name its harness walk, its documents, its time limits and its
  # model choice are read by. nil for a run the stage runner did not queue, or with the
  # workflow model off, which keep the workflow the Workflow page saved
  # (`Apiary.Stacks.workflow/2`).
  #
  # Transition, as D1: nil for `explore_workflow/0` too. Explore v1 runs exactly as today's
  # Explore run, by the Workflow page's saved workflow, until the harness change.
  @doc false
  @spec run_workflow(DispatchRun.t()) :: String.t() | nil
  def run_workflow(%DispatchRun{stage_id: stage_id, workflow: workflow})
      when is_binary(stage_id) and is_binary(workflow),
      do: if(workflow != explore_workflow() and on?(), do: workflow)

  def run_workflow(%DispatchRun{}), do: nil

  # Transition (D1): explore_workflow/0 is the workflow whose runs return today's explore
  # v1 result: the first workflow of the default process that the Qory harness lists, in
  # stage order. Nil for none, and then no stage is Explore.
  @doc false
  @spec explore_workflow() :: String.t() | nil
  def explore_workflow do
    listed = Processes.qory_workflows()

    Processes.default_document("software")["stages"]
    |> Enum.flat_map(&Runner.workflows/1)
    |> Enum.find(&(&1 in listed))
  end

  # confirmed/3 approves Explore's gate for the work item whose proposal the scope's
  # person confirmed in this transaction (`Apiary.WorkItems.confirm/4`), which passes
  # the stage of the confirmed run as `expect_stage` (`confirmed_stage_id/2`). A confirmation
  # with changes first stores the person's `proposal` version.
  @doc false
  @spec confirmed(Scope.t(), WorkItem.t(), expect) :: {:ok, WorkItem.t()} | {:error, term}
  def confirmed(%Scope{} = scope, %WorkItem{id: id}, opts \\ []) do
    in_transaction!()
    work_item = lock!(id)

    with {:ok, version, stage} <- placed(work_item),
         :ok <- expected(work_item, opts),
         :at_gate <- work_item.stage_state do
      confirmation = Explore.confirmation(work_item.id, work_item.take_in)

      with :ok <- if(may_approve?(scope, stage), do: :ok, else: {:error, :not_approver}),
           :ok <- person_proposal(scope, work_item, stage, confirmation),
           {:ok, work_item} <- approve_locked(scope, work_item, version, stage, nil, false) do
        tell_now(work_item)
        {:ok, work_item}
      end
    else
      {:error, :stage_changed} = refused -> refused
      _not_at_gate -> {:ok, work_item}
    end
  end

  # explore_again/3 runs `again`, today's Explore again (`Apiary.WorkItems.Moves`), inside
  # one transaction. Where the work item's stage is escalated, Explore again resolves the
  # escalation as another round, so it is the same act as `resolve_escalation/5`: the
  # scope's person needs `gate.approve` and a place among the stage's approvers, else
  # nothing runs; the escalation then has the person as `resolved_by`, and the trail a
  # `gate.approve` entry. Without an open escalation, `again` runs as it is.
  @doc false
  @spec explore_again(Scope.t(), WorkItem.t(), (-> {:ok, WorkItem.t()} | {:error, term})) ::
          {:ok, WorkItem.t()} | {:error, term}
  def explore_again(%Scope{} = scope, %WorkItem{id: id} = work_item, again) do
    transact(fn ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> explore_again_locked(scope, work_item, lock_open(uuid), again)
        :error -> again.()
      end
    end)
  end

  defp lock_open(id) do
    case Repo.get(WorkItem, id) do
      %WorkItem{} -> open_escalation(lock!(id))
      nil -> nil
    end
  end

  defp explore_again_locked(_scope, _work_item, nil, again), do: again.()

  defp explore_again_locked(scope, work_item, %Escalation{} = escalation, again) do
    expect = [expect_stage: escalation.stage_id]

    with {:ok, _work_item, _version, _stage} <- hold(scope, work_item, expect),
         {:ok, work_item} <- again.(),
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

  # answers_used_up/2 escalates the stage of the work item, `round_limit`, with the
  # newest run's questions as the gaps, when it waits for answers to a run that was the
  # last its take in may have, as a work item the migration placed may (the answer to it
  # is refused `:used_up`, `Apiary.WorkItems.Moves`): `{:ok, work_item}`. `refused`
  # otherwise, also for a work item that is no longer `:exploring`: the answer's
  # transaction ended, and a person may have closed the work item since.
  @doc false
  @spec answers_used_up(WorkItem.t(), {:error, term}) :: {:ok, WorkItem.t()} | {:error, term}
  def answers_used_up(%WorkItem{id: id}, refused) do
    transact(fn ->
      work_item = lock!(id)

      with :exploring <- work_item.state,
           {:ok, version, stage} <- placed(work_item),
           :waiting_answers <- work_item.stage_state do
        run = newest_of_take_in(work_item)
        questions = Enum.join(List.wrap(((run && run.result) || %{})["questions"]), "\n")

        position =
          position(work_item) ||
            %{entry: 0, loop_entry: nil, round: max(work_item.stage_round || 1, 1)}

        outcome = %{
          state: :escalated,
          position: position,
          actions: [{:escalate, :round_limit, questions}]
        }

        {work_item, _run} = apply_outcome(work_item, version, stage, outcome, run && run.id)
        tell_now(work_item)
        {:ok, work_item}
      else
        _other -> refused
      end
    end)
  end

  defp newest_of_take_in(work_item) do
    Repo.one(
      from d in DispatchRun,
        where: d.work_item_id == ^work_item.id and d.take_in == ^work_item.take_in,
        order_by: [desc: d.attempt],
        limit: 1
    )
  end

  # confirmed_stage_id/2 is the stage whose proposal a confirmation of the run `attempt`
  # of the work item's take in confirms: the stage that run ran in, or, for a run with no
  # stage, the stage that runs `explore_workflow/0` (`explore_stage_id/1`).
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

  # explore_stage_id/1 is the id of the stage of the work item's process version that runs
  # `explore_workflow/0`; nil for none.
  @doc false
  @spec explore_stage_id(WorkItem.t()) :: String.t() | nil
  def explore_stage_id(%WorkItem{} = work_item) do
    case Processes.version_for(work_item) do
      %{document: %{"stages" => stages}} ->
        explore = explore_workflow()
        Enum.find_value(stages, &(explore in Runner.workflows(&1) && &1["id"]))

      _none ->
        nil
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
  # (`Apiary.Artifacts.push/5`, `{:person, scope}`), with the `stage_id` of the stage the
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
          cond do
            work_item.state != :exploring ->
              {:ok, work_item}

            work_item.stage_state == :waiting_inputs ->
              {work_item, _run} = apply_event(work_item, version, stage, :resume)
              {:ok, work_item}

            work_item.stage_state == :at_gate and Runner.people?(stage) ->
              {work_item, _run} = apply_event(work_item, version, stage, :version_added)
              {:ok, work_item}

            true ->
              {:ok, work_item}
          end

        :not_placed ->
          {:error, :not_placed}
      end
    end)
  end

  # check_workflows/2 reads the workflow names the workspace's harness lists now, as the
  # scope's person, through the harness sources (`Apiary.Stacks.Sources`), stores them as
  # the workspace's snapshot, and starts the work item's stage when it waits for a
  # workflow the read found: `{:ok, work_item}`; `{:error, :still_missing}` when the
  # stage still waits; `{:error, :not_live}` for a work item that is not `:exploring`, read
  # under its lock; the read's error otherwise. `read` is the read, given only by tests.
  @doc false
  @spec check_workflows(Scope.t(), WorkItem.t(), (Scope.t(), Workspace.t() -> term)) ::
          {:ok, WorkItem.t()} | {:error, term}
  def check_workflows(%Scope{} = scope, %WorkItem{id: id}, read \\ &Sources.chosen_workflows/2) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} <- in_workspace(workspace, id) || {:error, :not_found},
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
        cond do
          work_item.stage_state != :waiting_workflow ->
            {:ok, work_item}

          facts(work_item, version, stage).undeclared != [] ->
            {:error, :still_missing}

          true ->
            {work_item, _run} = apply_event(work_item, version, stage, :resume)
            {:ok, work_item}
        end
      else
        :not_placed -> {:error, :not_placed}
        {:error, :not_live} = refused -> refused
      end
    end)
  end

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
  # that runs `explore_workflow/0`: the gate approves what a member confirms, so the two are
  # one act. The gate of any other stage confirms nothing.
  defp confirm_explore(scope, work_item, stage) do
    if explore_workflow() in Runner.workflows(stage),
      do: confirm_today(scope, work_item),
      else: {:ok, false}
  end

  defp confirm_today(scope, work_item) do
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
  # close it or decline it.
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

  ## Reading

  # status/2 is where the work item stands in its stage, as the work item page draws it;
  # nil for a work item the runner has not placed. `scope` decides whether its person may
  # approve the gate; with none, `approvable?` is false. `missing_outputs` is the
  # required output types whose Exists check fails (`missing_outputs/1`); while it has
  # one, the gate of a stage with no workflow is not approvable. `loop` is whether the
  # work item is in a loop of its stage: `rounds` is that loop's limit, or, past the last
  # loop, the limit of the loop it left, which a later entry's runs do not count by.
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
        escalation: escalation_map(escalation),
        waiting_workflow: waiting_workflow(work_item, stage),
        gate: %{
          kind: get_in(stage, ["gate", "kind"]) || "person",
          approvers: approvers(stage),
          approvable?:
            state == :at_gate and may_approve?(scope, stage) and
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
  # queue: waiting, claimed, handed_over or ended), `verdict` from its verdict artifact
  # (`:passed`; `:failed` for changes-requested or escalate; nil for none), and when it
  # started and ended, nil for not yet.
  @doc false
  @spec runs(WorkItem.t()) :: [map]
  def runs(%WorkItem{id: id} = work_item) do
    verdicts = run_verdicts(work_item)

    Repo.all(
      from d in DispatchRun,
        left_join: r in Run,
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
        verdict: verdicts[dispatch_run.id] || (run && verdicts[run.id]),
        started_at: run && run.started_at,
        ended_at: ended_at(dispatch_run, run)
      }
    end)
  end

  defp ended_at(%DispatchRun{state: :ended}, %Run{exited_at: %DateTime{} = at}), do: at
  defp ended_at(%DispatchRun{state: :ended, updated_at: at}, _run), do: at
  defp ended_at(_dispatch_run, _run), do: nil

  # The verdict of each run that stored one, by the run's id: the newest of its versions.
  defp run_verdicts(work_item) do
    for artifact <- Artifacts.list(work_item),
        artifact.type == "verdict",
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
  # (`:check`, with no person).
  @doc false
  @spec notes(WorkItem.t()) :: [map]
  def notes(%WorkItem{id: id}) do
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

    answers =
      Repo.all(
        from a in Apiary.WorkItems.Answer,
          left_join: r in DispatchRun,
          on:
            r.work_item_id == a.work_item_id and r.take_in == a.take_in and
              r.attempt == a.attempt,
          where: a.work_item_id == ^id and not is_nil(a.answered_at) and not is_nil(a.answer),
          order_by: [a.take_in, a.attempt, a.position],
          select: %{
            kind: :answer,
            stage_id: r.stage_id,
            user_id: a.answered_by_id,
            note: a.answer,
            artifact_version_id: nil,
            inserted_at: a.answered_at
          }
      )

    Enum.sort_by(decisions ++ escalations ++ checks ++ answers, & &1.inserted_at, DateTime)
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

  defp apply_event(work_item, version, stage, event, run_id \\ nil) do
    facts = work_item |> facts(version, stage) |> Map.put(:last_attempt, last_attempt?(run_id))
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
      undeclared: undeclared(workspace, declarations),
      declarations: declarations,
      failed_checks: missing(outputs(work_item, stage, artifacts)),
      machine: version.document["machine"]
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

  # Whether the run `run_id` is the last its take in may have (`attempt` reached `of`).
  defp last_attempt?(nil), do: false

  defp last_attempt?(run_id) do
    Repo.one(from d in DispatchRun, where: d.id == ^run_id, select: d.attempt >= d.of) || false
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
        machine_type: spec.machine_type
      }
    })
  end

  # The runs queued before for the entry of `spec`, in its round, in the take in.
  defp runs_of_entry(work_item, stage, spec) do
    Repo.aggregate(
      from(d in DispatchRun,
        where: d.work_item_id == ^work_item.id and d.take_in == ^work_item.take_in,
        where: d.stage_id == ^stage["id"] and d.stage_entry == ^spec.entry,
        where: d.round == ^spec.round
      ),
      :count
    )
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
  defp run_result(_work_item, %DispatchRun{end_cause: :run_ended, result_outcome: nil}, _ctx),
    do: :unsettled

  defp run_result(_work_item, %DispatchRun{end_cause: cause}, _context)
       when cause in [:closed, :undone, :released, :superseded],
       do: :ignored

  defp run_result(work_item, %DispatchRun{} = run, context) do
    cond do
      explore_run?(run) -> {:ok, explore_result(work_item, run, context)}
      run.end_cause == :run_ended -> {:ok, reported_result(work_item, run)}
      true -> {:ok, {:stopped, stop_cause(run, work_item, context)}}
    end
  end

  defp explore_run?(%DispatchRun{step: "explore", workflow: workflow}),
    do: is_nil(workflow) or workflow == explore_workflow()

  defp explore_run?(%DispatchRun{}), do: false

  # D1: today's explore v1 result as artifacts.
  defp explore_result(
         work_item,
         %DispatchRun{end_cause: :run_ended, result_outcome: :proposal} = run,
         _context
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
         %DispatchRun{end_cause: :run_ended, result_outcome: :questions} = run,
         _context
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

  defp explore_result(work_item, run, context),
    do: {:stopped, stop_cause(run, work_item, context)}

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
        {:stopped, stop_cause(run, work_item)}

      true ->
        {:verdict, nil, nil}
    end
  end

  defp verdict("passed"), do: :passed
  defp verdict("changes-requested"), do: :changes_requested
  defp verdict("escalate"), do: :escalate
  defp verdict(_none), do: nil

  # Why a run ended before it started, by its end cause (`Apiary.Dispatches.DispatchRun`),
  # the end of the sentence `stop_cause/1` shows.
  # stop_cause/3 is why `run` stopped, as an escalation shows it (`StopCause.text/3`).
  @doc false
  @spec stop_cause(DispatchRun.t(), WorkItem.t(), StopCause.context()) :: String.t()
  def stop_cause(run, work_item, context \\ %{}), do: StopCause.text(run, work_item, context)

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
  defp hold(scope, %WorkItem{id: id}, opts) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id),
         :ok <- Access.authorize(scope, @action, found),
         work_item = lock!(found.id),
         :ok <- expected(work_item, opts),
         :ok <- live(work_item),
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

  defp approvers(stage) do
    case get_in(stage, ["gate", "approvers"]) do
      %{"members" => members} when is_list(members) -> members
      _members -> :members
    end
  end

  defp may_approve?(nil, _stage), do: false

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
      build_run: build_run(run, escalation),
      set_up_step: StopCause.set_up_step(run),
      inserted_at: escalation.inserted_at
    }
  end

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

  # A stage that waits for a workflow shows why; any other, its gaps.
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
  # read: its workflows are fixed (`Apiary.Processes.qory_workflows/0`).
  @doc false
  @spec not_in_qory(String.t(), String.t()) :: String.t()
  def not_in_qory(stage, workflow) do
    "#{stage} uses #{workflow}, which the Qory harness does not list. " <>
      "Choose another workflow for #{stage}, or choose a harness that lists #{workflow} " <>
      "under workflows on the Workflow page."
  end

  defp gaps(%Escalation{gaps: gaps}, _work_item, _stage, _artifacts), do: gaps

  # With no escalation, the newer of the failed checks that started the round and the
  # stage's newest verdict.
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

    cond do
      check &&
          (is_nil(verdict) or DateTime.compare(check.inserted_at, verdict.inserted_at) == :gt) ->
        check.gaps

      verdict ->
        text((Artifacts.read_json(verdict) || %{})["gaps"])

      true ->
        nil
    end
  end

  defp text(text) when is_binary(text), do: text
  defp text(_other), do: nil

  defp waiting_workflow(%WorkItem{stage_state: :waiting_workflow} = work_item, stage) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}

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
