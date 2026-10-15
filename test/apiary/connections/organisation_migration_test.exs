defmodule Apiary.Connections.OrganisationMigrationTest do
  # The migration that moves the connections, the releases and the service definitions to
  # the organisation, run down and up again inside the test's transaction, which rolls it
  # all back. It changes the tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection

  @moduletag needs: :secrets

  @move {20_261_016_090_200, Apiary.Repo.Migrations.MoveConnectionsToTheOrganisation,
         "move_connections_to_the_organisation"}

  setup_all do
    {version, migration, name} = @move

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: migrate(:down)
  defp up!, do: migrate(:up)

  defp migrate(direction) do
    {version, migration, _name} = @move
    apply(Ecto.Migrator, direction, [Repo, version, migration, @options])
  end

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  test "down gives each table its workspace again, and up takes it away" do
    assert :ok = down!()
    assert "workspace_id" in columns("workspace_connections")
    assert "workspace_id" in columns("integration_releases")
    assert "workspace_id" in columns("service_definitions")
    assert "target_id" in columns("connection_targets")
    assert columns("organisation_connections") == []
    assert columns("connection_workspaces") == []

    assert :ok = up!()
    assert columns("workspace_connections") == []
    assert columns("connection_targets") == []
    refute "workspace_id" in columns("organisation_connections")
    refute "workspace_id" in columns("integration_releases")
    refute "workspace_id" in columns("service_definitions")

    assert columns("connection_workspaces") ==
             ~w(connection_id inserted_at organisation_id updated_at workspace_id)

    # The tables work as the context writes them.
    %{scope: scope} = sign_up_fixture()

    assert {:ok, %Connection{workspaces: [_]}} =
             Connections.create_runtime(scope, %{
               runtime: "claude",
               applies_to: "selected",
               workspace_ids: [scope.workspace.id]
             })
  end
end
