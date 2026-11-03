defmodule Apiary.Stages.FeatureOffTest do
  # Without `workflow_model`, Explore works as before the stage runner: a take in queues
  # run 1 of 3 with no place in a process, a run's end stores no artifact and opens no
  # escalation, and a confirmation writes no gate decision.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Harnesses, Repo, Stacks, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{RunHarness, WalkJob}
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Confirmation, WorkItem}

  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]

  setup do
    %{scope: sign_up_fixture().scope}
  end

  test "a take in queues run 1 of 3 outside any stage", %{scope: scope} do
    refute Stages.on?()
    work_item = taken_in_fixture(scope)

    assert %WorkItem{process_version_id: nil, stage_id: nil, stage_state: nil} = work_item

    assert [
             %DispatchRun{
               step: "explore",
               attempt: 1,
               of: 3,
               stage_id: nil,
               round: nil,
               workflow: nil,
               process_version_id: nil
             }
           ] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
  end

  test "a run with no row gets a walk resolved with no origin, and no job", %{scope: scope} do
    run = scope |> taken_in_fixture() |> newest_run()

    assert %RunHarness{state: :resolved, origin: :none, workflow: nil} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    refute_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
    assert Harnesses.entries(run) == []
  end

  test "a run walks the workflow of the one saved row", %{scope: scope} do
    {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, "review"}, nil)
    run = scope |> taken_in_fixture() |> newest_run()

    assert %RunHarness{state: :pending, workflow: "review"} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
  end

  test "a proposal, questions and no result store nothing for the stage runner", %{scope: scope} do
    work_item = taken_in_fixture(scope) |> end_run!(questions_result())
    {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "a", "2" => "b"})
    assert %DispatchRun{attempt: 2, of: 3, round: nil} = newest_run(work_item)

    work_item = end_run!(work_item, nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 2)
    work_item = end_run!(work_item, understood_result())

    assert {:ok, %WorkItem{}} = WorkItems.confirm(scope, work_item, 3)
    assert Repo.get_by(Confirmation, work_item_id: work_item.id)

    assert %WorkItem{state: :exploring, stage_id: nil, stage_state: nil} =
             Repo.get!(WorkItem, work_item.id)

    assert Artifacts.list(work_item) == []
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
