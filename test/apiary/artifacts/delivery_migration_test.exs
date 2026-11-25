defmodule Apiary.Artifacts.DeliveryMigrationTest do
  # The two migrations that add the delivery columns to `artifact_versions` and validate
  # their checks, and the two that add `target_removed` to the delivery failure check and
  # validate it, run down and up again inside the test's transaction, which rolls it all
  # back. Not async: the migration locks `artifact_versions`, which other tests read.
  use Apiary.DataCase, async: false

  import Apiary.DeliveryFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is shown only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :workflow_model

  @add {20_261_122_093_000, Apiary.Repo.Migrations.StoreWhereADeliveryStandsOnItsVersion,
        "store_where_a_delivery_stands_on_its_version"}
  @validate {20_261_122_093_100,
             Apiary.Repo.Migrations.ValidateTheDeliveryChecksOfAnArtifactVersion,
             "validate_the_delivery_checks_of_an_artifact_version"}
  @target_removed {20_261_122_120_000,
                   Apiary.Repo.Migrations.AddTargetRemovedToTheDeliveryFailures,
                   "add_target_removed_to_the_delivery_failures"}
  @validate_target_removed {20_261_122_120_100,
                            Apiary.Repo.Migrations.ValidateTheDeliveryFailureCheck,
                            "validate_the_delivery_failure_check"}
  @options [log: false, migration_lock: false]
  @columns ~w(delivery delivery_reply delivery_failure delivery_detail delivery_target_id delivery_at)

  setup_all do
    for {version, migration, name} <- [@add, @validate, @target_removed, @validate_target_removed],
        not Code.ensure_loaded?(migration) do
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

  defp check_clause do
    %{rows: [[clause]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conname = 'artifact_versions_delivery_failure_check'"
      )

    clause |> String.replace_prefix("CHECK ", "") |> String.replace(" NOT VALID", "")
  end

  test "target_removed is a delivery failure after its migration, and not before" do
    assert String.contains?(check_clause(), "'target_removed'")
    assert checks()["artifact_versions_delivery_failure_check"] == true

    down!(@validate_target_removed)
    down!(@target_removed)
    refute String.contains?(check_clause(), "'target_removed'")
    assert String.contains?(check_clause(), "'invalid'")
    assert checks()["artifact_versions_delivery_failure_check"] == false

    up!(@target_removed)
    assert String.contains?(check_clause(), "'target_removed'")
    assert checks()["artifact_versions_delivery_failure_check"] == false

    up!(@validate_target_removed)
    assert checks()["artifact_versions_delivery_failure_check"] == true
  end

  test "after the rollback, a version with target_removed stays readable, and no write of it passes" do
    work_item = work_item_fixture(scope_fixture())
    artifact = artifact_fixture(work_item, "reply", "t-1")
    version = version_fixture(artifact, 1, delivery: :failed)
    id = Ecto.UUID.dump!(version.id)

    Repo.query!(
      "UPDATE artifact_versions SET delivery_failure = 'target_removed' WHERE id = $1",
      [
        id
      ]
    )

    down!(@validate_target_removed)
    down!(@target_removed)

    assert %{rows: [["target_removed"]]} =
             Repo.query!("SELECT delivery_failure FROM artifact_versions WHERE id = $1", [id])

    # Postgres checks a NOT VALID check on every row that a write changes, whatever column
    # the write sets. The savepoint of `Repo.transaction/1` keeps the test's transaction
    # usable after the error.
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE artifact_versions SET delivery_detail = 'x' WHERE id = $1", [id])
        end)
      end

    assert error.postgres.constraint == "artifact_versions_delivery_failure_check"

    assert %{rows: [["target_removed", nil]]} =
             Repo.query!(
               "SELECT delivery_failure, delivery_detail FROM artifact_versions WHERE id = $1",
               [id]
             )
  end
end
