defmodule Apiary.Organisations.ActivitySlugMigrationTest do
  @moduledoc """
  `20261003000400`: a workspace whose slug is `activity`, now the Activity page's name, gets
  the first free numbered slug of its organisation; no other workspace moves.
  """
  # Not async: the migration writes every workspace that holds the slug, as it runs.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  Code.require_file(
    "priv/repo/migrations/20261003000400_move_workspaces_off_the_activity_slug.exs",
    File.cwd!()
  )

  alias Apiary.Organisations.Workspace
  alias Apiary.Repo.Migrations.MoveWorkspacesOffTheActivitySlug, as: Migration

  @version 20_261_003_000_400

  # As a release before this one could have made them: the slug was no reserved name then.
  defp workspace!(organisation, slug) do
    Repo.insert!(%Workspace{
      organisation_id: organisation.id,
      name: "Workspace #{slug}",
      slug: slug,
      domain: "software"
    })
  end

  test "a workspace named activity moves to the first free numbered slug" do
    %{organisation: first, workspace: untouched} = sign_up_fixture()
    %{organisation: second} = sign_up_fixture()

    moved = workspace!(first, "activity")
    workspace!(second, "activity-2")
    crowded = workspace!(second, "activity")

    # It ran when the test database was made, before these rows: taken back (which changes
    # nothing) and run again, as a release migrates. Without the migration lock: the test's
    # sandbox connection is the only one.
    Ecto.Migrator.down(Repo, @version, Migration, log: false, migration_lock: false)
    Ecto.Migrator.up(Repo, @version, Migration, log: false, migration_lock: false)

    assert Repo.reload!(moved).slug == "activity-2"
    assert Repo.reload!(crowded).slug == "activity-3"
    assert Repo.reload!(untouched).slug == untouched.slug
    refute Repo.exists?(from w in Workspace, where: w.slug == "activity")
  end
end
