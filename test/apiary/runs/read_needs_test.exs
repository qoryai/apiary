defmodule Apiary.Runs.ReadNeedsTest do
  # A read-only run qory closed on the instance's pool (`Apiary.Runs.ReadNeeds`): the words
  # of the escalation and the facts of Explore's tab. The instance has one pool in use at
  # most, so this module is not async.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Runs.ReadNeeds
  alias Apiary.Stages.StopCause

  @moduletag needs: :factory

  @failed %{
    state: "failed",
    exit_state: "failed",
    outcome_state: nil,
    outcome_time: nil,
    outcome_received_at: nil,
    outcome_digest: nil
  }

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, work_item: work_item_fixture(scope)}
  end

  defp ended(work_item, reason, node) do
    explore_run_fixture(work_item,
      run: Map.merge(@failed, %{reason: reason, node_id: node && node.id})
    )
  end

  defp stored(work_item, reason, node) do
    %{dispatch_run: dispatch_run} = ended(work_item, reason, node)
    StopCause.text(%{dispatch_run | result_outcome: :none}, work_item)
  end

  describe "StopCause.text/2" do
    test "Contact support stands in place of the two fixes a person cannot make", ctx do
      pool = instance_pool_fixture(installed_as: "pool")

      assert stored(ctx.work_item, "read_needs_wall", pool) ==
               "Contact support. A read-only run needs a wall, and this machine has none."

      other = work_item_fixture(ctx.scope)

      assert stored(other, "read_needs_setup_outside", pool) ==
               "Contact support. A read-only run cannot run its setup inside the agent's container."
    end

    test "the other two reasons keep their fix", ctx do
      pool = instance_pool_fixture(installed_as: "pool")

      assert stored(ctx.work_item, "read_needs_setup_removed", pool) ==
               "Start the run again. The setup container was not removed, so a process in it could still write the files."

      other = work_item_fixture(ctx.scope)

      assert stored(other, "read_needs_no_nested_docker", pool) ==
               "Choose an image without nested Docker in the repository's environment, then start the run again. A read-only run cannot use an image with nested Docker."
    end

    test "a pool since deleted reads as the instance's", ctx do
      pool =
        instance_pool_fixture(installed_as: "pool")
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

      assert stored(ctx.work_item, "read_needs_wall", pool) ==
               "Contact support. A read-only run needs a wall, and this machine has none."
    end
  end

  describe "of_run/1" do
    test "a gateway at the instance is no pool" do
      gateway = instance_gateway_fixture()

      assert ReadNeeds.of_run(%{reason: "read_needs_wall", node_id: gateway.id}) ==
               %{code: "read_needs_wall", installed: false}
    end

    test "any other reason, and no run, have no facts" do
      assert ReadNeeds.of_run(%{reason: "no_longer_needed", node_id: nil}) == nil
      assert ReadNeeds.of_run(nil) == nil
    end
  end

  describe "WorkItems.explore/2" do
    test "a run on the instance's pool has installed: true", ctx do
      ended(ctx.work_item, "read_needs_wall", instance_pool_fixture(installed_as: "pool"))

      assert %{run: %{read_needs: %{code: "read_needs_wall", installed: true}}} =
               WorkItems.explore(ctx.scope, ctx.work_item)
    end
  end
end
