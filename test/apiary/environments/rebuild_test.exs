defmodule Apiary.Environments.RebuildTest do
  # A member's Rebuild of a target's environment (`Apiary.Environments.rebuild/2`): a
  # prebuild queued for each node pool of the target's workspace, changed or not, held for
  # the pool, with its record made; nothing for a pool whose prebuild of the collection's
  # ref waits unclaimed; one audit entry about the target with how many it queued,
  # none when it queued none; every member may, and a target that names no environment
  # there, a workspace without a pool, and a target of another workspace are not found.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Dispatches, Environments, Repo, Targets}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Runs.Target

  @moduletag needs: :factory

  @system "code.example.com"
  @path "acme/shop"

  # Two node pools, then a target of the workspace and a collection assigned there with it
  # and the `environment_ref` `env-1`, made after the pools, so nothing is queued yet.
  setup do
    %{scope: scope} = sign_up_fixture()
    _gateway = workspace_gateway!(scope)
    mac = pool_fixture(scope, name: "mac-pool")
    linux = pool_fixture(scope, name: "linux-pool")
    shop = shop_collection(scope)

    %{scope: scope, mac: mac, linux: linux, shop: shop, target: target(scope)}
  end

  defp shop_collection(scope, attrs \\ []) do
    collection_fixture(
      scope,
      Keyword.merge(
        [
          external_ref: "SHOP",
          target_system: @system,
          target_path: @path,
          environment_ref: "env-1"
        ],
        attrs
      )
    )
  end

  defp target(scope) do
    :ok =
      Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: @system, path: @path}
      ])

    Targets.get(scope, @system, @path)
  end

  # The prebuilds of `collection` that wait, `{pool_id, environment_ref}` by pool.
  defp waiting(collection) do
    Repo.all(
      from r in DispatchRun,
        where: r.step == ^DispatchRun.prebuild() and r.source_collection_id == ^collection.id,
        where: r.state == :waiting,
        order_by: r.pool_id,
        select: {r.pool_id, r.environment_ref}
    )
  end

  defp waiting_ids(collection) do
    Repo.all(
      from r in DispatchRun,
        where: r.step == ^DispatchRun.prebuild() and r.source_collection_id == ^collection.id,
        where: r.state == :waiting,
        order_by: r.id,
        select: r.id
    )
  end

  defp entries(target) do
    Repo.all(
      from e in Entry,
        where: e.action == "target.rebuild_environment" and e.subject_id == ^target.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp sorted(pools), do: pools |> Enum.map(& &1.id) |> Enum.sort()

  test "queues a prebuild for each node pool, held for it, and makes each record",
       %{scope: scope, mac: mac, linux: linux, shop: shop, target: target} do
    assert Environments.rebuild(scope, target) == {:ok, 2}

    assert waiting(shop) == Enum.map(sorted([mac, linux]), &{&1, "env-1"})

    for pool <- [mac, linux] do
      assert %Record{image: nil, built_ref: nil} = Environments.fetch(pool.id, shop.id)
    end
  end

  test "leaves one audit entry about the target, with how many it queued, and none when it queued none",
       %{scope: scope, target: target} do
    {:ok, 2} = Environments.rebuild(scope, target)

    assert [entry] = entries(target)
    assert entry.subject_kind == "target"
    assert entry.workspace_id == scope.workspace.id
    assert entry.details == %{"count" => 2}

    assert Environments.rebuild(scope, target) == {:ok, 0}
    assert [^entry] = entries(target)
  end

  test "changed or not: a record queued for the same ref and target, its prebuild claimed, is queued again",
       %{scope: scope, mac: mac, linux: linux, shop: shop, target: target} do
    _queued = Apiary.DispatchedRunsFixtures.queue_builds!(shop)

    %{access_key: key} = enrolled_key_fixture(scope, mac)
    {:ok, %{run: claimed}} = Dispatches.claim(key, Dispatches.now())
    assert claimed.pool_id == mac.id
    [linux_waiting] = waiting_ids(shop)

    assert Environments.rebuild(scope, target) == {:ok, 1}

    assert waiting(shop) == Enum.map(sorted([mac, linux]), &{&1, "env-1"})
    assert linux_waiting in waiting_ids(shop)
    assert %DispatchRun{state: :claimed} = Repo.get!(DispatchRun, claimed.id)
  end

  test "does nothing for a pool whose prebuild waits unclaimed; every pool's waiting, it queues none",
       %{scope: scope, mac: mac, linux: linux, shop: shop, target: target} do
    {:ok, {:ok, _run}} =
      Repo.transact(fn -> {:ok, Dispatches.queue_prebuild(shop, mac, "env-1")} end)

    [mac_waiting] = waiting_ids(shop)
    record_before = Environments.fetch(mac.id, shop.id)

    assert Environments.rebuild(scope, target) == {:ok, 1}
    assert waiting(shop) == Enum.map(sorted([mac, linux]), &{&1, "env-1"})
    assert mac_waiting in waiting_ids(shop)
    assert Environments.fetch(mac.id, shop.id) == record_before

    ids = waiting_ids(shop)
    assert Environments.rebuild(scope, target) == {:ok, 0}
    assert waiting_ids(shop) == ids
  end

  test "queues for each collection of the target that names an environment, and leaves out the others",
       %{scope: scope, mac: mac, linux: linux, shop: shop, target: target} do
    second = shop_collection(scope, external_ref: "SHOP2", environment_ref: "env-9")
    none = shop_collection(scope, external_ref: "SHOP3", environment_ref: nil)
    other = workspace_fixture(scope.organisation)
    elsewhere = shop_collection(scope, external_ref: "SHOP4", workspace_id: other.id)

    ended =
      shop_collection(scope, external_ref: "SHOP5")
      |> Ecto.Changeset.change(ended_at: DateTime.utc_now(), ended_reason: :disconnected)
      |> Repo.update!()

    assert Environments.rebuild(scope, target) == {:ok, 4}
    assert waiting(shop) == Enum.map(sorted([mac, linux]), &{&1, "env-1"})
    assert waiting(second) == Enum.map(sorted([mac, linux]), &{&1, "env-9"})

    for left_out <- [none, elsewhere, ended], do: assert(waiting(left_out) == [])
  end

  test "every member may", %{scope: scope, target: target} do
    %{scope: member} = member_fixture(scope, :member)
    assert Environments.rebuild(member, target) == {:ok, 2}
  end

  test "a person no longer a member is refused, and nothing is queued",
       %{scope: scope, shop: shop, target: target} do
    %{scope: member, membership: membership} = member_fixture(scope, :member)
    {:ok, _removed} = Apiary.Organisations.remove_member(scope, membership.id)

    assert {:error, _refused} = Environments.rebuild(member, target)
    assert waiting(shop) == []
    assert entries(target) == []
  end

  test "not found: a target whose collections name no environment, or none assigned to its workspace",
       %{scope: scope, shop: shop, target: target} do
    shop |> Ecto.Changeset.change(environment_ref: nil) |> Repo.update!()
    assert Environments.rebuild(scope, target) == {:error, :not_found}

    shop |> Ecto.Changeset.change(environment_ref: "env-1", workspace_id: nil) |> Repo.update!()
    assert Environments.rebuild(scope, target) == {:error, :not_found}
    assert waiting(shop) == []
    assert entries(target) == []
  end

  test "not found: a workspace without a node pool", %{scope: scope, mac: mac, linux: linux} do
    for pool <- [mac, linux], do: {:ok, _deleted} = Apiary.Nodes.delete_node(scope, pool)
    assert Environments.rebuild(scope, target(scope)) == {:error, :not_found}
  end

  test "not found: a workspace whose domain has no prebuilds, and the target's page shows none",
       %{scope: scope, shop: shop, target: target} do
    scope = with_domain(scope, "general")
    assert Environments.rebuild(scope, target) == {:error, :not_found}
    assert waiting(shop) == []
    assert entries(target) == []
    assert Environments.section(scope, target) == nil
  end

  test "not found: a target of another workspace, or of another organisation",
       %{scope: scope, shop: shop, target: target} do
    second = workspace_fixture(scope.organisation)
    owner_there = %{scope | workspace: second}
    assert Environments.rebuild(owner_there, target) == {:error, :not_found}

    %{scope: other} = sign_up_fixture()
    assert Environments.rebuild(other, target) == {:error, :not_found}

    assert waiting(shop) == []
    assert entries(target) == []
  end

  test "the action: members, the feature factory, asked of the workspace, audited" do
    assert %Apiary.Access.Action{
             feature: :factory,
             roles: [:owner, :admin, :member],
             audited: true,
             asked_of: :workspace,
             what: "rebuild the environment of a target"
           } = Apiary.Access.action(:"target.rebuild_environment")
  end
end
