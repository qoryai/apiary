defmodule Apiary.Stages.FeatureOffTest do
  # Without `workflow_model`, Explore runs with no stage runner: a take in queues run 1 of
  # 3 with no place in a process, and a run's end opens no escalation. The run API answers
  # 404, so a run pushes no proposal and no questions, and every run ends with no result.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Artifacts, Repo, Stacks, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{RunHarness, WalkJob}
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Confirmation, WorkItem}

  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]

  setup do
    %{scope: sign_up_fixture().scope}
  end

  # The take in, the walk's queue and the dialog's line read no process version, so a
  # workspace with none gets none. With no row and no version, the run has no workflow,
  # so it ends when it is queued (`Apiary.Harnesses.WalkJob.queue/2`).
  test "a take in inserts no process version in a workspace with none", %{scope: scope} do
    versions = from(v in Apiary.Processes.Version, where: v.workspace_id == ^scope.workspace.id)
    Repo.delete_all(versions)
    ticket = Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)

    assert Stages.take_in_starts(scope.workspace, ticket.public_id) == {:run, nil}
    assert {:ok, %WorkItem{} = work_item} = WorkItems.take_in(scope, ticket.public_id)
    assert Repo.aggregate(versions, :count) == 0
    run = newest_run(work_item)

    assert %RunHarness{state: :failed, origin: nil, workflow: nil, failure: "no_process"} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert %DispatchRun{state: :ended, end_cause: :harness_unresolved} =
             Repo.get!(DispatchRun, run.id)

    refute_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
  end

  # The take in dialog's line reads the row the run's walk reads, at the ticket's target.
  test "the take in's line and its run have the workflow of the same row", %{scope: scope} do
    first = Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)
    {:ok, taken} = WorkItems.take_in(scope, first.public_id)
    taken = Repo.get!(WorkItem, taken.id)
    collection = Repo.get!(Apiary.Adapters.Collection, first.collection_id)

    # The row of the work item's target, by its adapter and collection ref, made where
    # the workspace has none: the row the dialog's line and the walk read.
    target_id =
      Apiary.Runs.Target.id_of(scope.organisation.id, scope.workspace.id, %{
        adapter_id: collection.adapter_id,
        collection_external_ref: taken.target_collection_external_ref,
        system: taken.target_system,
        path: taken.target_path
      })

    target = Repo.get!(Apiary.Runs.Target, target_id)
    {:ok, _row} = Stacks.put_stack(scope, {:target, target, "triage"}, nil)

    line_and_run = fn ->
      ticket =
        Apiary.WorkItemsFixtures.source_item_fixture(scope, %{
          collection: collection,
          external_ref: "acme/shop##{System.unique_integer([:positive])}"
        })

      {:run, line} = Stages.take_in_starts(scope.workspace, ticket.public_id)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      run = newest_run(work_item)
      {line, Repo.get_by!(RunHarness, dispatch_run_id: run.id).workflow}
    end

    # The target's row alone: its workflow.
    assert line_and_run.() == {"triage", "triage"}

    # A workspace row of another workflow beside it: two rows, so neither has a workflow.
    {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, "review"}, nil)
    assert line_and_run.() == {nil, nil}
  end

  test "a take in queues run 1 of 3 outside any stage", %{scope: scope} do
    refute Stages.on?()
    work_item = taken_in_fixture(scope)

    assert %WorkItem{process_version_id: nil, stage_id: nil, stage_state: nil} = work_item

    assert [
             %DispatchRun{
               step: "workflow",
               attempt: 1,
               of: 3,
               stage_id: nil,
               round: nil,
               workflow: nil,
               explore: true,
               process_version_id: nil
             }
           ] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
  end

  test "a row left escalated: a confirmation is written, as no stage runner reads the row", %{
    scope: scope
  } do
    work_item =
      scope |> taken_in_fixture() |> end_run!(Apiary.WorkItemsFixtures.understood_result())

    assert WorkItems.explore(scope, work_item).status == :confirm

    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [
          process_version_id: Apiary.Processes.current(scope.workspace).id,
          stage_id: "st_r79kph11eg",
          stage_state: :escalated
        ]
      )

    assert {:ok, %WorkItem{}} =
             WorkItems.confirm(scope, Repo.get!(WorkItem, work_item.id), 1)

    assert Repo.get_by(Confirmation, work_item_id: work_item.id)
  end

  test "a run with no row walks the first workflow of the process's first stage", %{
    scope: scope
  } do
    first = Stages.first_workflow(Apiary.Processes.current(scope.workspace))
    assert is_binary(first)
    ticket = Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)
    assert Stages.take_in_starts(scope.workspace, ticket.public_id) == {:run, first}
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    run = newest_run(work_item)

    assert %RunHarness{state: :pending, workflow: ^first} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
    assert Stages.run_workflow(run) == nil
  end

  # The walk of the workflow review, with the row's write, is in Apiary.Harnesses.WalkTest.
  test "with a row for review with access write, the run walks review with that access", %{
    scope: scope
  } do
    {:ok, _row} =
      Stacks.put_stack(scope, {:workspace, scope.workspace, "review"}, nil, access: :write)

    work_item = taken_in_fixture(scope)
    run = newest_run(work_item)
    target = WorkItem.target(work_item)

    assert %RunHarness{state: :pending, workflow: "review"} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert Stacks.workflow_for(scope.workspace, target) == "review"
    assert Stacks.recorded_access(scope.workspace, target, "review") == :write
    assert Stages.run_workflow(run) == nil
    assert Stages.take_in_starts(scope.workspace, "tk_0000000000") == {:run, "review"}
  end

  test "a run walks the workflow of the one saved row", %{scope: scope} do
    {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, "review"}, nil)
    run = scope |> taken_in_fixture() |> newest_run()

    assert %RunHarness{state: :pending, workflow: "review"} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
  end

  test "a run's end gives no result: no run pushes an artifact, as the run API answers 404",
       %{scope: scope} do
    work_item = taken_in_fixture(scope) |> end_run!(nil)
    assert WorkItems.explore(scope, work_item).status == :no_result
    assert %DispatchRun{result_outcome: :none, round: nil} = newest_run(work_item)

    # Explore again runs it once more, and so on to the run limit; no answer, no review
    # comment and no confirmation can be given, as no proposal or question exists.
    {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
    assert %DispatchRun{attempt: 2, of: 3, round: nil} = newest_run(work_item)
    work_item = end_run!(work_item, nil)

    assert WorkItems.answer(scope, work_item, 2, %{"1" => "a"}) == {:error, :not_waiting}
    assert WorkItems.review_comment(scope, work_item, 2, "Also this.") == {:error, :not_waiting}
    assert WorkItems.confirm(scope, work_item, 2) == {:error, :not_waiting}

    assert %WorkItem{state: :exploring, stage_id: nil, stage_state: nil} =
             Repo.get!(WorkItem, work_item.id)

    assert Artifacts.list(work_item) == []
    assert Repo.get_by(Confirmation, work_item_id: work_item.id) == nil
    assert Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id) == []
    assert Repo.all(from d in GateDecision, where: d.work_item_id == ^work_item.id) == []
    assert Stages.status(work_item) == nil
  end

  test "a run with a place in a process has no limits, whatever its workflow" do
    run = %DispatchRun{
      stage_id: "st_r79kph11eg",
      process_version_id: Ecto.UUID.generate(),
      workflow: "build"
    }

    assert Stages.limits(run) == nil
  end

  test "a run with a place in a process has no run workflow, Explore's among them" do
    for workflow <- ["explore-a-ticket", "build"] do
      assert Stages.run_workflow(%DispatchRun{stage_id: "st_r79kph11eg", workflow: workflow}) ==
               nil
    end
  end
end
