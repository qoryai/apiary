defmodule Apiary.Organisations.WorkspaceTypeMigrationTest do
  # The migration that gives every workspace its type, run down and up again inside the
  # test's transaction, which rolls it all back. It changes the `workspaces` table under
  # every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  @version 20_261_028_150_000
  @migration Apiary.Repo.Migrations.KeepAWorkspaceSType

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_a_workspace_s_type.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # A workspace row written in SQL, of the domain `domain`, with no type: the column may
  # not be there.
  defp insert!(organisation, name, domain) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO workspaces (id, organisation_id, name, slug, domain, inserted_at, " <>
        "updated_at) VALUES ($1, $2, $3, $4, $5, now(), now())",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(organisation.id), name, name, domain]
    )

    id
  end

  defp type(id) do
    %{rows: [[type]]} =
      Repo.query!("SELECT type FROM workspaces WHERE id = $1", [Ecto.UUID.dump!(id)])

    type
  end

  defp column do
    %{rows: rows} =
      Repo.query!(
        "SELECT is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_name = 'workspaces' AND column_name = 'type'"
      )

    rows
  end

  test "up gives every workspace there already the type its domain reads as" do
    %{scope: scope} = sign_up_fixture()

    down!()
    assert column() == []

    software = insert!(scope.organisation, "alpha", "software")
    # The migration dates from when `general` was a domain, and gives it `qory.general`.
    general = insert!(scope.organisation, "beta", "general")
    retired = insert!(scope.organisation, "gamma", "retired")

    up!()
    assert column() == [["NO", nil]]

    assert type(software) == "qory.software"
    assert type(general) == "qory.general"
    assert type(retired) == "qory.software"
    assert type(scope.workspace.id) == "qory.software"
  end

  test "after up, a workspace row needs a type" do
    %{scope: scope} = sign_up_fixture()

    down!()
    up!()

    assert_raise Postgrex.Error, ~r/not_null_violation|null value in column "type"/, fn ->
      Repo.transaction(fn -> insert!(scope.organisation, "delta", "software") end)
    end
  end
end
