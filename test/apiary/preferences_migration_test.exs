defmodule Apiary.PreferencesMigrationTest do
  @moduledoc """
  `20260930000200`: a person's preferences and a workspace's domain. The rows an
  installation already holds read the defaults, English, UTC, the standard skin and the
  software domain, and the rollback drops the four columns.
  """
  # Not async: the migration alters the users and workspaces tables, as it runs.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  Code.require_file(
    "priv/repo/migrations/20260930000200_add_preferences_to_users_and_domain_to_workspaces.exs",
    File.cwd!()
  )

  alias Apiary.Repo.Migrations.AddPreferencesToUsersAndDomainToWorkspaces, as: Migration

  @version 20_260_930_000_200

  defp columns(table) do
    Repo.query!(
      "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
      [table]
    ).rows
    |> List.flatten()
  end

  defp row(sql, id), do: Repo.query!(sql, [Ecto.UUID.dump!(id)]).rows

  test "rows held before it read the defaults; the rollback drops the columns" do
    %{user: user, workspace: workspace} = sign_up_fixture()

    # Without the migration lock: the test's sandbox connection is the only one, and the
    # migrator's task shares it.
    Ecto.Migrator.down(Repo, @version, Migration, log: false, migration_lock: false)

    refute Enum.any?(~w(language time_zone skin), &(&1 in columns("users")))
    refute "domain" in columns("workspaces")

    Ecto.Migrator.up(Repo, @version, Migration, log: false, migration_lock: false)

    assert row("SELECT language, time_zone, skin FROM users WHERE id = $1", user.id) ==
             [["en", "Etc/UTC", "standard"]]

    assert row("SELECT domain FROM workspaces WHERE id = $1", workspace.id) == [["software"]]

    assert Repo.query!("""
           SELECT table_name, column_name, is_nullable FROM information_schema.columns
           WHERE (table_name, column_name) IN
             (('users', 'language'), ('users', 'time_zone'), ('users', 'skin'),
              ('workspaces', 'domain'))
           """).rows
           |> Enum.all?(fn [_table, _column, nullable] -> nullable == "NO" end)
  end
end
