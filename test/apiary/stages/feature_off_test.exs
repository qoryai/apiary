defmodule Apiary.Stages.FeatureOffTest do
  # Without `workflow_model`, Explore works as before the stage runner: a take in queues
  # run 1 of 3 with no place in a process, a run's end stores no artifact and opens no
  # escalation, and a confirmation writes no gate decision.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, Stages, StagesArtifactsStub, WorkItems}
  alias Apiary.Dispatches.DispatchRun
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

  test "a proposal, questions and no result store nothing for the stage runner", %{scope: scope} do
    work_item = taken_in_fixture(scope) |> end_run!(questions_result())
    {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "a", "2" => "b"})
    assert %DispatchRun{attempt: 2, of: 3, round: nil} = newest_run(work_item)

    work_item = end_run!(work_item, nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 2)
    work_item = end_run!(work_item, understood_result())

    assert {:ok, %WorkItem{}} = WorkItems.confirm(scope, work_item, 3)
    assert Repo.get_by(Confirmation, work_item_id: work_item.id)
    assert %WorkItem{stage_id: nil, stage_state: nil} = Repo.get!(WorkItem, work_item.id)
    assert StagesArtifactsStub.list(work_item) == []
    assert Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id) == []
    assert Repo.all(from d in GateDecision, where: d.work_item_id == ^work_item.id) == []
    assert Stages.status(work_item) == nil
  end
end
