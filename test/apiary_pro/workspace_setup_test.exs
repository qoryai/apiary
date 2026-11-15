defmodule ApiaryPro.WorkspaceSetupTest do
  # The four rules of the Overview's setup list (`Apiary.WorkspaceSetup`), as the
  # edition reads them: the results of the core in a plain organisation.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Edition, ModelChoices, Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run

  @moduletag with_features: Apiary.Features.all()

  describe "in a plain organisation, the four rules return what the core returns" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: scope, workspace: scope.workspace}
    end

    test "work source: the adapters of the workspace's collections, by name", ctx do
      assert Edition.work_source_ready(ctx.workspace) == []

      collection = collection_fixture(ctx.scope)

      assert [%{adapter: %Node{id: adapter_id}, collections: 1}] =
               Edition.work_source_ready(ctx.workspace)

      assert adapter_id == collection.adapter_id
    end

    test "machines: a pool of the workspace and its gateway, each with an active key", ctx do
      assert Edition.machines_ready(ctx.workspace) == nil

      gateway = gateway_fixture(ctx.scope)
      pool = pool_fixture(ctx.scope)
      assert Edition.machines_ready(ctx.workspace) == nil

      _gateway_key = enrolled_key_fixture(ctx.scope, gateway)
      assert Edition.machines_ready(ctx.workspace) == nil

      _pool_key = enrolled_key_fixture(ctx.scope, pool)

      assert %{pool: %Node{id: pool_id}, gateway: %Node{id: gateway_id}} =
               Edition.machines_ready(ctx.workspace)

      assert {pool_id, gateway_id} == {pool.id, gateway.id}
    end

    test "model key: a provider with a key, and a model choice of the workspace", ctx do
      refute Edition.model_key_ready?(ctx.workspace)

      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-setup-1"}]
        })

      refute Edition.model_key_ready?(ctx.workspace)

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.scope, :workspace, %{provider: provider.public_id})

      assert Edition.model_key_ready?(ctx.workspace)
    end

    test "test run: passed once a test work item's run ended by its exit, completed", ctx do
      refute Edition.test_run_passed?(ctx.workspace)

      {:ok, item} = WorkItems.take_in_test(ctx.scope, "Hi! Where are you running?")
      refute Edition.test_run_passed?(ctx.workspace)

      [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      Repo.delete_all(from r in Run, where: r.dispatch_run_id == ^queued.id)

      %Run{
        organisation_id: item.organisation_id,
        workspace_id: item.workspace_id,
        node_run_id: queued.run_id,
        dispatch_run_id: queued.id
      }
      |> Ecto.Changeset.change(%{started_at: DateTime.utc_now(), state: "completed"})
      |> Apiary.RunEventsFixtures.insert_run!()

      assert Edition.test_run_passed?(ctx.workspace)
    end
  end
end
