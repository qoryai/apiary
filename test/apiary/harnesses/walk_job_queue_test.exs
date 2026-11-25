defmodule Apiary.Harnesses.WalkJobQueueTest do
  # A run of the step `workflow` with no workflow ends when it is queued
  # (`Apiary.Harnesses.WalkJob.queue/2`): `harness_unresolved`, with the cause as the code
  # of its failed walk and as its end detail, no job, its record failed, and the words of
  # the cause. The run contract requires a workflow for every run of the step `workflow`,
  # so no claim takes such a run. The features are the whole node's, so the module is not
  # async.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Stacks, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{RunHarness, WalkJob}
  alias Apiary.Runs.Run
  alias Apiary.Stages.StopCause
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory
  @moduletag :capture_log

  setup do
    %{scope: sign_up_fixture().scope}
  end

  defp queue!(work_item) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  # The run ended when it was queued, with `code`, and its words are `words`.
  defp assert_ended!(%DispatchRun{id: id}, work_item, code, words) do
    run = Repo.get!(DispatchRun, id)

    assert %DispatchRun{
             state: :ended,
             end_cause: :harness_unresolved,
             end_detail: ^code,
             result_outcome: :error
           } = run

    assert %RunHarness{state: :failed, origin: nil, failure: ^code, attempts: 0} =
             Repo.get_by!(RunHarness, dispatch_run_id: id)

    refute_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => id})

    assert %Run{state: "failed", reason: "harness_unresolved"} =
             Repo.get_by!(Run, dispatch_run_id: id)

    assert StopCause.text(run, Repo.get!(WorkItem, work_item.id)) == words
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "more than one stack with a workflow: many_stacks", %{scope: scope} do
    for workflow <- ["triage", "review"] do
      {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, workflow}, nil)
    end

    work_item = work_item_fixture(scope)
    {run, log} = ExUnit.CaptureLog.with_log(fn -> queue!(work_item) end)

    # The instance's log line states the end at the queue, not a failed walk.
    assert log =~ "a run with no workflow ended at the queue end_cause=harness_unresolved"
    assert log =~ "failure=many_stacks"
    refute log =~ "a harness walk failed"

    assert_ended!(
      run,
      work_item,
      "many_stacks",
      "No workflow to start: more than one stack has a workflow. Keep the workflow in one stack."
    )
  end

  @tag with_features: Apiary.Features.all()
  test "with the workflow model, a run the stage runner did not queue and no stack with a workflow: no_stage_run",
       %{scope: scope} do
    work_item = work_item_fixture(scope)
    first = queue!(work_item)

    # The first run ended, and the work item is one the stage runner did not place, so
    # its next run has no stage entry.
    Repo.update_all(from(r in DispatchRun, where: r.id == ^first.id),
      set: [state: :ended, end_cause: :lost, of: 3]
    )

    Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
      set: [process_version_id: nil, stage_id: nil, stage_state: nil]
    )

    {:ok, next} =
      Repo.transact(fn -> Dispatches.queue_next(Repo.get!(WorkItem, work_item.id), 1) end)

    assert next.stage_id == nil

    assert_ended!(
      next,
      work_item,
      "no_stage_run",
      "No workflow to start: no stage started this run, and no stack has a workflow. Add a workflow to a stack, or start the work item from a stage."
    )
  end

  # The callers of the queue tell the work item once their transaction commits: nothing
  # is sent on the work items topic from inside it, so a rollback leaves no message there
  # about an end that never was.
  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "a run that ends at the queue sends nothing on the work items topic before its transaction commits",
       %{scope: scope} do
    for workflow <- ["triage", "review"] do
      {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, workflow}, nil)
    end

    work_item = work_item_fixture(scope)
    :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(work_item.workspace_id))

    assert {:error, :rolled_back} =
             Repo.transact(fn ->
               {:ok, run} = Dispatches.queue(work_item, 1)
               assert %DispatchRun{state: :ended, end_detail: "many_stacks"} = run
               refute_received {:work_items_changed, _ids}
               {:error, :rolled_back}
             end)

    refute_received {:work_items_changed, _ids}
    refute Repo.exists?(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
  end

  # A run with no stage, of a work item in a running stage, ends at the queue: the
  # stage acts on that end in the same transaction (`Apiary.Stages.run_ended_or_later/2`)
  # and stops with the cause's words. It queues no run, so no run ends at the queue again.
  @tag with_features: Apiary.Features.all()
  test "with the workflow model, a stage whose run ends at the queue stops and queues no run",
       %{scope: scope} do
    work_item = work_item_fixture(scope)
    first = queue!(work_item)
    assert %WorkItem{stage_state: :running} = Repo.get!(WorkItem, work_item.id)

    # The first run ended lost, with no stage, as a run queued before the workflow model
    # was on, and no stack has a workflow.
    Repo.update_all(from(r in DispatchRun, where: r.id == ^first.id),
      set: [
        state: :ended,
        end_cause: :lost,
        process_version_id: nil,
        stage_id: nil,
        round: nil,
        stage_entry: nil,
        loop_entry: nil,
        workflow: nil
      ]
    )

    Repo.delete_all(
      from s in Stacks.Stack,
        where: s.workspace_id == ^scope.workspace.id and not is_nil(s.workflow)
    )

    {:ok, next} =
      Repo.transact(fn ->
        :ok = Apiary.Stages.hold_work_item(first.id)
        Dispatches.requeue_for_image(Repo.get!(DispatchRun, first.id))
      end)

    words =
      "No workflow to start: no stage started this run, and no stack has a workflow. Add a workflow to a stack, or start the work item from a stage."

    assert next.stage_id == nil
    assert_ended!(next, work_item, "no_stage_run", words)

    assert [first.id, next.id] ==
             Repo.all(
               from r in DispatchRun,
                 where: r.work_item_id == ^work_item.id,
                 order_by: r.attempt,
                 select: r.id
             )

    assert %WorkItem{stage_state: :escalated} = Repo.get!(WorkItem, work_item.id)

    assert %Apiary.Stages.Escalation{cause: :run_stopped, points: [%{"text" => ^words}]} =
             Repo.get_by!(Apiary.Stages.Escalation, work_item_id: work_item.id)
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "a process whose first stage has no workflow: no_first_workflow", %{scope: scope} do
    version = Apiary.Processes.current(scope.workspace)
    [first | rest] = version.document["stages"]
    document = Map.put(version.document, "stages", [Map.put(first, "sequence", []) | rest])

    {1, _rows} =
      Repo.update_all(from(v in Apiary.Processes.Version, where: v.id == ^version.id),
        set: [document: document]
      )

    work_item = work_item_fixture(scope)

    assert_ended!(
      queue!(work_item),
      work_item,
      "no_first_workflow",
      "No workflow to start: the first stage of the process has no workflow. Add a workflow to that stage."
    )
  end

  # A work item taken in while the workflow model was off is in no stage once the model
  # is on, and its next run has no stage entry.
  @tag with_features: Apiary.Features.all()
  test "with the workflow model, the next run of a work item in no stage, after an answer, with no stack with a workflow: no_stage_run",
       %{scope: scope} do
    work_item = work_item_fixture(scope)
    %{dispatch_run: asked} = explore_run_fixture(work_item, result: questions_result())
    assert asked.stage_id == nil

    Repo.delete_all(
      from s in Stacks.Stack,
        where: s.workspace_id == ^scope.workspace.id and not is_nil(s.workflow)
    )

    :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(work_item.workspace_id))
    answers = %{"1" => "The small one.", "2" => "The spring sale."}
    {:ok, _} = WorkItems.answer(scope, Repo.get!(WorkItem, work_item.id), 1, answers)

    # The answer sends the work item's public id on the work items topic.
    public_id = work_item.public_id
    assert_received {:work_items_changed, [^public_id]}

    next =
      Repo.one!(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id and r.attempt == 2
      )

    assert_ended!(
      next,
      work_item,
      "no_stage_run",
      "No workflow to start: no stage started this run, and no stack has a workflow. Add a workflow to a stack, or start the work item from a stage."
    )
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "no process version: no_process", %{scope: scope} do
    Repo.delete_all(
      from v in Apiary.Processes.Version, where: v.workspace_id == ^scope.workspace.id
    )

    work_item = work_item_fixture(scope)

    assert_ended!(
      queue!(work_item),
      work_item,
      "no_process",
      "No workflow to start: the workspace has no process. Set up a process for the workspace."
    )
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "one stack with a workflow: the run waits for its walk", %{scope: scope} do
    {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, "triage"}, nil)
    run = queue!(work_item_fixture(scope))

    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, run.id)

    assert %RunHarness{state: :pending, workflow: "triage"} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
  end
end
