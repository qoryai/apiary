defmodule Apiary.Dispatches.ImageMissingTest do
  # A run of a work item whose exit says the registry has no copy of the image its pool's
  # record gave it (`failed`, `image_missing`): the end of its run of the queue clears that
  # image from the pool's records for the run's target and queues a build of it; the run
  # of the queue ends as any failed run does (`Apiary.Dispatches.RunEnd`,
  # `Apiary.Environments.forget_image/3`).
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches.{DispatchRun, RunEnd}
  alias Apiary.Environments
  alias Apiary.Environments.Record
  alias Apiary.Runs.{Liveness, Projector, Run}

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
      queued_ref: "env-1",
      queued_at: now,
      queued_target_system: @target.system,
      queued_target_path: @target.path,
      image: @image,
      size: 734_003_200,
      commit: "9c1e4a7b",
      built_at: now,
      reported_ref: "env-1",
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
            ~w(image size commit built_at reported_ref built_target_system built_target_path built_queued_at)a
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
             built_queued_at: nil,
             queued_ref: "env-1",
             retired_at: nil
           } = record!(ctx)

    assert Environments.image_for(ctx.pool, @target) == nil
  end

  test "clears the image, queues a build of it, and queues no run of the work item", ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, @given)

    assert Environments.image_for(ctx.pool, @target) == @image
    exit!(run, @missing)

    assert %Run{state: "failed", exit_reason: "image_missing"} = Repo.get!(Run, run.id)
    assert_cleared(ctx)
    assert prebuilds(ctx) == [{:waiting, "env-1"}]
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
  end

  test "an image recorded again and missing again is cleared and queued again", ctx do
    %{run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)

    # The build that was queued ran and recorded the image again, which is missing again.
    {1, _rows} =
      Repo.update_all(
        from(d in DispatchRun,
          where: d.source_collection_id == ^ctx.collection.id and d.state == :waiting
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
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
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
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
  end

  test "a run that started in no recorded image clears nothing and queues nothing", ctx do
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(ctx.scope, ctx.key, Map.delete(@given, :configured_image))

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
    # A new pool's trigger made its record of the collection: replaced by one with the
    # same build.
    other_pool = pool_fixture(ctx.scope)
    Repo.delete_all(from r in Record, where: r.pool_id == ^other_pool.id)
    other = Repo.insert!(built_record(ctx.scope, other_pool, ctx.collection))

    %{run: run} = handed_over_fixture(ctx.scope, ctx.key, @given)
    exit!(run, @missing)

    assert_cleared(ctx)
    assert Repo.get!(Record, other.id) == other
  end
end
