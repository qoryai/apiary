defmodule Apiary.WorkspaceSetupTest do
  # The edition's four rules of the set-up (`Apiary.WorkspaceSetup`), as the core's
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

  describe "the Machines step" do
    @software Apiary.Lingo.Domain.Software

    defp states(workspace),
      do:
        for(
          %{pool: pool, instance: instance, state: state} <- WorkspaceSetup.pools(workspace),
          do: {pool && pool.id, instance, state}
        )

    test "pools/1: the instance's pool, not ready for each reason it lacks, then ready", ctx do
      organisation = ctx.scope.organisation
      assert WorkspaceSetup.serving_pools(ctx.workspace) == []
      assert states(ctx.workspace) == [{nil, true, {:not_ready, :no_pool}}]
      refute WorkspaceSetup.done?(:machines, organisation, {@software, ctx.workspace})

      pool = instance_pool_fixture()
      assert [%Node{id: pool_id}] = WorkspaceSetup.serving_pools(ctx.workspace)
      assert pool_id == pool.id
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :no_active_key}}]

      _pool_key = installed_key_fixture(pool)
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :no_gateway}}]

      gateway = instance_gateway_fixture()
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :gateway_without_key}}]
      refute WorkspaceSetup.done?(:machines, organisation, {@software, ctx.workspace})

      _gateway_key = installed_key_fixture(gateway, allow_secrets: true)

      assert [{^pool_id, true, {:ready, %Node{id: gateway_id}}}] = states(ctx.workspace)
      assert gateway_id == gateway.id
      assert WorkspaceSetup.done?(:machines, organisation, {@software, ctx.workspace})
      refute WorkspaceSetup.done?(:machines, organisation, {@software, nil})
    end

    test "pools/1: a pool of the workspace in place of the instance's, enrolled or not", ctx do
      organisation = ctx.scope.organisation
      instance_pool = instance_pool_fixture()
      _key = installed_key_fixture(instance_pool)
      _gateway_key = installed_key_fixture(instance_gateway_fixture(), allow_secrets: true)
      assert WorkspaceSetup.done?(:machines, organisation, {@software, ctx.workspace})

      # A pool of the workspace that has not enrolled serves the workspace alone, and is
      # not ready.
      gateway = gateway_fixture(ctx.scope)
      _gateway_key = node_key_fixture(ctx.scope, gateway)
      pool = pool_fixture(ctx.scope)

      assert states(ctx.workspace) == [{pool.id, false, {:not_ready, :no_active_key}}]
      refute WorkspaceSetup.done?(:machines, organisation, {@software, ctx.workspace})

      # Enrolled, through the workspace's gateway.
      _pool_key = enrolled_key_fixture(ctx.scope, pool)

      assert [{pool_id, false, {:ready, %Node{id: gateway_id}}}] = states(ctx.workspace)
      assert {pool_id, gateway_id} == {pool.id, gateway.id}
      assert WorkspaceSetup.done?(:machines, organisation, {@software, ctx.workspace})
    end

    test "instance_line/0: the instance's pool with its state, while a pool of the workspace serves the workspace",
         ctx do
      assert WorkspaceSetup.instance_line() ==
               %{pool: nil, instance: true, state: {:not_ready, :no_pool}}

      instance_pool = instance_pool_fixture()
      _pool = pool_fixture(ctx.scope)
      refute WorkspaceSetup.instance_pool?(ctx.workspace)

      assert %{pool: %Node{id: id}, instance: true, state: {:not_ready, :no_active_key}} =
               WorkspaceSetup.instance_line()

      assert id == instance_pool.id

      _key = installed_key_fixture(instance_pool)
      gateway = instance_gateway_fixture()
      _gateway_key = installed_key_fixture(gateway, allow_secrets: true)

      assert %{state: {:ready, %Node{id: gateway_id}}} = WorkspaceSetup.instance_line()
      assert gateway_id == gateway.id
    end

    test "pools/1: a pool of the workspace set to Direct, or to a default gateway that does not exist",
         ctx do
      pool = pool_fixture(ctx.scope)
      _pool_key = enrolled_key_fixture(ctx.scope, pool)

      assert pool.gateway_choice == :direct
      assert states(ctx.workspace) == [{pool.id, false, {:not_ready, :direct}}]
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      set!(Node, pool.id, gateway_choice: :default)
      assert states(ctx.workspace) == [{pool.id, false, {:not_ready, :no_gateway}}]
      assert WorkspaceSetup.machines(ctx.workspace) == nil
    end

    test "pools/1: the instance's pool set to Direct, naming a gateway its runs may not go through, or one deleted",
         ctx do
      gateway = gateway_fixture(ctx.scope)
      _gateway_key = node_key_fixture(ctx.scope, gateway)
      instance_gateway = instance_gateway_fixture()
      _instance_key = installed_key_fixture(instance_gateway, allow_secrets: true)

      pool = instance_pool_fixture(gateway_choice: :direct)
      _pool_key = installed_key_fixture(pool)
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :direct}}]
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      # The instance's pool's runs go through the instance's gateway alone.
      set!(Node, pool.id, gateway_choice: :named, gateway_id: gateway.id)
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :gateway_not_serving}}]
      assert WorkspaceSetup.machines(ctx.workspace) == nil

      # The instance's gateway, named, then deleted, or gone from the choice.
      set!(Node, pool.id, gateway_id: instance_gateway.id)
      assert [{_id, true, {:ready, %Node{}}}] = states(ctx.workspace)

      set!(Node, instance_gateway.id, deleted_at: DateTime.utc_now())
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :no_gateway}}]

      set!(Node, pool.id, gateway_id: nil)
      assert states(ctx.workspace) == [{pool.id, true, {:not_ready, :no_gateway}}]
      assert WorkspaceSetup.machines(ctx.workspace) == nil
    end

    test "a pool's name is the workspace's name, cut to whole graphemes within 80 code points, trailing whitespace trimmed",
         ctx do
      name = &WorkspaceSetup.pool_name(%Apiary.Organisations.Workspace{name: &1})

      assert name.("Payments") == "Payments"
      assert name.(String.duplicate("a", 120)) == String.duplicate("a", 80)
      assert name.(String.duplicate("a", 79) <> " bbbb") == String.duplicate("a", 79)

      # "é" as "e" and a combining acute accent: 1 grapheme, 2 code points.
      accented = "é"
      cut = name.(String.duplicate(accented, 50))
      assert cut == String.duplicate(accented, 40)
      assert {String.length(cut), length(String.codepoints(cut))} == {40, 80}

      # A grapheme that would pass 80 code points is left out whole.
      assert name.(String.duplicate("a", 79) <> accented) == String.duplicate("a", 79)

      assert name.(String.duplicate("a", 78) <> accented <> "b") ==
               String.duplicate("a", 78) <> accented

      # A family emoji: 1 grapheme, 5 code points.
      family = "\u{1F468}‍\u{1F469}‍\u{1F467}"
      assert name.(String.duplicate(family, 20)) == String.duplicate(family, 16)

      # The node's changeset and the database's check accept each cut name.
      for long <- [
            String.duplicate("a", 120),
            String.duplicate(accented, 60),
            String.duplicate(family, 24)
          ] do
        assert %Node{kind: :pool} = pool_fixture(ctx.scope, name: name.(long))
      end
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
      assert read.() == {:failed, :ended}

      end_test!(item, [end_cause: :lost, end_detail: nil], %{
        state: "lost",
        silenced_at: DateTime.utc_now()
      })

      assert read.() == {:failed, :silent}

      # Lost, never attached or past its backstop: not silent.
      end_test!(item, [end_cause: :lost], %{state: "lost"})
      assert read.() == {:failed, :ended}

      # Ended by its exit, failed.
      end_test!(item, [end_cause: :run_ended], %{state: "failed"})
      assert read.() == {:failed, :ended}

      # Ended before a machine took it: no registered run.
      end_test!(item, end_cause: :harness_unresolved, result_outcome: :error)

      assert %{state: {:failed, :no_run}, run: nil} =
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

      assert Edition.work_source_ready(ctx.workspace) == []

      assert %{pool: %Node{name: "shared-pool"}, gateway: %Node{name: "shared-gateway"}} =
               Edition.machines_ready(ctx.workspace)

      assert Edition.model_key_ready?(ctx.workspace)
      refute Edition.test_run_passed?(ctx.workspace)
    end
  end

  describe "the rules of the set-up flow" do
    defmodule NoAdapterRead do
      # Nobody reads the instance's adapters in an organisation (`adapter.read`).
      def check(_scope, :"adapter.read", _subject), do: {:error, :forbidden}
      def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
    end

    @software Apiary.Lingo.Domain.Software

    defp targets!(adapter_id), do: set!(Node, adapter_id, targets: true)

    test "connected_ids/3: the adapters for the type with a connected connection", ctx do
      organisation = ctx.scope.organisation
      assert WorkspaceSetup.connected_ids(organisation, @software, :items) == MapSet.new()

      # Pending is not connected.
      %{adapter: pending} = connectable_adapter_fixture()
      {_connection, _nonce} = connection_fixture(ctx.scope, pending, :pending)
      assert WorkspaceSetup.connected_ids(organisation, @software, :items) == MapSet.new()

      %{adapter: adapter} = connectable_adapter_fixture()
      {connection, _nonce} = connection_fixture(ctx.scope, adapter, :connected)

      assert WorkspaceSetup.connected_ids(organisation, @software, :items) ==
               MapSet.new([adapter.id])

      assert WorkspaceSetup.connected_ids(organisation, @software, :targets) == MapSet.new()

      targets!(adapter.id)

      assert WorkspaceSetup.connected_ids(organisation, @software, :targets) ==
               MapSet.new([adapter.id])

      # An adapter that serves another type counts for that type alone.
      set!(Node, adapter.id, domains: ["example"])
      assert WorkspaceSetup.connected_ids(organisation, @software, :items) == MapSet.new()

      assert WorkspaceSetup.connected_ids(organisation, Apiary.Lingo.Domain.Example, :items) ==
               MapSet.new([adapter.id])

      # An ended connection counts for none.
      set!(Node, adapter.id, domains: nil)

      set!(Connection, connection.id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: "adapter_reported"
      )

      assert WorkspaceSetup.connected_ids(organisation, @software, :items) == MapSet.new()

      # Another organisation's connection counts for none.
      assert WorkspaceSetup.connected_ids(sign_up_fixture().organisation, @software, :items) ==
               MapSet.new()
    end

    @tag needs: [:factory, :secrets]
    test "done?/3: Model once the workspace's choice has a provider that reaches it, with a key",
         ctx do
      %{scope: scope, workspace: main} = ctx
      organisation = scope.organisation

      done? = fn workspace ->
        WorkspaceSetup.done?(:model, organisation, {@software, workspace})
      end

      refute done?.(main)

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-flow-1"}]
        })

      refute done?.(main)

      # The organisation's default (level 6) is no choice of the workspace.
      {:ok, _} = ModelChoices.put_choice(scope, :organisation, %{provider: provider.public_id})
      refute done?.(main)

      {:ok, _} =
        ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id, key: "main"})

      assert done?.(main)
      assert WorkspaceSetup.model_key?(main)

      # Another workspace has no choice; every step after Name is not done before the
      # workspace exists.
      refute done?.(workspace_fixture(organisation, "Other"))
      refute done?.(nil)

      # A provider that reaches no workspace any more: applies to the workspaces it lists,
      # and lists none.
      set!(Apiary.Connections.Connection, provider.id, applies_to: "selected")
      refute done?.(main)
      refute WorkspaceSetup.model_key?(main)

      Repo.insert!(%Apiary.Connections.ConnectionWorkspace{
        organisation_id: organisation.id,
        connection_id: provider.id,
        workspace_id: main.id
      })

      assert done?.(main)

      # A provider with no key.
      Repo.delete_all(from v in Apiary.Secrets.Value, where: v.secret_id == ^provider.secret_id)

      refute done?.(main)
      refute WorkspaceSetup.model_key?(main)
    end

    test "sources? and destinations?: a row of the tick list ticked", ctx do
      %{scope: scope, workspace: main} = ctx
      collection = collection_fixture(scope)

      # Assigned to Main with its Backlog on: a work source used; its adapter has no
      # targets, so no destination.
      assert WorkspaceSetup.sources?(main, @software)
      refute WorkspaceSetup.destinations?(main, @software)

      set!(Collection, collection.id, backlog: false)
      refute WorkspaceSetup.sources?(main, @software)

      targets!(collection.adapter_id)
      assert WorkspaceSetup.destinations?(main, @software)

      # A collection with no target is in no destination list.
      set!(Collection, collection.id, target_system: nil, target_path: nil)
      refute WorkspaceSetup.destinations?(main, @software)

      # A collection of another workspace counts for that workspace alone.
      set!(Collection, collection.id,
        target_system: "code.example.com",
        target_path: "acme/repo",
        backlog: true
      )

      other = workspace_fixture(scope.organisation, "Other")
      set!(Collection, collection.id, workspace_id: other.id)
      refute WorkspaceSetup.sources?(main, @software)
      refute WorkspaceSetup.destinations?(main, @software)
      assert WorkspaceSetup.sources?(other, @software)
      assert WorkspaceSetup.destinations?(other, @software)
    end

    test "done?/3: Name once the workspace exists; no other step before", ctx do
      organisation = ctx.scope.organisation
      _collection = collection_fixture(ctx.scope)

      refute WorkspaceSetup.done?(:name, organisation, {@software, nil})
      assert WorkspaceSetup.done?(:name, organisation, {@software, ctx.workspace})

      for step <- WorkspaceSetup.flow() -- [:name],
          do: refute(WorkspaceSetup.done?(step, organisation, {@software, nil}))

      # Work sources by the workspace's tick list: the collection is Main's, Backlog on.
      assert WorkspaceSetup.done?(:sources, organisation, {@software, ctx.workspace})
      refute WorkspaceSetup.done?(:destinations, organisation, {@software, ctx.workspace})
      refute WorkspaceSetup.done?(:test, organisation, {@software, ctx.workspace})

      assert WorkspaceSetup.flow() ==
               [:name, :sources, :destinations, :model, :harness, :machines, :test]
    end

    test "done?/3: Destinations once a collection with a target is the workspace's", ctx do
      organisation = ctx.scope.organisation
      collection = collection_fixture(ctx.scope)
      refute WorkspaceSetup.done?(:destinations, organisation, {@software, ctx.workspace})

      targets!(collection.adapter_id)
      assert WorkspaceSetup.done?(:destinations, organisation, {@software, ctx.workspace})

      # Its Backlog off: still a destination, no work source.
      set!(Collection, collection.id, backlog: false)
      assert WorkspaceSetup.done?(:destinations, organisation, {@software, ctx.workspace})
      refute WorkspaceSetup.done?(:sources, organisation, {@software, ctx.workspace})

      # In another workspace: neither for Main.
      other = workspace_fixture(ctx.scope.organisation, "Other")
      set!(Collection, collection.id, workspace_id: other.id, backlog: true)
      refute WorkspaceSetup.done?(:destinations, organisation, {@software, ctx.workspace})
      refute WorkspaceSetup.done?(:sources, organisation, {@software, ctx.workspace})
      assert WorkspaceSetup.done?(:sources, organisation, {@software, other})
    end

    test "done?/3: Harness once the workspace has a saved choice, or takes the organisation's shared harness",
         ctx do
      organisation = ctx.scope.organisation
      other = workspace_fixture(organisation, "Other")
      refute WorkspaceSetup.done?(:harness, organisation, {@software, ctx.workspace})

      {:ok, _stack} = Apiary.Stacks.Sources.choose(ctx.scope, :qory)
      assert WorkspaceSetup.done?(:harness, organisation, {@software, ctx.workspace})
      refute WorkspaceSetup.done?(:harness, organisation, {@software, other})

      # A document at the workspace saved without a choice is no choice.
      {:ok, _stack} =
        Apiary.Stacks.put_stack(
          ctx.scope,
          {:workspace, ctx.workspace},
          "extends: {git: \"https://code.example.com/acme/harness\", ref: v1}\n"
        )

      refute WorkspaceSetup.done?(:harness, organisation, {@software, ctx.workspace})

      # The organisation's shared harness: done for each workspace with no choice.
      {:ok, _stack} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      assert WorkspaceSetup.done?(:harness, organisation, {@software, ctx.workspace})
      assert WorkspaceSetup.done?(:harness, organisation, {@software, other})

      {:ok, _stack} = Apiary.Stacks.delete_stack({:organisation, organisation})
      refute WorkspaceSetup.done?(:harness, organisation, {@software, other})
    end

    test "collections/3: the organisation's rows by adapter, each with its workspace", ctx do
      %{scope: scope, workspace: main} = ctx
      other = workspace_fixture(scope.organisation, "Other")
      b = collection_fixture(scope, external_ref: "b-repo")
      a = collection_fixture(scope, workspace_id: other.id, external_ref: "a-repo")
      free = collection_fixture(scope, workspace_id: nil, external_ref: "c-repo")
      set!(Node, b.adapter_id, name: "Beta")
      set!(Node, a.adapter_id, name: "alpha")
      set!(Node, free.adapter_id, name: "Gamma")
      targets!(a.adapter_id)

      # Another organisation's collection, and an ended one, are in no list.
      _theirs = collection_fixture(sign_up_fixture().scope)
      ended = collection_fixture(scope)
      set!(Collection, ended.id, ended_at: DateTime.utc_now(), ended_reason: "not_listed")

      rows = fn list ->
        for {adapter, rows} <- WorkspaceSetup.collections(scope, @software, list),
            do:
              {adapter.name, Enum.map(rows, &{&1.collection.id, &1.workspace && &1.workspace.id})}
      end

      assert rows.(:sources) == [
               {"alpha", [{a.id, other.id}]},
               {"Beta", [{b.id, main.id}]},
               {"Gamma", [{free.id, nil}]}
             ]

      # Destinations: the collections with a target, of an adapter with targets.
      assert rows.(:destinations) == [{"alpha", [{a.id, other.id}]}]

      # A collection with no items is in no work source list.
      set!(Collection, b.id, items: false)
      assert [{"alpha", _}, {"Gamma", _}] = rows.(:sources)

      # A person who may not read the instance's adapters gets no row.
      :ok = Edition.put_test_stub(NoAdapterRead)
      assert WorkspaceSetup.collections(scope, @software, :sources) == []
    end

    test "tick/5: changes a row of the list as it stands; refuses one elsewhere or gone", ctx do
      %{scope: scope, workspace: main} = ctx
      other = workspace_fixture(scope.organisation, "Other")
      free = collection_fixture(scope, workspace_id: nil)
      elsewhere = collection_fixture(scope, workspace_id: other.id)
      theirs = collection_fixture(sign_up_fixture().scope, workspace_id: nil)
      targets!(free.adapter_id)

      row = fn c ->
        c = Repo.get!(Collection, c.id)
        {c.workspace_id, c.backlog}
      end

      assert WorkspaceSetup.tick(scope, main, @software, :destinations, free.id) == :ok
      assert row.(free) == {main.id, false}
      assert WorkspaceSetup.tick(scope, main, @software, :sources, free.id) == :ok
      assert row.(free) == {main.id, true}

      # Unticked as a work source, a destination stays assigned.
      assert WorkspaceSetup.tick(scope, main, @software, :sources, free.id) == :ok
      assert row.(free) == {main.id, false}
      assert WorkspaceSetup.tick(scope, main, @software, :destinations, free.id) == :ok
      assert row.(free) == {nil, false}

      assert WorkspaceSetup.tick(scope, main, @software, :sources, elsewhere.id) ==
               {:error, :elsewhere}

      assert row.(elsewhere) == {other.id, true}

      assert WorkspaceSetup.tick(scope, main, @software, :sources, theirs.id) ==
               {:error, :unlisted}

      assert WorkspaceSetup.tick(scope, main, @software, :sources, "not an id") ==
               {:error, :unlisted}

      %{scope: member} = member_fixture(scope, :member)
      member = %{member | workspace: main}

      assert WorkspaceSetup.tick(member, main, @software, :sources, free.id) ==
               {:error, :forbidden}

      assert row.(free) == {nil, false}
    end
  end
end
