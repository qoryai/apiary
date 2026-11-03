defmodule Apiary.Organisations.ShownStandardTypesMigrationTest do
  # The migration that adds `workspaces.shown_standard_types`, run down and up again inside
  # the test's transaction, which rolls it all back. It changes the `workspaces` table under
  # every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.Workspace

  @version 20_261_102_140_000
  @migration Apiary.Repo.Migrations.KeepAWorkspaceSShownStandardTypes
  @options [log: false, migration_lock: false]

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_a_workspace_s_shown_standard_types.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp column do
    Repo.query!("""
    SELECT data_type, udt_name, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_name = 'workspaces' AND column_name = 'shown_standard_types'
    """).rows
  end

  test "up adds a nullable text array with no default; down removes it" do
    scope = scope_fixture()
    assert column() == [["ARRAY", "_text", "YES", nil]]

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert column() == []

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert column() == [["ARRAY", "_text", "YES", nil]]

    # A workspace that was there before the column shows every standard type.
    assert Repo.get!(Workspace, scope.workspace.id).shown_standard_types == nil
  end
end
