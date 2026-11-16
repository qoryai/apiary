defmodule ApiaryPro.Operators.WorkspaceOperatorsMigrationTest do
  # The migration that adds `workspace_operators`, run down and up again inside the
  # test's transaction, which rolls it all back. It changes no other table.
  #
  # It drops and adds a table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Down and up of a migration older than the latest logs a warning each.
  @moduletag :capture_log

  @version 20_261_115_100_000
  @migration Apiary.Repo.Migrations.KeepTheOperatorOfAWorkspace

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_the_operator_of_a_workspace.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp table(name) do
    %{rows: [[table]]} = Repo.query!("SELECT to_regclass($1)::text", [name])
    table
  end

  defp column(table, column) do
    %{rows: rows} =
      Repo.query!(
        "SELECT data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    rows
  end

  test "down takes the table away, and up brings it back" do
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert table("workspace_operators") == nil

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert table("workspace_operators") == "workspace_operators"
    assert column("workspace_operators", "operator_id") == [["uuid", "NO"]]
    assert column("workspace_operators", "since") == [["timestamp without time zone", "NO"]]
    assert column("workspace_operators", "model_chain") == []
  end
end
