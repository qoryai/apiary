defmodule Apiary.Connections.OrganisationMigrationTest do
  # The migration that moves the connections, the releases and the service definitions to
  # the organisation, run down and up again inside the test's transaction, which rolls it
  # all back. It changes the tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection

  @moduletag needs: :secrets

  @move {20_261_016_090_200, Apiary.Repo.Migrations.MoveConnectionsToTheOrganisation,
         "move_connections_to_the_organisation"}

  # The later migrations of a model provider and its model choice, whose keys depend on
  # the tables this one makes: down before it, and up after it.
  @later [
    {20_261_026_140_000, Apiary.Repo.Migrations.KeepNoModelListForAProvider,
     "keep_no_model_list_for_a_provider"},
    {20_261_019_070_200, Apiary.Repo.Migrations.KeepTheModelChoiceAtEachLevel,
     "keep_the_model_choice_at_each_level"},
    {20_261_019_070_100, Apiary.Repo.Migrations.KeepAProviderSModels, "keep_a_provider_s_models"},
    {20_261_019_070_000, Apiary.Repo.Migrations.KeepAProviderAsAnIntegrationConnection,
     "keep_a_provider_as_an_integration_connection"}
  ]

  setup_all do
    for {version, migration, name} <- [@move | @later], not Code.ensure_loaded?(migration) do
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

  defp later_down! do
    for {version, migration, _name} <- @later,
        do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))
  end

  defp later_up! do
    for {version, migration, _name} <- Enum.reverse(@later),
        do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))
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
    later_down!()
    assert :ok = down!()
    assert "workspace_id" in columns("workspace_connections")
    assert "workspace_id" in columns("integration_releases")
    assert "workspace_id" in columns("service_definitions")
    assert "target_id" in columns("connection_targets")
    assert columns("organisation_connections") == []
    assert columns("connection_workspaces") == []

    assert :ok = up!()
    later_up!()
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

  test "down refuses while a table holds a row, and keeps it" do
    %{scope: scope} = sign_up_fixture()
    assert {:ok, _} = Connections.create_runtime(scope, %{runtime: "claude"})

    error = assert_raise Postgrex.Error, fn -> down!() end
    assert error.postgres.message =~ "Rolling back gives integrations back to the workspaces"
    assert "organisation_id" in columns("organisation_connections")
  end

  test "up refuses while a table of the workspaces holds a row" do
    %{scope: scope} = sign_up_fixture()
    later_down!()
    assert :ok = down!()

    Repo.query!(
      """
      INSERT INTO integration_releases
        (id, organisation_id, workspace_id, source, integrity_key_id, integrity_code,
         integrity_version, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'example.com/acme/tool', 'k', '\\x00', 1, now(), now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id)
      ]
    )

    error = assert_raise Postgrex.Error, fn -> up!() end
    assert error.postgres.message =~ "Qory moves integrations from the workspaces"
    assert "workspace_id" in columns("integration_releases")
  end
end
