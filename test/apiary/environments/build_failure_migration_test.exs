defmodule Apiary.Environments.BuildFailureMigrationTest do
  # The two migrations that let an environment record take the failure cause `failed`,
  # run down and up again inside the test's transaction, which rolls it all back. They
  # change the `environments` table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Environments.Record

  @record {20_261_022_200_200, Apiary.Repo.Migrations.RecordABuildFailedByItsExit,
           "record_a_build_failed_by_its_exit"}
  @validate {20_261_022_200_300, Apiary.Repo.Migrations.ValidateABuildFailureCheck,
             "validate_a_build_failure_check"}

  setup_all do
    for {version, migration, name} <- [@record, @validate], not Code.ensure_loaded?(migration) do
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

  # A record of a prebuild that failed for `cause`, for a collection made for it alone.
  defp failed!(ctx, cause) do
    Repo.insert!(%Record{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      pool_id: ctx.pool.id,
      source_collection_id: collection_fixture(ctx.scope, environment_ref: nil).id,
      failure_cause: cause,
      failed_at: DateTime.utc_now()
    })
  end

  defp set_cause!(record, cause) do
    Repo.query!("UPDATE environments SET failure_cause = $2 WHERE id = $1", [
      Ecto.UUID.dump!(record.id),
      cause
    ])
  end

  defp validated? do
    %{rows: [[validated]]} =
      Repo.query!(
        "SELECT convalidated FROM pg_constraint " <>
          "WHERE conrelid = 'environments'::regclass AND conname = 'environments_failure_check'"
      )

    validated
  end

  test "down refuses failed and up takes it: added NOT VALID, then validated", ctx do
    down!(@validate)
    down!(@record)
    refute validated?()

    assert_raise Ecto.ConstraintError, ~r/environments_failure_check/, fn ->
      Repo.transaction(fn -> failed!(ctx, :failed) end)
    end

    lost = failed!(ctx, :lost)

    up!(@record)
    refute validated?()
    failed = failed!(ctx, :failed)
    up!(@validate)
    assert validated?()

    assert Repo.get!(Record, lost.id).failure_cause == :lost
    assert Repo.get!(Record, failed.id).failure_cause == :failed
  end

  test "down stops while a record has failed, names it, and changes nothing", ctx do
    failed = failed!(ctx, :failed)
    other = failed!(ctx, :lost)

    down!(@validate)

    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.down(Repo, elem(@record, 0), elem(@record, 1), @options)
      end

    assert error.postgres.code == :check_violation

    assert error.postgres.message ==
             "Set failure_cause to lost on the environment records #{failed.id}, then roll " <>
               "back again: the check before this migration refuses failed"

    refute error.postgres.message =~ other.id
    assert Repo.get!(Record, failed.id).failure_cause == :failed

    set_cause!(failed, "lost")
    down!(@record)
    assert Repo.get!(Record, failed.id).failure_cause == :lost

    up!(@record)
    up!(@validate)
    assert validated?()
  end
end
