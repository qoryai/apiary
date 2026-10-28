defmodule Apiary.Adapters.ConnectionReachMigrationTest do
  # The migration of the workspaces an adapter's connection reaches, run down and up again
  # inside the test's transaction, which rolls it all back: up adds
  # `adapter_connections.applies_to`, `all` for the rows there already and with no default
  # after, its check, and `adapter_connection_workspaces`, whose rows keep a connection
  # and a workspace of one organisation; down takes them away. It changes
  # `adapter_connections` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @version 20_261_028_170_000
  @migration Apiary.Repo.Migrations.KeepTheWorkspacesAnAdapterConnectionReaches

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_the_workspaces_an_adapter_connection_reaches.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp query!(sql, params), do: Repo.query!(sql, Enum.map(params, &Ecto.UUID.dump!/1))

  defp column_default do
    Repo.query!(
      "SELECT column_default FROM information_schema.columns " <>
        "WHERE table_name = 'adapter_connections' AND column_name = 'applies_to'"
    ).rows
  end

  defp reach_table?,
    do:
      Repo.query!("SELECT to_regclass('adapter_connection_workspaces') IS NOT NULL").rows ==
        [[true]]

  test "a connection there already reaches every workspace; up adds the check and the keys" do
    %{scope: scope} = sign_up_fixture()
    {connection, _nonce} = connection_fixture(scope, connectable_adapter_fixture().adapter)

    down!()
    assert column_default() == []
    refute reach_table?()

    up!()
    assert column_default() == [[nil]]
    assert reach_table?()
    assert Repo.reload!(connection).applies_to == "all"

    assert_raise Postgrex.Error, ~r/adapter_connections_applies_to_check/, fn ->
      Repo.transaction(fn ->
        query!("UPDATE adapter_connections SET applies_to = 'some' WHERE id = $1", [
          connection.id
        ])
      end)
    end

    # A connection reaches a workspace of its organisation only.
    other = sign_up_fixture().scope.workspace

    assert_raise Postgrex.Error, ~r/adapter_connection_workspaces_workspace_id_fkey/, fn ->
      Repo.transaction(fn ->
        query!(
          "INSERT INTO adapter_connection_workspaces " <>
            "(organisation_id, connection_id, workspace_id, inserted_at, updated_at) " <>
            "VALUES ($1, $2, $3, now(), now())",
          [scope.organisation.id, connection.id, other.id]
        )
      end)
    end

    assert %{num_rows: 1} =
             query!(
               "INSERT INTO adapter_connection_workspaces " <>
                 "(organisation_id, connection_id, workspace_id, inserted_at, updated_at) " <>
                 "VALUES ($1, $2, $3, now(), now())",
               [scope.organisation.id, connection.id, scope.workspace.id]
             )
  end
end
