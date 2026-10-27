defmodule Apiary.WorkspaceSetupTest do
  # The four rules of the Overview's setup list (`Apiary.WorkspaceSetup`), as the core's
  # edition answers them and as a test's stub of the edition overrides them, and the state
  # of the latest test run. Not async: some tests make the instance's pool and gateway,
  # which the instance has one of each at most.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Edition, EditionStubs, ModelChoices, Repo, WorkItems, WorkspaceSetup}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, workspace: scope.workspace}
  end

  defp set!(schema, id, changes) do
    {1, _rows} = Repo.update_all(from(r in schema, where: r.id == ^id), set: changes)
    :ok
  end

  # The one run of `item`, a test work item, ended with `changes`, and its registered run,
  # with `run_attrs`, in place of any it had; none for nil.
  defp end_test!(item, changes, run_attrs \\ nil) do
    [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)
    set!(DispatchRun, queued.id, [state: :ended] ++ changes)
    Repo.delete_all(from r in Run, where: r.dispatch_run_id == ^queued.id)

    if run_attrs do
      %Run{
        organisation_id: item.organisation_id,
        workspace_id: item.workspace_id,
        node_run_id: queued.run_id,
        dispatch_run_id: queued.id
      }
      |> Ecto.Changeset.change(Map.merge(%{started_at: DateTime.utc_now()}, run_attrs))
      |> Repo.insert!()
    end

    queued
  end

  describe "work source" do
    test "none until a collection of a connected, listed connection is assigned", ctx do
      assert WorkspaceSetup.work_source(ctx.workspace) == []
      assert Edition.work_source_ready(ctx.workspace) == []

      collection = collection_fixture(ctx.scope)
      _second = collection_fixture(ctx.scope)

      assert [%{adapter: %Node{id: adapter_id}, collections: 1}, %{collections: 1}] =
               Edition.work_source_ready(ctx.workspace)

      assert adapter_id in Enum.map(WorkspaceSetup.work_source(ctx.workspace), & &1.adapter.id)

      assert collection.adapter_id in Enum.map(
               WorkspaceSetup.work_source(ctx.workspace),
               & &1.adapter.id
             )
    end

    test "counts the collections of one adapter together", ctx do
      collection = collection_fixture(ctx.scope)

      Repo.insert!(%{
        collection
        | id: nil,
          public_id: Apiary.PublicId.generate(Collection.prefix()),
          external_ref: "R_other",
          target_path: "acme/R_other"
      })

      assert [%{collections: 2}] = WorkspaceSetup.work_source(ctx.workspace)
    end

    test "leaves out a collection that ended, of another workspace, or of none", ctx do
      ended = collection_fixture(ctx.scope)
      set!(Collection, ended.id, ended_at: DateTime.utc_now(), ended_reason: :disconnected)

      other = workspace_fixture(ctx.scope.organisation)
      _elsewhere = collection_fixture(ctx.scope, workspace_id: other.id)
      _unassigned = collection_fixture(ctx.scope, workspace_id: nil)

      assert WorkspaceSetup.work_source(ctx.workspace) == []
      assert [%{collections: 1}] = WorkspaceSetup.work_source(other)
    end

    test "leaves out a connection not connected, never listed, or ended", ctx do
      for changes <- [
            [state: :pending, connected_at: nil, listed_at: nil],
            [listed_at: nil],
            [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
          ] do
        collection = collection_fixture(ctx.scope)
        set!(Connection, collection.connection_id, changes)
      end

      assert WorkspaceSetup.work_source(ctx.workspace) == []
    end

    test "leaves out the collections of an adapter deleted", ctx do
      collection = collection_fixture(ctx.scope)
      set!(Node, collection.adapter_id, deleted_at: DateTime.utc_now())

      assert WorkspaceSetup.work_source(ctx.workspace) == []
    end
  end

  describe "machines for runs" do
    test "a pool of the workspace and its gateway, each with an active key", ctx do
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      %{pool: pool, gateway: gateway} = handover_place_fixture(ctx.scope)

      assert %{pool: %Node{id: pool_id}, gateway: %Node{id: gateway_id}} =
               Edition.machines_ready(ctx.workspace)

      assert {pool_id, gateway_id} == {pool.id, gateway.id}
      refute WorkspaceSetup.instance_pool?(ctx.workspace)
    end

    test "nil while the pool has no key, or its gateway has none", ctx do
      gateway = gateway_fixture(ctx.scope)
      _pool = pool_fixture(ctx.scope)
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      # A key on the gateway alone.
      _key = node_key_fixture(ctx.scope, gateway)
      assert WorkspaceSetup.machines(ctx.workspace) == nil
    end

    test "the instance's pool and gateway while the workspace has no pool", ctx do
      pool = instance_pool_fixture()
      gateway = instance_gateway_fixture()
      assert WorkspaceSetup.instance_pool?(ctx.workspace)
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      _pool_key = installed_key_fixture(pool)
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      _gateway_key = installed_key_fixture(gateway, allow_secrets: true)

      assert %{pool: %Node{id: pool_id}, gateway: %Node{id: gateway_id}} =
               WorkspaceSetup.machines(ctx.workspace)

      assert {pool_id, gateway_id} == {pool.id, gateway.id}

      # A pool of the workspace, with no key yet, takes its runs from then on.
      _pool = pool_fixture(ctx.scope)
      refute WorkspaceSetup.instance_pool?(ctx.workspace)
      assert WorkspaceSetup.machines(ctx.workspace) == nil
    end
  end

  describe "model key" do
    @describetag needs: [:factory, :secrets]

    test "a provider with a key, and a choice of the workspace", ctx do
      refute WorkspaceSetup.model_key?(ctx.workspace)

      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-setup-1"}]
        })

      refute Edition.model_key_ready?(ctx.workspace)

      # The organisation's default is no choice of the workspace.
      {:ok, _} =
        ModelChoices.put_choice(ctx.scope, :organisation, %{provider: provider.public_id})

      refute WorkspaceSetup.model_key?(ctx.workspace)

      {:ok, _} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: provider.public_id})
      assert Edition.model_key_ready?(ctx.workspace)

      # Another workspace has no choice.
      refute WorkspaceSetup.model_key?(workspace_fixture(ctx.scope.organisation))
    end

    test "on an operator's chain, the operator's provider with a key and its default", ctx do
      %{scope: operator} = sign_up_fixture()
      :ok = Edition.put_test_stub(EditionStubs.ServesAcrossWithChain)
      EditionStubs.ServesAcross.put([{operator.organisation.id, ctx.scope.organisation.id}])
      EditionStubs.ServesAcrossWithChain.writer(true)

      provider = fn scope, chain ->
        {:ok, provider} =
          Connections.create_provider(scope, %{
            provider: "anthropic",
            chain: chain,
            keys: [%{value_id: "main", value: "sk-setup-operator-1"}]
          })

        provider
      end

      # The client's own provider and choice of the workspace, on its own chain.
      own = provider.(ctx.scope, "organisation")
      {:ok, _} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: own.public_id})
      assert Edition.model_key_ready?(ctx.workspace)

      # On the operator's chain, the client's rows are not read.
      EditionStubs.ServesAcrossWithChain.chain("operator")
      refute Edition.model_key_ready?(ctx.workspace)

      theirs = provider.(operator, "operator")
      refute WorkspaceSetup.model_key?(ctx.workspace)

      {:ok, _} =
        ModelChoices.put_choice(
          operator,
          :organisation,
          %{provider: theirs.public_id, key: "main"},
          "operator"
        )

      assert Edition.model_key_ready?(ctx.workspace)

      # An operator's chain whose operator the edition does not name has no key.
      EditionStubs.ServesAcrossWithChain.operator(nil)
      refute WorkspaceSetup.model_key?(ctx.workspace)
    end
  end

  describe "the test run" do
    test "none, waiting, waiting past 5 minutes, then running", ctx do
      assert WorkspaceSetup.test_run(ctx.workspace, DateTime.utc_now()) == nil

      {:ok, item} = WorkItems.take_in_test(ctx.scope, "Hi! Where are you running?")
      now = DateTime.utc_now()

      assert %{state: :waiting, work_item: %{id: id}, run: nil} =
               WorkspaceSetup.test_run(ctx.workspace, now)

      assert id == item.id

      assert %{state: {:failed, :no_machine}} =
               WorkspaceSetup.test_run(ctx.workspace, DateTime.add(now, 301, :second))

      [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)

      for state <- [:claimed, :handed_over] do
        set!(DispatchRun, queued.id, state: state)
        assert %{state: :running} = WorkspaceSetup.test_run(ctx.workspace, now)
      end
    end

    test "passed: ended by its exit, its run completed", ctx do
      {:ok, item} = WorkItems.take_in_test(ctx.scope, "Hi! Where are you running?")
      refute Edition.test_run_passed?(ctx.workspace)

      run = end_test!(item, [end_cause: :run_ended], %{state: "completed"})
      run = Repo.get_by!(Run, dispatch_run_id: run.id)

      assert %{state: :passed, run: %{id: run_id}} =
               WorkspaceSetup.test_run(ctx.workspace, DateTime.utc_now())

      assert run_id == run.id
      assert Edition.test_run_passed?(ctx.workspace)
    end

    test "each failure, by its run's end", ctx do
      {:ok, item} = WorkItems.take_in_test(ctx.scope, "Hi! Where are you running?")
      read = fn -> WorkspaceSetup.test_run(ctx.workspace, DateTime.utc_now()).state end

      end_test!(item, [end_cause: :run_refused, end_detail: "model_key_missing"], %{
        state: "failed",
        reason: "model_key_missing"
      })

      assert read.() == {:failed, :model_key_missing}

      # Another refusal is no missing key.
      end_test!(item, [end_cause: :run_refused, end_detail: "image_unknown"], %{state: "failed"})
      assert read.() == {:failed, :other}

      end_test!(item, [end_cause: :lost, end_detail: nil], %{
        state: "lost",
        silenced_at: DateTime.utc_now()
      })

      assert read.() == {:failed, :silent}

      # Lost, never attached or past its backstop: not silent.
      end_test!(item, [end_cause: :lost], %{state: "lost"})
      assert read.() == {:failed, :other}

      # Ended by its exit, failed.
      end_test!(item, [end_cause: :run_ended], %{state: "failed"})
      assert read.() == {:failed, :other}

      # Ended before a machine took it: no registered run.
      end_test!(item, end_cause: :harness_unresolved, result_outcome: :error)

      assert %{state: {:failed, :other}, run: nil} =
               WorkspaceSetup.test_run(ctx.workspace, DateTime.utc_now())

      refute Edition.test_run_passed?(ctx.workspace)
    end

    test "reads the latest test work item of the workspace alone", ctx do
      {:ok, first} = WorkItems.take_in_test(ctx.scope, "Hi! Where are you running?")
      end_test!(first, [end_cause: :run_ended], %{state: "completed"})
      assert WorkspaceSetup.test_passed?(ctx.workspace)

      {:ok, second} = WorkItems.take_in_test(ctx.scope, "Hello again")

      assert %{state: :waiting, work_item: %{id: id}} =
               WorkspaceSetup.test_run(ctx.workspace, DateTime.utc_now())

      assert id == second.id

      # A test that passed once keeps the step done.
      assert WorkspaceSetup.test_passed?(ctx.workspace)

      # A work item that is no test is not read.
      other = workspace_fixture(ctx.scope.organisation)
      explore_run_fixture(work_item_fixture(ctx.scope))
      refute WorkspaceSetup.test_passed?(other)
      assert WorkspaceSetup.test_run(other, DateTime.utc_now()) == nil
    end
  end

  describe "the edition" do
    test "a stub's rules are read in place of the core's", ctx do
      :ok = Edition.put_test_stub(EditionStubs.SetupReady)

      assert %{
               work_source: [],
               machines: %{
                 pool: %Node{name: "shared-pool"},
                 gateway: %Node{name: "shared-gateway"}
               },
               model_key: true,
               test_passed: false,
               test_run: nil
             } = WorkspaceSetup.read(ctx.workspace)
    end
  end
end
