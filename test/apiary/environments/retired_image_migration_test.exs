defmodule Apiary.Environments.RetiredImageMigrationTest do
  # The migration that clears the build of each retired environment record before the
  # held-run migration sets `built_ref` from `reported_ref`, run down and up again inside
  # the test's transaction, which rolls it all back: a retired record's image then serves
  # no run, whatever its collection's `environment_ref`, and a record that was not retired
  # keeps its image. It changes `environments` under every other test, so this is not
  # async. The rows before the held-run migration are written in raw SQL, as the record's
  # schema has no `retired_at`.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Environments
  alias Apiary.Environments.Record

  @forget {20_261_023_085_900, Apiary.Repo.Migrations.ForgetTheRetiredEnvironmentImages,
           "forget_the_retired_environment_images"}
  @hold {20_261_023_090_000, Apiary.Repo.Migrations.HoldRunsForTheirEnvironmentBuild,
         "hold_runs_for_their_environment_build"}
  @validate {20_261_023_090_100, Apiary.Repo.Migrations.ValidateTheHeldRunChecks,
             "validate_the_held_run_checks"}

  @image "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)

  setup_all do
    for {version, migration, name} <- [@forget, @hold, @validate],
        not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, pool: pool_fixture(scope)}
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  # A record of `collection` for the pool, as one kept before the held-run migration: an
  # image built for the collection's target from `env-1`, a failure after it, and
  # `retired_at` set or not.
  defp insert!(ctx, collection, retired?) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO environments (id, organisation_id, workspace_id, pool_id, " <>
        "source_collection_id, queued_ref, queued_at, image, size, commit, built_at, " <>
        "reported_ref, built_target_system, built_target_path, built_queued_at, " <>
        "failure_cause, failed_at, retired_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, 'env-1', now(), $6, 734003200, '9c1e4a7b', now(), " <>
        "'env-1', $7, $8, now(), 'lost', now(), $9, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.scope.organisation.id),
        Ecto.UUID.dump!(ctx.scope.workspace.id),
        Ecto.UUID.dump!(ctx.pool.id),
        Ecto.UUID.dump!(collection.id),
        @image,
        collection.target_system,
        collection.target_path,
        if(retired?, do: DateTime.utc_now())
      ]
    )

    id
  end

  defp target(collection), do: %{system: collection.target_system, path: collection.target_path}

  test "a retired record keeps no build, so its image serves no run of its environment_ref; another keeps its image",
       ctx do
    retired = collection_fixture(ctx.scope, target_path: "acme/retired")
    kept = collection_fixture(ctx.scope, target_path: "acme/kept")

    down!(@validate)
    down!(@hold)
    down!(@forget)

    retired_id = insert!(ctx, retired, true)
    kept_id = insert!(ctx, kept, false)

    up!(@forget)
    up!(@hold)
    up!(@validate)

    assert %Record{
             image: nil,
             size: nil,
             commit: nil,
             built_at: nil,
             reported_ref: nil,
             built_ref: nil,
             built_target_system: nil,
             built_target_path: nil,
             built_queued_at: nil,
             failure_cause: :lost,
             failed_at: %DateTime{}
           } = Repo.get!(Record, retired_id)

    assert %Record{image: @image, reported_ref: "env-1", built_ref: "env-1"} =
             Repo.get!(Record, kept_id)

    # Both collections have `env-1`: only the record that was not retired serves a run.
    assert Environments.image_for(ctx.pool, target(retired)) == nil
    assert Environments.image_for(ctx.pool, target(kept)) == @image
  end

  test "once the held-run migration has run, up changes nothing", ctx do
    collection = collection_fixture(ctx.scope)

    record =
      Repo.insert!(%Record{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        pool_id: ctx.pool.id,
        source_collection_id: collection.id,
        image: @image,
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1",
        built_ref: "env-1",
        built_target_system: collection.target_system,
        built_target_path: collection.target_path
      })

    down!(@forget)
    up!(@forget)

    assert Repo.get!(Record, record.id) == record
    assert Environments.image_for(ctx.pool, target(collection)) == @image
  end
end
