defmodule Apiary.Stages.ReturnMigrationTest do
  # The two migrations that keep the stage a run returned to (`20261116180000` and
  # `20261116180100`), run down and up again inside the test's transaction, which rolls it
  # all back: down takes the columns `dispatch_runs.returned_to` and `returned_at` and the
  # check on the first away, and the cause `return_limit` out of the check on
  # `escalations.cause`; up brings them back. The migrations change `dispatch_runs` and `escalations` under every other test, so this is
  # not async. The rolled-back transaction leaves the test database as it was, and the
  # migration lock is off, as it is in the other migration tests here.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  @keep {20_261_116_180_000, Apiary.Repo.Migrations.KeepTheStageARunReturnedTo,
         "keep_the_stage_a_run_returned_to"}
  @validate {20_261_116_180_100, Apiary.Repo.Migrations.ValidateTheStageARunReturnedTo,
             "validate_the_stage_a_run_returned_to"}

  setup_all do
    for {version, migration, name} <- [@keep, @validate], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  # The columns of `dispatch_runs` that the first migration adds, by name.
  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'dispatch_runs' AND column_name IN ('returned_to', 'returned_at') " <>
          "ORDER BY column_name"
      )

    List.flatten(rows)
  end

  # The checks of the two tables, each with whether it is validated.
  defp checks do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname, convalidated FROM pg_constraint " <>
          "WHERE conname IN ('dispatch_runs_returned_to_check', 'escalations_cause_check') " <>
          "ORDER BY conname"
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp cause_check do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conname = 'escalations_cause_check'"
      )

    definition
  end

  test "down takes returned_to, returned_at and the check on returned_to away, and return_limit out of the cause check; up brings them back" do
    assert columns() == ["returned_at", "returned_to"]
    assert cause_check() =~ "return_limit"

    down!(@validate)
    down!(@keep)

    assert columns() == []
    assert checks() == [{"escalations_cause_check", true}]
    refute cause_check() =~ "return_limit"

    up!(@keep)
    up!(@validate)

    assert columns() == ["returned_at", "returned_to"]

    assert checks() == [
             {"dispatch_runs_returned_to_check", true},
             {"escalations_cause_check", true}
           ]

    assert cause_check() =~ "return_limit"
  end
end
