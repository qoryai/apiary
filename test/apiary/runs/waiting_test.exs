defmodule Apiary.Runs.WaitingTest do
  # Why a queued run waits (`Apiary.Runs.Waiting.reason/2`), the first reason that applies: its
  # harness walk, no pool ready, no pool for its machine type, its target's environment
  # image, every pool at its limit, runs queued before it, else the pool that has not
  # taken it yet. Not async: a machine type and the instance's pool are the instance's.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [walked_claim: 2, workspace_gateway!: 1]
  import Apiary.MachineTypesFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Runs.Waiting

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  # A workspace pool with an enrolled key, through the workspace's gateway.
  defp ready_pool!(scope, attrs \\ %{}) do
    workspace_gateway!(scope)
    pool = pool_fixture(scope, attrs)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    {pool, key}
  end

  defp queue!(scope, attrs \\ %{}) do
    work_item = work_item_fixture(scope, attrs)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    # With the workflow model a run waits for its harness walk, which no adapter reads here.
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
    run
  end

  defp reason(%DispatchRun{id: id}), do: Waiting.reason(Repo.get!(DispatchRun, id))

  # A run queued on the type `large`, whose spec no offer of `pool` fits.
  defp no_fit!(scope, pool) do
    run = queue!(scope)

    Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
      set: [machine_type: "large", machine_spec: spec(), machine_type_was_default: false]
    )

    with_offers(pool, [spec(%{arch: "arm64"})])
    run
  end

  test "with nothing else in its way, the pool that has not taken it yet", %{scope: scope} do
    {pool, _key} = ready_pool!(scope, %{name: "build-pool"})
    run = queue!(scope)
    assert reason(run) == {:pool, pool.name}
  end

  test "with runs of the workspace queued before it, how many", %{scope: scope} do
    ready_pool!(scope)
    first = queue!(scope)
    second = queue!(scope)
    third = queue!(scope)

    assert {:pool, _name} = reason(first)
    assert reason(second) == {:behind, 1}
    assert reason(third) == {:behind, 2}
  end

  test "while its harness walk is not resolved, the harness, before any other reason",
       %{scope: scope} do
    run = queue!(scope)

    Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^run.id),
      set: [state: :pending, origin: nil]
    )

    assert reason(run) == :harness

    Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^run.id),
      set: [state: :resolved, origin: :none]
    )

    assert reason(run) == :no_pool
  end

  test "with no pool ready, no pool", %{scope: scope} do
    run = queue!(scope)
    assert reason(run) == :no_pool
  end

  test "with no ready pool that starts its machine type, the type's key and the first pool",
       %{scope: scope} do
    {pool, _key} = ready_pool!(scope)

    machine_type_fixture(%{
      name: "large",
      vcpus: 4,
      memory_mib: 16_384,
      disk_gib: 60,
      arch: "amd64"
    })

    run = queue!(scope)

    Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
      set: [machine_type: "large", machine_spec: spec(), machine_type_was_default: false]
    )

    with_offers(pool, [spec(%{arch: "arm64"})])
    assert reason(run) == {:no_fit, "large", pool.name}
  end

  test "with no pool that starts its machine type, a workspace's pool named Qory Pool by its name",
       %{scope: scope} do
    {pool, _key} = ready_pool!(scope, %{name: "Qory Pool"})
    machine_type_fixture(%{name: "large"})
    run = no_fit!(scope, pool)
    assert reason(run) == {:no_fit, "large", "Qory Pool"}
  end

  # An environment image is built and stored through the registry.
  @tag needs: [:factory, :registry]
  test "held for its target's environment image: queued, running, or none live",
       %{scope: scope} do
    {pool, key} = ready_pool!(scope)
    collection = collection_fixture(scope)

    run =
      queue!(scope, %{
        target_system: collection.target_system,
        target_path: collection.target_path
      })

    assert reason(run) == {:image, collection.target_path, nil}

    {:ok, _prebuild} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-1") end)

    assert reason(run) == {:image, collection.target_path, :queued}

    assert {:ok, %{run: %{step: "prebuild"}}} = walked_claim(key, Dispatches.now())
    assert reason(run) == {:image, collection.target_path, :running}
  end

  test "with every pool at its limit, the pool, its machines in use and its limit",
       %{scope: scope} do
    {pool, key} = ready_pool!(scope, %{instance_limit: 1})
    queue!(scope)
    assert {:ok, %{run: %DispatchRun{}}} = walked_claim(key, Dispatches.now())

    run = queue!(scope)
    assert reason(run) == {:busy, pool.name, 1, 1}
  end

  @tag needs: [:factory, :secrets]
  test "while every key of its model providers is in cooldown, the provider and the first end",
       %{scope: scope} do
    {_pool, _key} = ready_pool!(scope)

    {:ok, main} =
      Apiary.Connections.create_provider(scope, %{
        provider: "anthropic",
        name: "Team keys",
        keys: [
          %{value_id: "main", value: "sk-ant-waiting-main"},
          %{value_id: "spare", value: "sk-ant-waiting-spare"}
        ]
      })

    {:ok, fallback} =
      Apiary.Connections.create_provider(scope, %{
        provider: "anthropic",
        name: "Spare keys",
        keys: [%{value_id: "main", value: "sk-ant-waiting-fallback"}]
      })

    {:ok, _choice} =
      Apiary.ModelChoices.put_choice(scope, :workspace, %{
        provider: main.public_id,
        fallbacks: [%{provider: fallback.public_id}]
      })

    run = queue!(scope)
    cooling!(main, in_seconds(3600))

    # The fallback has a free key: the run does not wait for a key.
    assert {:pool, _name} = reason(run)

    # The fallback's key leaves its cooldown first: the reason has its provider and end.
    first = in_seconds(1800)
    cooling!(fallback, first)
    assert {:cooldown, "Spare keys", until} = reason(run)
    assert DateTime.compare(until, first) == :eq
  end

  @tag needs: [:factory, :secrets]
  test "while every key of an operator's provider is in cooldown, the first end alone",
       %{scope: scope} do
    {_pool, _key} = ready_pool!(scope)
    %{scope: operator} = sign_up_fixture()

    {:ok, theirs} =
      Apiary.Connections.create_provider(operator, %{
        provider: "anthropic",
        name: "Operator keys",
        keys: [%{value_id: "main", value: "sk-ant-waiting-operator"}]
      })

    run = queue!(scope)

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [model_provider_ids: [theirs.id]]
      )

    first = in_seconds(1800)
    cooling!(theirs, first)
    assert {:cooldown, nil, until} = reason(run)
    assert DateTime.compare(until, first) == :eq
  end

  describe "the instance's pool" do
    setup do
      gateway = instance_gateway_fixture()
      installed_key_fixture(gateway, allow_secrets: true)
      pool = instance_pool_fixture(%{instance_limit: 1})
      %{access_key: key} = installed_key_fixture(pool)
      %{key: key, pool: pool}
    end

    test "with no offer that fits the machine type, the instance's pool by its place",
         %{scope: scope, pool: pool} do
      machine_type_fixture(%{name: "large"})
      run = no_fit!(scope, pool)
      assert reason(run) == {:no_fit, "large", :instance}
    end

    test "is Qory Pool, and at its limit has no numbers", %{scope: scope, key: key} do
      first = queue!(scope)
      assert reason(first) == {:pool, "Qory Pool"}

      assert {:ok, %{run: %DispatchRun{}}} = walked_claim(key, Dispatches.now())
      run = queue!(scope)
      assert reason(run) == {:busy, :instance}
    end
  end
end
