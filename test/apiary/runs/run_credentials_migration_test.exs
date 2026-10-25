defmodule Apiary.Runs.RunCredentialsMigrationTest do
  # The migration of the runs' credential entries, run down and up again inside the
  # test's transaction, which rolls it all back: down drops `run_credentials`, and up
  # makes it again with its checks. Not async: it changes the schema under other tests.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  @version 20_261_025_160_500
  @migration Apiary.Repo.Migrations.KeepEachRunSCredentialEntries

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_each_run_s_credential_entries.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp table? do
    Repo.query!("SELECT to_regclass('public.run_credentials') IS NOT NULL").rows == [[true]]
  end

  defp checks do
    Repo.query!(
      "SELECT conname FROM pg_constraint WHERE conrelid = 'run_credentials'::regclass " <>
        "AND contype = 'c' ORDER BY conname"
    ).rows
  end

  test "down drops the table, and up makes it again with its checks" do
    assert table?()
    down!()
    refute table?()
    up!()
    assert table?()
    assert checks() == [["run_credentials_entry_check"], ["run_credentials_values_check"]]
  end
end
