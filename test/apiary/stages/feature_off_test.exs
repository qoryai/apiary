defmodule Apiary.Stages.FeatureOffTest do
  # Without `workflow_model`, Explore runs with no stage runner: a take in queues run 1 of
  # 3 with no place in a process, and a run's end opens no escalation. The run API answers
  # 404, so a run pushes no proposal and no questions, and every run ends with no result.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

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
