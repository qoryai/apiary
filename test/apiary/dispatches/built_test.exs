defmodule Apiary.Dispatches.BuiltTest do
  # The image a prebuild reports in its record, `dev.qory.run.built`
  # (`Apiary.Dispatches.Built`): stored on the environment record of its pool and
  # collection once a projection folds it, whether its run of the queue has ended or not,
  # from a prebuild alone, and only at the place in the registry its claim sent it.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Built, DispatchRun}
  alias Apiary.Environments.Record
  alias Apiary.Runs.{Liveness, Projector, Run}

  # A prebuild's claim sends it its destinations only with the registry.
  @moduletag needs: [:factory, :registry]

  @old_digest String.duplicate("3b9d", 16)
  @digest String.duplicate("7a1c", 16)
  @commit String.duplicate("4e1c9b0a", 5)

  # The data of a report of the image at the run's `image_destination`.
  defp built(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        "image" => ctx.image,
        "size" => 734_003_200,
        "commit" => @commit,
        "environment_ref" => "env-1"
      },
      attrs
    )
  end

  # A collection with a target, the pool's environment record of it, `env-1` queued and a
  # good build of an older image kept, and a prebuild of it queued for a pool with a
  # gateway, claimed and handed over: its registered run, and the image at its
  # `image_destination`.
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
        image: registry_image(scope.organisation.id, @old_digest),
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
      run: run,
      image: destination_image(run, @digest)
    }
  end

  defp record!(%{record: %Record{id: id}}), do: Repo.get!(Record, id)
  defp queue_run!(%{dispatch_run: %DispatchRun{id: id}}), do: Repo.get!(DispatchRun, id)

  defp report!(ctx, data \\ nil, sequence \\ 5) do
    event_fixture(ctx.run, sequence, "run.built", data || built(ctx))
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
             image: image,
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

    assert image == ctx.image
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
           }) == ctx.image
  end

  test "a report and a failed exit folded together store the image and record no failure",
       ctx do
    event_fixture(ctx.run, 5, "run.built", built(ctx))
    exit!(ctx, %{"state" => "failed", "exit_code" => 1})

    assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(ctx)
    assert_stored(ctx)
  end

  test "a report that arrives after the exit ended the prebuild is stored, the exit's failure cleared",
       ctx do
    exit!(ctx, %{"state" => "failed", "exit_code" => 1})
    assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(ctx)
    assert %Record{failure_cause: :failed, image: old_image} = record!(ctx)
    assert old_image == ctx.record.image

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
    report!(ctx, built(ctx), 7)
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
          built(ctx, %{"image" => "registry.example.com/acme/shop-env:latest"}),
          built(ctx, %{
            "image" => "Registry.example.com/acme/env@sha256:" <> String.duplicate("a", 64)
          }),
          built(ctx, %{"size" => 0}),
          built(ctx, %{"size" => "734003200"}),
          built(ctx, %{"commit" => String.upcase(@commit)}),
          built(ctx, %{"commit" => String.duplicate("a", 39)}),
          built(ctx, %{"environment_ref" => ""}),
          built(ctx, %{"environment_ref" => String.duplicate("e", 201)}),
          built(ctx, %{"environment_image" => "registry.example.com/acme/env:latest"}),
          built(ctx, %{"environment_image" => 1}),
          Map.delete(built(ctx), "environment_ref"),
          %{}
        ] do
      Repo.delete_all(from e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id)
      event_fixture(ctx.run, 5, "run.built", data)
      assert Built.record(Repo.get!(Run, ctx.run.id)) == :refused
      assert record!(ctx) == ctx.record
    end
  end

  test "of two reports of one run, the lower sequence counts", ctx do
    event_fixture(ctx.run, 6, "run.built", built(ctx, %{"size" => 1}))
    report!(ctx, built(ctx), 5)
    assert_stored(ctx)
  end

  test "the report of a run that is not a prebuild records nothing", ctx do
    %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.place.pool)
    %{run: explore} = handed_over_fixture(ctx.scope, key)

    event_fixture(explore, 5, "run.built", built(ctx))
    assert {:ok, %Run{}} = Projector.project(explore)
    assert Built.record(Repo.get!(Run, explore.id)) == :refused
    assert record!(ctx) == ctx.record

    # Nor does a run a node registered itself.
    node_run = run_fixture(ctx.scope)
    event_fixture(node_run, 5, "run.built", built(ctx))
    assert {:ok, %Run{}} = Projector.project(node_run)
    assert Built.record(Repo.get!(Run, node_run.id)) == :refused
    assert record!(ctx) == ctx.record
  end

  describe "an image away from the run's destinations" do
    # The run's `image_destination` with its part `index` replaced: 0 the registry's
    # address, 1 the instance, 2 the organisation.
    defp moved(ctx, index, value) do
      ctx.run
      |> sent("image_destination")
      |> String.split("/")
      |> List.replace_at(index, value)
      |> Enum.join("/")
    end

    # The run's report of `data`, alone, as `Built.record/1` takes it, and the log it wrote.
    defp record_alone(ctx, data) do
      Repo.delete_all(from e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id)
      event_fixture(ctx.run, 5, "run.built", data)

      capture_log(fn ->
        send(self(), {:recorded, Built.record(Repo.get!(Run, ctx.run.id))})
      end)
    end

    test "records nothing, and logs the run and the member, never the image", ctx do
      destination = sent(ctx.run, "image_destination")
      [host, instance, organisation, "targets", _target] = String.split(destination, "/")
      assert host == Apiary.Registry.service()
      assert instance == Apiary.InstanceConfig.registry_instance()
      assert organisation == Apiary.Registry.Names.organisation(ctx.scope.organisation.id)

      for place <- [
            moved(ctx, 2, Apiary.Registry.Names.organisation(Ecto.UUID.generate())),
            moved(ctx, 1, String.duplicate("0", 16)),
            moved(ctx, 0, "registry.other.example"),
            destination <> "-x",
            destination <> "/x",
            destination <> "x",
            String.slice(destination, 0..-2//1),
            String.replace(destination, "/targets/", "/environments/")
          ] do
        image = place <> "@sha256:" <> @digest
        log = record_alone(ctx, built(ctx, %{"image" => image}))
        assert_received {:recorded, :refused}
        assert record!(ctx) == ctx.record
        assert log =~ "its image is not at the run's image_destination (run #{ctx.run.public_id})"
        refute log =~ "@sha256:"
      end
    end

    test "records nothing for a tag in place of a digest, or a path that leaves the destination",
         ctx do
      destination = sent(ctx.run, "image_destination")

      for image <- [
            destination <> ":latest",
            destination <> "/../x@sha256:" <> @digest,
            destination <> "@sha256:" <> String.upcase(@digest)
          ] do
        record_alone(ctx, built(ctx, %{"image" => image}))
        assert_received {:recorded, :refused}
        assert record!(ctx) == ctx.record
      end
    end

    test "an environment image is stored with its report only at the run's environment_destination",
         ctx do
      place = sent(ctx.run, "environment_destination")
      assert place =~ ~r"/environments/[0-9a-f]{16}\z"
      assert sent(ctx.run, "environment_image") == nil

      for wrong <- [
            sent(ctx.run, "image_destination"),
            place <> "-x",
            String.replace(place, Apiary.Registry.service(), "registry.other.example")
          ] do
        log =
          record_alone(ctx, built(ctx, %{"environment_image" => wrong <> "@sha256:" <> @digest}))

        assert_received {:recorded, :refused}
        assert record!(ctx) == ctx.record
        assert log =~ "its environment_image is not the environment image the run was sent"
      end

      record_alone(ctx, built(ctx, %{"environment_image" => place <> "@sha256:" <> @digest}))
      assert_received {:recorded, :recorded}
      assert_stored(ctx)
    end

    test "a run sent an environment image reports exactly that one", ctx do
      sent_image = sent(ctx.run, "environment_destination") <> "@sha256:" <> @old_digest

      documents =
        ctx.run.run_documents
        |> Jason.decode!(objects: :ordered_objects)
        |> then(fn %{values: values} = object ->
          values =
            Enum.map(values, fn
              {"environment_destination", _place} -> {"environment_image", sent_image}
              member -> member
            end)

          %{object | values: values}
        end)
        |> Jason.encode!()

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [run_documents: documents]
        )

      ctx = %{ctx | run: Repo.get!(Run, ctx.run.id)}

      record_alone(
        ctx,
        built(ctx, %{"environment_image" => String.replace(sent_image, @old_digest, @digest)})
      )

      assert_received {:recorded, :refused}
      assert record!(ctx) == ctx.record

      record_alone(ctx, built(ctx, %{"environment_image" => sent_image}))
      assert_received {:recorded, :recorded}
      assert_stored(ctx)
    end

    test "a run whose documents have no image_destination, registered before the claim sent one, records nothing",
         ctx do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [run_documents: ~s({"step":"prebuild"})]
        )

      log = record_alone(ctx, built(ctx))
      assert_received {:recorded, :refused}
      assert record!(ctx) == ctx.record
      assert log =~ "its image cannot be checked: the run's documents have no image_destination"
    end
  end

  test "a run with no report records nothing", ctx do
    assert Built.record(ctx.run) == :none
    assert record!(ctx) == ctx.record
  end

  # The fixture's image is at a place no claim sends: its digest is moved to the run's
  # `image_destination`.
  @tag :contract
  test "the data of Forager's fixture of the report is stored", ctx do
    [%{"type" => "dev.qory.run.built", "data" => data}] =
      Apiary.ContractFixtures.contract_dir()
      |> Path.join("fixtures/batch/built-sha256-commit.json")
      |> File.read!()
      |> Jason.decode!()

    [_place, digest] = String.split(data["image"], "@sha256:")
    data = %{data | "image" => destination_image(ctx.run, digest)}
    report!(ctx, data)

    assert %Record{image: image, size: size, commit: commit, reported_ref: ref} = record!(ctx)

    assert {image, size, commit, ref} ==
             {data["image"], data["size"], data["commit"], data["environment_ref"]}
  end
end
