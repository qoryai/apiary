defmodule Apiary.WorkItems.TargetRowTest do
  # A work item's target is its target row (`work_items.target_id`): the joins from a
  # work item to the collections of its target read the row's adapter and collection ref,
  # never its address. Two collections of two adapters at one address are two targets,
  # and a work item of one gets nothing of the other: its work credential's collection
  # (`Apiary.Runs.RunCredentials`), its image and its hold (`Apiary.Environments`), why
  # its run waits (`Apiary.Runs.Waiting`), the run that built its environment
  # (`Apiary.Stages.StopCause.build_run/1`) and the end of its runs held for a build
  # (`Apiary.Dispatches.end_held/4`). Not async: a run's wait reads the instance's pool.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [registry_image: 2, workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Environments}
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Run, RunCredentials, Target, Waiting}
  alias Apiary.Stages.StopCause
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :registry]

  @system "code.example.com"
  @path "acme/shop"

  # Two collections of two adapters at one address, OTHER listed first, both with targets
  # and an `environment_ref`, and a work item whose target row is SHOP's.
  setup do
    %{scope: scope} = sign_up_fixture()
    workspace_gateway!(scope)
    pool = pool_fixture(scope)
    _key = enrolled_key_fixture(scope, pool)
    other = collection_fixture(scope, target_system: @system, target_path: @path)
    shop = collection_fixture(scope, target_system: @system, target_path: @path)

    {2, _rows} =
      Repo.update_all(from(n in Node, where: n.id in ^[other.adapter_id, shop.adapter_id]),
        set: [targets: true]
      )

    %{scope: scope, pool: pool, other: other, shop: shop, work_item: of(scope, shop)}
  end

  # A work item taken in through `collection`'s connection, whose target is that
  # collection's.
  defp of(scope, %Collection{} = collection) do
    work_item_fixture(scope, %{
      connection_id: collection.connection_id,
      target_collection_external_ref: collection.target_collection_external_ref,
      target_system: @system,
      target_path: @path
    })
  end

  defp queue!(work_item) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
    run
  end

  defp image(ctx, n), do: registry_image(ctx.scope.organisation.id, String.duplicate(n, 64))

  # The pool's record of `collection`, built for its address from its `environment_ref`,
  # with the image `n`, written over the record a prebuild made.
  defp built!(ctx, collection, n) do
    now = DateTime.utc_now()

    %Record{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      pool_id: ctx.pool.id,
      source_collection_id: collection.id,
      image: image(ctx, n),
      size: 1_048_576,
      commit: "4b7d0a3f",
      built_at: now,
      reported_ref: "env-1",
      built_ref: "env-1",
      built_target_system: @system,
      built_target_path: @path,
      built_queued_at: now
    }
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:pool_id, :source_collection_id]
    )
  end

  defp held?(ctx, run) do
    Repo.exists?(
      from r in DispatchRun,
        as: :run,
        where: r.id == ^run.id,
        where: exists(Environments.held(ctx.pool.id))
    )
  end

  # A prebuild of `collection` for the pool, with its run registered: the run.
  defp registered_build!(ctx, collection) do
    {:ok, build} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    %Run{
      number: Apiary.RunEventsFixtures.next_run_number(build.organisation_id, build.workspace_id),
      organisation_id: build.organisation_id,
      workspace_id: build.workspace_id,
      node_run_id: build.run_id,
      dispatch_run_id: build.id
    }
    |> Ecto.Changeset.change(state: "running", started_at: DateTime.utc_now())
    |> Apiary.RunEventsFixtures.insert_run!()
  end

  test "the work credential's collection is the target row's, not the one listed first at the address",
       ctx do
    run = queue!(ctx.work_item)

    assert {%Collection{id: id}, _connection, _adapter} =
             RunCredentials.work_collection(run, ctx.work_item, WorkItem.target(ctx.work_item))

    assert id == ctx.shop.id
  end

  test "the hold, the image, the wait and the build run read the target row's collection",
       ctx do
    run = queue!(ctx.work_item)

    # An image of the collection at the same address of another adapter holds the run
    # all the same, and is not given.
    built!(ctx, ctx.other, "1")
    assert held?(ctx, run)
    assert Environments.claim_image(ctx.pool, ctx.work_item) == :held

    # Its build is not the run's.
    other_build = registered_build!(ctx, ctx.other)
    assert Waiting.reason(Repo.get!(DispatchRun, run.id)) == {:image, @path, nil}
    assert StopCause.build_run(ctx.work_item) == nil

    shop_build = registered_build!(ctx, ctx.shop)
    assert Waiting.reason(Repo.get!(DispatchRun, run.id)) == {:image, @path, :queued}
    assert StopCause.build_run(ctx.work_item) == shop_build.public_id
    assert other_build.public_id != shop_build.public_id

    built!(ctx, ctx.shop, "2")
    refute held?(ctx, run)
    assert Environments.claim_image(ctx.pool, ctx.work_item) == {:ok, image(ctx, "2")}
  end

  test "a failed build ends the held runs of the work items of its target row alone", ctx do
    shop_run = queue!(ctx.work_item)
    other_item = of(ctx.scope, ctx.other)
    other_run = queue!(other_item)

    {:ok, _told} =
      Repo.transact(fn ->
        {:ok,
         Dispatches.end_held(
           [ctx.work_item.id, other_item.id],
           ctx.scope.workspace.id,
           ctx.work_item.target_id,
           DateTime.utc_now()
         )}
      end)

    assert %DispatchRun{state: :ended, end_cause: :build_failed} =
             Repo.get!(DispatchRun, shop_run.id)

    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, other_run.id)
  end

  test "deleting the target row leaves the work item without a target", ctx do
    Repo.delete!(Repo.get!(Target, ctx.work_item.target_id))

    work_item = Repo.get!(WorkItem, ctx.work_item.id)
    assert work_item.target_id == nil
    assert WorkItem.target(work_item) == nil
  end
end
