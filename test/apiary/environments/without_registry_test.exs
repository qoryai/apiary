defmodule Apiary.Environments.WithoutRegistryTest do
  # On an instance without a registry (`Apiary.Registry.configured?/0`), no prebuild is
  # queued or claimed, no run is held for one, and an explore run starts in its pool's
  # default image, whatever image a record has. Not async: the features are the whole
  # node's.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Environments}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Runs.Target

  @moduletag needs: :factory

  setup {Apiary.DataCase, :without_registry}

  @target %{system: "code.example.com", path: "acme/shop"}

  # A pool that claims through a gateway, and a collection of the target with `env-1`.
  setup do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope)

    collection =
      collection_fixture(scope, target_system: @target.system, target_path: @target.path)

    %{scope: scope, place: place, collection: collection}
  end

  defp prebuilds(ctx) do
    Repo.all(
      from d in DispatchRun,
        where: d.source_collection_id == ^ctx.collection.id,
        select: {d.state, d.environment_ref}
    )
  end

  defp explore!(ctx) do
    work_item =
      work_item_fixture(ctx.scope, %{target_system: @target.system, target_path: @target.path})

    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {work_item, run}
  end

  test "holds no run and queues no build: the claim takes the run, in the pool's default image",
       ctx do
    refute Apiary.Registry.configured?()
    {work_item, run} = explore!(ctx)

    refute Environments.holds?(ctx.scope.workspace.id)
    assert Environments.claim_image(ctx.place.pool, work_item) == {:ok, nil}

    assert {:ok, %{run: taken, registered: registered}} =
             Dispatches.claim(ctx.place.key, Dispatches.now())

    assert taken.id == run.id
    assert registered.configured_image == nil
    assert prebuilds(ctx) == []
  end

  test "a prebuild queued while the registry was there is not claimed", ctx do
    {:ok, prebuild} =
      Repo.transact(fn -> Dispatches.queue_prebuild(ctx.collection, ctx.place.pool, "env-1") end)

    assert Dispatches.claim(ctx.place.key, Dispatches.now()) == {:ok, :none}
    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, prebuild.id)

    # A run of the target behind it is taken, and the prebuild still waits.
    {_work_item, run} = explore!(ctx)
    assert {:ok, %{run: taken}} = Dispatches.claim(ctx.place.key, Dispatches.now())
    assert taken.id == run.id
    assert prebuilds(ctx) == [{:waiting, "env-1"}]
  end

  test "an image a record has is given to no run", ctx do
    now = DateTime.utc_now()

    Repo.insert!(%Record{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      pool_id: ctx.place.pool.id,
      source_collection_id: ctx.collection.id,
      image: "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("4", 64),
      size: 1_048_576,
      commit: "4b7d0a3f",
      built_at: now,
      reported_ref: "env-1",
      built_ref: "env-1",
      built_target_system: @target.system,
      built_target_path: @target.path,
      built_queued_at: now
    })

    {work_item, _run} = explore!(ctx)
    assert Environments.image_for(ctx.place.pool, @target) == nil
    assert Environments.claim_image(ctx.place.pool, work_item) == {:ok, nil}
  end

  test "a Rebuild queues no build", ctx do
    :ok = Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [@target])
    target = Repo.get_by!(Target, workspace_id: ctx.scope.workspace.id, path: @target.path)

    assert Environments.rebuild(ctx.scope, target) == {:error, :not_found}
    assert prebuilds(ctx) == []
  end
end
