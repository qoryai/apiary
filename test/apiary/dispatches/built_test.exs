defmodule Apiary.Dispatches.BuiltTest do
  # The image a prebuild reports in its record, `dev.qory.run.built`
  # (`Apiary.Dispatches.Built`): stored on the environment record of its pool and
  # collection once a projection folds it, whether its run of the queue has ended or not,
  # and from a prebuild alone.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Built, DispatchRun}
  alias Apiary.Environments.Record
  alias Apiary.Runs.{Liveness, Projector, Run}

  @moduletag needs: :factory

  @old_image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("7a1c", 16)
  @commit String.duplicate("4e1c9b0a", 5)

  # The data of a report of `@image`.
  defp built(attrs \\ %{}) do
    Map.merge(
      %{
        "image" => @image,
        "size" => 734_003_200,
        "commit" => @commit,
        "environment_ref" => "env-1"
      },
      attrs
    )
  end

  # A collection with a target, the pool's environment record of it, `env-1` queued and a
  # good build of `@old_image` kept, and a prebuild of it queued for a pool with a gateway,
  # claimed and handed over: its registered run.
  setup do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope)
    collection = collection_fixture(scope, target_system: "code.example.com")

    record =
      Repo.insert!(%Record{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        pool_id: place.pool.id,
        source_collection_id: collection.id,
        image: @old_image,
        size: 1000,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1",
        built_ref: "env-1",
        failure_cause: :lost,
        failed_at: DateTime.utc_now()
      })

    {:ok, _queued} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, place.pool, "env-1") end)

    %{run: dispatch_run, registered: run} = dispatched!(place.key)

    %{
      scope: scope,
      place: place,
      collection: collection,
      record: record,
      dispatch_run: dispatch_run,
      run: run
    }
  end

  defp record!(%{record: %Record{id: id}}), do: Repo.get!(Record, id)
  defp queue_run!(%{dispatch_run: %DispatchRun{id: id}}), do: Repo.get!(DispatchRun, id)

  defp report!(ctx, data \\ built(), sequence \\ 5) do
    event_fixture(ctx.run, sequence, "run.built", data)
    assert {:ok, %Run{}} = Projector.project(ctx.run)
  end

  defp exit!(ctx, data) do
    event_fixture(ctx.run, 9, "run.exited", data)
    assert {:ok, %Run{exited_at: %DateTime{}}} = Projector.project(ctx.run)
  end

  # The record holds the build the prebuild of `ctx` reported, and no failure.
  defp assert_stored(ctx) do
    collection = ctx.collection

    assert %Record{
             image: @image,
             size: 734_003_200,
             commit: @commit,
             reported_ref: "env-1",
             built_ref: "env-1",
             built_at: %DateTime{},
             built_target_system: "code.example.com",
             built_target_path: path,
             built_queued_at: built_queued_at,
             failure_cause: nil,
             failure_reason: nil,
             failed_at: nil
           } = record!(ctx)

    assert path == collection.target_path
    assert built_queued_at == queue_run!(ctx).environment_ref_at
  end

  test "a prebuild's report, once folded, stores its image on the record of its pool and collection",
       ctx do
    report!(ctx)
    assert_stored(ctx)

    # The report ends nothing of the queue.
    assert %DispatchRun{state: :handed_over} = queue_run!(ctx)

    # A run of the pool for that target is given the image.
    assert Apiary.Environments.image_for(ctx.place.pool, %{
             system: "code.example.com",
             path: ctx.collection.target_path
           }) == @image
  end

  test "a report and a failed exit folded together store the image and record no failure",
       ctx do
    event_fixture(ctx.run, 5, "run.built", built())
    exit!(ctx, %{"state" => "failed", "exit_code" => 1})

    assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(ctx)
    assert_stored(ctx)
  end

  test "a report that arrives after the exit ended the prebuild is stored, the exit's failure cleared",
       ctx do
    exit!(ctx, %{"state" => "failed", "exit_code" => 1})
    assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(ctx)
    assert %Record{failure_cause: :failed, image: @old_image} = record!(ctx)

    # Its sequence is lower than the exit's: it was sent first and arrived last.
    report!(ctx)
    assert_stored(ctx)
    assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(ctx)
  end

  test "a report that arrives after the lost-run check ended the prebuild is stored", ctx do
    Liveness.check(DateTime.add(ctx.run.attach_by, 1, :second))
    assert %DispatchRun{state: :ended, end_cause: :lost} = queue_run!(ctx)

    report!(ctx)
    assert_stored(ctx)
  end

  test "a second projection of the report writes nothing again", ctx do
    report!(ctx)
    stored = record!(ctx)

    assert Built.record(Repo.get!(Run, ctx.run.id)) == :kept
    assert {:ok, _run} = Projector.rebuild(Repo.get!(Run, ctx.run.id))
    assert record!(ctx) == stored
  end

  test "an image cleared as missing is not stored again by a later projection or a rebuild",
       ctx do
    report!(ctx)

    {:ok, []} =
      Repo.transact(fn ->
        {:ok, Apiary.Environments.forget_image([record!(ctx)], [], DateTime.utc_now())}
      end)

    assert %Record{image: nil, built_queued_at: nil} = cleared = record!(ctx)

    # A second report, with a higher sequence, folded by a later pass.
    report!(ctx, built(), 7)
    assert record!(ctx) == cleared

    assert {:ok, _run} = Projector.rebuild(Repo.get!(Run, ctx.run.id))
    assert record!(ctx) == cleared
  end

  test "a report of a ref older than the record's image's leaves the record", ctx do
    newer = DateTime.add(ctx.dispatch_run.environment_ref_at, 60, :second)

    {1, _rows} =
      Repo.update_all(from(r in Record, where: r.id == ^ctx.record.id),
        set: [built_queued_at: newer]
      )

    kept = record!(ctx)
    report!(ctx)
    assert record!(ctx) == kept
  end

  test "a report that breaks its rules records nothing", ctx do
    for data <- [
          built(%{"image" => "registry.example.com/acme/shop-env:latest"}),
          built(%{
            "image" => "Registry.example.com/acme/env@sha256:" <> String.duplicate("a", 64)
          }),
          built(%{"size" => 0}),
          built(%{"size" => "734003200"}),
          built(%{"commit" => String.upcase(@commit)}),
          built(%{"commit" => String.duplicate("a", 39)}),
          built(%{"environment_ref" => ""}),
          built(%{"environment_ref" => String.duplicate("e", 201)}),
          Map.delete(built(), "environment_ref"),
          %{}
        ] do
      Repo.delete_all(from e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id)
      event_fixture(ctx.run, 5, "run.built", data)
      assert Built.record(Repo.get!(Run, ctx.run.id)) == :refused
      assert record!(ctx) == ctx.record
    end
  end

  test "of two reports of one run, the lower sequence counts", ctx do
    event_fixture(ctx.run, 6, "run.built", built(%{"image" => @old_image, "size" => 1}))
    report!(ctx, built(), 5)
    assert_stored(ctx)
  end

  test "the report of a run that is not a prebuild records nothing", ctx do
    %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.place.pool)
    %{run: explore} = handed_over_fixture(ctx.scope, key)

    event_fixture(explore, 5, "run.built", built())
    assert {:ok, %Run{}} = Projector.project(explore)
    assert Built.record(Repo.get!(Run, explore.id)) == :refused
    assert record!(ctx) == ctx.record

    # Nor does a run a node registered itself.
    node_run = run_fixture(ctx.scope)
    event_fixture(node_run, 5, "run.built", built())
    assert {:ok, %Run{}} = Projector.project(node_run)
    assert Built.record(Repo.get!(Run, node_run.id)) == :refused
    assert record!(ctx) == ctx.record
  end

  test "a run with no report records nothing", ctx do
    assert Built.record(ctx.run) == :none
    assert record!(ctx) == ctx.record
  end

  @tag :contract
  test "the data of Forager's fixture of the report is stored", ctx do
    [%{"type" => "dev.qory.run.built", "data" => data}] =
      Apiary.ContractFixtures.contract_dir()
      |> Path.join("fixtures/batch/built-sha256-commit.json")
      |> File.read!()
      |> Jason.decode!()

    report!(ctx, data)

    assert %Record{image: image, size: size, commit: commit, reported_ref: ref} = record!(ctx)

    assert {image, size, commit, ref} ==
             {data["image"], data["size"], data["commit"], data["environment_ref"]}
  end
end
