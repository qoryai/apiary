defmodule Apiary.Dispatches.ImageMissingTest do
  # A run of a work item whose exit says the registry has no copy of the image its pool's
  # record gave it (`failed`, `image_missing`): the end of its run of the queue clears that
  # image from the pool's records for the run's target and queues a build of it; the run
  # of the queue ends as any failed run does, and the next run of its take in is queued
  # with the attempt total raised by one, once (`Apiary.Dispatches.RunEnd`,
  # `Apiary.Environments.forget_image/3`, `Apiary.Dispatches.requeue_for_image/1`).
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{Dispatches, ExploreInputsSchema}
  alias Apiary.Dispatches.{DispatchRun, Inputs, RunEnd}
  alias Apiary.Environments
  alias Apiary.Environments.Record
  alias Apiary.Runs.{Liveness, Projector, Run}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @missing %{"state" => "failed", "reason" => "image_missing", "exit_code" => -1}
  # The target of a work item of `work_item_fixture/2`.
  @target %{system: "forge.example.com", path: "acme/shop"}
  # A run started in `@image`, registered with the labels of that target.
  @given %{
    configured_image: @image,
    registration_labels: %{"forge" => "forge.example.com", "repository" => "acme/shop"}
  }

  # A node pool with its key, a collection of the work items' target with `env-1`, and
  # the pool's record of it with a good build of `@image` for that target.
  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)

    collection =
      collection_fixture(scope, target_system: @target.system, target_path: @target.path)

    record = Repo.insert!(built_record(scope, pool, collection))
    %{scope: scope, pool: pool, key: key, collection: collection, record: record}
  end

  defp built_record(scope, pool, collection) do
    now = DateTime.utc_now()

    %Record{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      pool_id: pool.id,
      source_collection_id: collection.id,
      image: @image,
      size: 734_003_200,
      commit: "9c1e4a7b",
      built_at: now,
      reported_ref: "env-1",
      built_ref: "env-1",
      built_target_system: @target.system,
      built_target_path: @target.path,
      built_queued_at: now
    }
  end

  defp record!(%{record: %Record{id: id}}), do: Repo.get!(Record, id)

  # The image recorded again on the record, as a build that landed since writes it.
  defp rebuilt!(ctx) do
    {1, _rows} =
      Repo.update_all(from(r in Record, where: r.id == ^ctx.record.id),
        set:
          Map.take(
            built_record(ctx.scope, ctx.pool, ctx.collection),
            ~w(image size commit built_at reported_ref built_ref built_target_system built_target_path built_queued_at)a
          )
          |> Map.to_list()
      )
  end

  # The run's exit, stored and folded onto it, which ends its run of the queue.
  defp exit!(run, data) do
    event_fixture(run, 9, "run.exited", data)
    assert {:ok, %Run{exited_at: %DateTime{}}} = Projector.project(run)
  end

  defp runs_of(work_item_id) do
    Repo.all(
      from d in DispatchRun,
        where: d.work_item_id == ^work_item_id,
        order_by: d.attempt,
        select: {d.attempt, d.state, d.end_cause}
    )
  end

  # The run of the queue of `work_item_id` with `attempt`.
  defp run_of(work_item_id, attempt),
    do:
      Repo.one!(
        from d in DispatchRun, where: d.work_item_id == ^work_item_id and d.attempt == ^attempt
      )

  defp prebuilds(ctx) do
    Repo.all(
      from d in DispatchRun,
        where: d.source_collection_id == ^ctx.collection.id and d.pool_id == ^ctx.pool.id,
        select: {d.state, d.environment_ref}
    )
  end

  defp assert_cleared(ctx) do
    assert %Record{
             image: nil,
             size: nil,
             commit: nil,
             built_at: nil,
             reported_ref: nil,
             built_target_system: nil,
             built_target_path: nil,
             built_queued_at: nil
           } = record!(ctx)

    assert Environments.image_for(ctx.pool, @target) == nil
  end

  test "clears the image, queues a build of it, and queues the next attempt with one more",
       ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, @given)

    assert Environments.image_for(ctx.pool, @target) == @image
    exit!(run, @missing)

    assert %Run{state: "failed", exit_reason: "image_missing"} = Repo.get!(Run, run.id)
    assert_cleared(ctx)
    assert prebuilds(ctx) == [{:waiting, "env-1"}]

    assert runs_of(dispatch_run.work_item_id) == [
             {1, :ended, :run_ended},
             {2, :waiting, nil}
           ]

    of = dispatch_run.of + 1

    assert %DispatchRun{take_in: take_in, of: ^of, image_requeue: true} =
             run_of(dispatch_run.work_item_id, 2)

    assert take_in == dispatch_run.take_in
    assert Dispatches.requeued_for_image?(Repo.get!(Run, run.id))
  end

  test "an image_missing of the run that requeue queued ends it without a requeue", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)
    requeued = run_of(dispatch_run.work_item_id, 2)

    # The build that was queued ran and recorded the image again, and the requeued run
    # was claimed and started in it.
    {1, _rows} =
      Repo.update_all(
        from(d in DispatchRun,
          where: d.source_collection_id == ^ctx.collection.id and d.state == :waiting
        ),
        set: [state: :ended, end_cause: :superseded]
      )

    rebuilt!(ctx)
    %{run: again} = handed_over(ctx.scope, ctx.key, requeued, @given)
    exit!(again, @missing)

    assert_cleared(ctx)

    assert runs_of(dispatch_run.work_item_id) == [
             {1, :ended, :run_ended},
             {2, :ended, :run_ended}
           ]

    refute Dispatches.requeued_for_image?(Repo.get!(Run, again.id))
  end

  # The explore input of the run of the queue `queued`, decoded, after it is checked
  # against the explore contract's `inputs.schema.json`.
  defp input!(queued) do
    work_item = Repo.get!(WorkItem, queued.work_item_id)
    {:ok, inputs} = Inputs.explore(work_item, queued, %{domain: "software", target: @target})
    inputs = inputs |> Jason.encode!() |> Jason.decode!()
    assert ExploreInputsSchema.validate(inputs) == :ok
    inputs
  end

  test "the input of the requeued run counts only the runs that started: attempt 1 of 3",
       ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    assert input!(dispatch_run)["run"] == %{"attempt" => 1, "of" => 3}
    exit!(run, @missing)

    requeued = run_of(dispatch_run.work_item_id, 2)
    assert %DispatchRun{attempt: 2, of: 4, image_requeue: true} = requeued
    assert input!(requeued)["run"] == %{"attempt" => 1, "of" => 3}
  end

  test "the input of the run after a requeued run that started: attempt 2 of 3", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)
    requeued = run_of(dispatch_run.work_item_id, 2)

    # The build that was queued ran and recorded the image again, and the requeued run
    # was claimed, started in it, and failed.
    {1, _rows} =
      Repo.update_all(
        from(d in DispatchRun,
          where: d.source_collection_id == ^ctx.collection.id and d.state == :waiting
        ),
        set: [state: :ended, end_cause: :superseded]
      )

    rebuilt!(ctx)
    %{run: again} = handed_over(ctx.scope, ctx.key, requeued, @given)
    exit!(again, %{"state" => "failed", "exit_code" => 1})

    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)

    {:ok, next} =
      Repo.transact(fn -> Dispatches.queue_next(work_item, dispatch_run.take_in) end)

    assert %DispatchRun{attempt: 3, of: 4, image_requeue: false} = next
    assert input!(next)["run"] == %{"attempt" => 2, "of" => 3}
  end

  test "an image recorded again and missing again is cleared and queued again", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)

    # The build that was queued ran and recorded the image again, which is missing again
    # for a run of another work item; the requeued run of the first ended.
    {2, _rows} =
      Repo.update_all(
        from(d in DispatchRun,
          where:
            d.source_collection_id == ^ctx.collection.id or
              d.work_item_id == ^dispatch_run.work_item_id,
          where: d.state == :waiting
        ),
        set: [state: :ended, end_cause: :superseded]
      )

    rebuilt!(ctx)

    %{run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)

    assert_cleared(ctx)
    assert {:waiting, "env-1"} in prebuilds(ctx)
  end

  test "an end that read the run before its exit was folded ends nothing", ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, @given)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          state: "failed",
          exit_state: "failed",
          exit_reason: "image_missing",
          exited_at: DateTime.utc_now()
        ]
      )

    # What `hold/1` returns for a run whose exit is not folded yet: nil.
    {:ok, changed} =
      Repo.transact(fn ->
        locked = RunEnd.lock(dispatch_run.id)
        locked_run = Repo.one(from r in Run, where: r.id == ^run.id, lock: "FOR UPDATE")
        {:ok, RunEnd.finish(locked, locked_run, :run_ended, DateTime.utc_now(), nil)}
      end)

    assert changed == []
    assert runs_of(dispatch_run.work_item_id) == [{1, :handed_over, nil}]
    assert record!(ctx) == ctx.record

    # The next check holds the image and ends it.
    Liveness.check(DateTime.utc_now())

    assert_cleared(ctx)

    assert runs_of(dispatch_run.work_item_id) == [
             {1, :ended, :run_ended},
             {2, :waiting, nil}
           ]
  end

  test "a record whose collection the end does not hold is cleared and queues no build",
       ctx do
    {:ok, []} =
      Repo.transact(fn ->
        {:ok, Environments.forget_image([record!(ctx)], [], DateTime.utc_now())}
      end)

    assert_cleared(ctx)
    assert prebuilds(ctx) == []
  end

  test "an image_missing whose end the lost-run check writes acts the same", ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, @given)

    # The exit folded, and the projection stopped before the end of the run of the queue.
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          state: "failed",
          exit_state: "failed",
          exit_reason: "image_missing",
          exited_at: DateTime.utc_now()
        ]
      )

    Liveness.check(DateTime.utc_now())

    assert_cleared(ctx)
    assert prebuilds(ctx) == [{:waiting, "env-1"}]

    assert runs_of(dispatch_run.work_item_id) == [
             {1, :ended, :run_ended},
             {2, :waiting, nil}
           ]
  end

  test "a run that started in no recorded image clears nothing and queues nothing", ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, Map.put(@given, :configured_image, nil))

    exit!(run, @missing)

    assert record!(ctx) == ctx.record
    assert prebuilds(ctx) == []
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
  end

  test "a failed exit for another reason clears nothing and queues nothing", ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, @given)

    exit!(run, %{"state" => "failed", "reason" => "no_session", "exit_code" => -1})

    assert record!(ctx) == ctx.record
    assert prebuilds(ctx) == []
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
  end

  test "the image of another pool is left", ctx do
    # A record of the collection for a second pool, with the same build.
    other_pool = pool_fixture(ctx.scope)
    Repo.delete_all(from r in Record, where: r.pool_id == ^other_pool.id)
    other = Repo.insert!(built_record(ctx.scope, other_pool, ctx.collection))

    %{run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)

    assert_cleared(ctx)
    assert Repo.get!(Record, other.id) == other
  end
end
