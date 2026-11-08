defmodule Apiary.Stages.PointsTest do
  # The points Core writes for the causes the stage runner sets (`Apiary.Stages.Points`):
  # one sentence on what is wrong, with the action run_again, and a stopped run's fix in
  # `fix` where its cause has one (`Apiary.Stages.StopCause.parts/3`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.{Points, StopCause}
  alias Apiary.WorkItems.WorkItem

  setup do
    %{scope: scope} = sign_up_fixture()

    work_item = %WorkItem{
      id: Ecto.UUID.generate(),
      workspace_id: scope.workspace.id,
      organisation_id: scope.organisation.id,
      number: 12,
      target_system: "git.example.com",
      target_path: "acme/web-shop"
    }

    %{work_item: work_item, ws: scope.workspace.name}
  end

  # The point of a run that ended with `cause`, as the stage runner stores it.
  defp stopped(cause, work_item, fields \\ []) do
    run =
      struct(
        %DispatchRun{
          id: Ecto.UUID.generate(),
          workspace_id: work_item.workspace_id,
          organisation_id: work_item.organisation_id,
          state: :ended,
          end_cause: cause
        },
        fields
      )

    {cause, fix} = StopCause.parts(run, work_item)
    Points.run_stopped(cause, fix)
  end

  test "a round limit is one point with the rounds that ran" do
    assert Points.round_limit(3, 3) == [
             %{"text" => "3 of 3 rounds ran.", "action" => "run_again"}
           ]
  end

  test "a round limit of one round says round" do
    assert Points.round_limit(1, 1) == [
             %{"text" => "1 of 1 round ran.", "action" => "run_again"}
           ]
  end

  test "failed checks are one point for each output type" do
    assert Points.check_failed(["spec", "mockup"]) == [
             %{"text" => "No spec was stored in this stage.", "action" => "run_again"},
             %{"text" => "No mockup was stored in this stage.", "action" => "run_again"}
           ]
  end

  test "a stopped run with no fix has no fix", %{work_item: work_item} do
    assert stopped(:run_ended, work_item) == [
             %{"text" => "The run stopped: it ended without a result.", "action" => "run_again"}
           ]

    assert stopped(:lost, work_item) == [
             %{
               "text" => "The run stopped: Qory Apiary got no report from it and marked it lost.",
               "action" => "run_again"
             }
           ]
  end

  test "a stopped run whose cause has a fix keeps the fix apart", %{
    work_item: work_item,
    ws: ws
  } do
    assert stopped(:run_refused, work_item, end_detail: "model_key_missing") == [
             %{
               "text" =>
                 "The run stopped: the gateway did not start the run, because it had no model key for the run.",
               "action" => "run_again",
               "fix" => "Owners and admins of #{ws} add a model key on the set-up step Model."
             }
           ]

    assert stopped(:ticket_gone, work_item) == [
             %{
               "text" =>
                 "The run stopped: it did not start, because the work item's ticket is no longer in Qory Apiary.",
               "action" => "run_again",
               "fix" => "Close the work item, or take the ticket in again."
             }
           ]
  end

  test "a run that failed after it wrote a proposal names the proposal's version" do
    assert Points.run_stopped(StopCause.failed_after_proposal(1), nil) == [
             %{
               "text" => "The run stopped: it failed after it wrote proposal version 1.",
               "action" => "run_again"
             }
           ]
  end
end
