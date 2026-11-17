defmodule Apiary.Runs.WriteNeedsTest do
  # A run that writes and that qory closed for want of a wall (`Apiary.Runs.WriteNeeds`):
  # its facts and the words of the escalation, for the instance's pool and for another
  # pool. The instance has one pool in use at most, so this module is not async.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Runs.WriteNeeds
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

  @cause "A run that writes to the checkout needs a wall, and this machine has none."

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
    test "Contact support stands in place of the fix a person cannot make", ctx do
      pool = instance_pool_fixture(installed_as: "pool")

      assert stored(ctx.work_item, "write_needs_wall", pool) == "Contact support. " <> @cause
    end

    test "another pool keeps the fix", ctx do
      pool = pool_fixture(ctx.scope)

      assert stored(ctx.work_item, "write_needs_wall", pool) ==
               "Set a wall in the machine's forager.yaml, then start the run again. " <> @cause
    end

    test "a pool since deleted reads as the instance's", ctx do
      pool =
        instance_pool_fixture(installed_as: "pool")
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

      assert stored(ctx.work_item, "write_needs_wall", pool) == "Contact support. " <> @cause
    end
  end

  describe "of_run/1" do
    test "a run on the instance's pool has installed: true" do
      pool = instance_pool_fixture(installed_as: "pool")

      assert WriteNeeds.of_run(%{reason: "write_needs_wall", node_id: pool.id}) ==
               %{code: "write_needs_wall", installed: true}
    end

    test "a run on another pool, and a gateway at the instance, have installed: false", ctx do
      pool = pool_fixture(ctx.scope)
      gateway = instance_gateway_fixture()

      for node <- [pool, gateway, nil] do
        assert WriteNeeds.of_run(%{reason: "write_needs_wall", node_id: node && node.id}) ==
                 %{code: "write_needs_wall", installed: false}
      end
    end

    test "any other reason, a read-only reason included, and no run, have no facts" do
      assert WriteNeeds.of_run(%{reason: "read_needs_wall", node_id: nil}) == nil
      assert WriteNeeds.of_run(%{reason: "no_longer_needed", node_id: nil}) == nil
      assert WriteNeeds.of_run(nil) == nil
    end
  end

  describe "of_dispatch_run/1" do
    test "reads the registered run's reason and pool", ctx do
      pool = instance_pool_fixture(installed_as: "pool")
      %{dispatch_run: dispatch_run} = ended(ctx.work_item, "write_needs_wall", pool)

      assert WriteNeeds.of_dispatch_run(dispatch_run) ==
               %{code: "write_needs_wall", installed: true}
    end

    test "a read-only run has none", ctx do
      %{dispatch_run: dispatch_run} = ended(ctx.work_item, "read_needs_wall", nil)

      assert WriteNeeds.of_dispatch_run(dispatch_run) == nil
    end
  end
end
