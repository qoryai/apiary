defmodule Apiary.Artifacts.DeliveryMigrationTest do
  # The two migrations that add the delivery columns to `artifact_versions` and validate
  # their checks run down and up again inside the test's transaction, which rolls it all
  # back. Not async: the migration locks `artifact_versions`, which other tests read.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is shown only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :workflow_model

  @add {20_261_120_140_000, Apiary.Repo.Migrations.StoreWhereADeliveryStandsOnItsVersion,
        "store_where_a_delivery_stands_on_its_version"}
  @validate {20_261_120_140_100,
             Apiary.Repo.Migrations.ValidateTheDeliveryChecksOfAnArtifactVersion,
             "validate_the_delivery_checks_of_an_artifact_version"}
  @options [log: false, migration_lock: false]
  @columns ~w(delivery delivery_reply delivery_failure delivery_detail delivery_target_id delivery_at)

  setup_all do
    for {version, migration, name} <- [@add, @validate], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'artifact_versions' AND column_name = ANY($1)",
        [@columns]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp checks do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname, convalidated FROM pg_constraint " <>
          "WHERE conrelid = 'artifact_versions'::regclass AND contype = 'c' AND conname LIKE 'artifact_versions_delivery%'" <>
          "ORDER BY conname"
      )

    Map.new(rows, &List.to_tuple/1)
  end

  test "the columns and their validated checks go down and come back up" do
    assert columns() == Enum.sort(@columns)

    assert checks() == %{
             "artifact_versions_delivery_check" => true,
             "artifact_versions_delivery_detail_check" => true,
             "artifact_versions_delivery_failure_check" => true,
             "artifact_versions_delivery_reply_check" => true
           }

    down!(@validate)
    down!(@add)
    assert columns() == []
    assert checks() == %{}

    up!(@add)
    assert columns() == Enum.sort(@columns)
    assert checks() |> Map.values() |> Enum.uniq() == [false]

    up!(@validate)
    assert checks() |> Map.values() |> Enum.uniq() == [true]
  end
end
