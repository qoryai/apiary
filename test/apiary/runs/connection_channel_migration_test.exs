defmodule Apiary.Runs.ConnectionChannelMigrationTest do
  # The migration that keeps the channel of a run's connection, run down and up again
  # inside the test's transaction, which rolls it all back: up lets one destination of a
  # run have a row on each channel and no other channel; down refuses while a row of the
  # channel `stack` exists, then puts the key without the channel back. It changes
  # `connections` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  @version 20_261_025_160_300
  @migration Apiary.Repo.Migrations.KeepTheChannelOfAConnection

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_the_channel_of_a_connection.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp refused(pattern, fun), do: assert_raise(Postgrex.Error, pattern, fun)

  setup do
    %{scope: scope} = sign_up_fixture()
    %{run: started_run(scope)}
  end

  # A connection row of `run` to git.example:443, with `channel` where given.
  defp insert!(run, channel) do
    {columns, values} =
      if channel,
        do: {", channel", ", '#{channel}'"},
        else: {"", ""}

    Repo.query!(
      "INSERT INTO connections (id, organisation_id, workspace_id, run_id, host, port, " <>
        "path, first_seen_at, last_seen_at#{columns}) VALUES (gen_random_uuid(), $1, $2, " <>
        "$3, 'git.example', 443, '', now(), now()#{values})",
      [
        Ecto.UUID.dump!(run.organisation_id),
        Ecto.UUID.dump!(run.workspace_id),
        Ecto.UUID.dump!(run.id)
      ]
    )
  end

  defp channels(run) do
    %{rows: rows} =
      Repo.query!("SELECT channel FROM connections WHERE run_id = $1 ORDER BY channel", [
        Ecto.UUID.dump!(run.id)
      ])

    List.flatten(rows)
  end

  test "up keeps one row per channel of a destination, session by default", %{run: run} do
    insert!(run, nil)
    insert!(run, "stack")
    assert channels(run) == ["session", "stack"]

    refused(~r/connections_run_id_channel_host_port_path_index/, fn -> insert!(run, "stack") end)
    refused(~r/connections_channel_check/, fn -> insert!(run, "other") end)
  end

  test "down refuses while a stack row exists, then takes the channel away", %{run: run} do
    insert!(run, nil)
    insert!(run, "stack")
    refused(~r/Delete the connections of the channel stack/, &down!/0)

    Repo.query!("DELETE FROM connections WHERE channel = 'stack'")
    down!()

    refused(~r/connections_run_id_host_port_path_index/, fn -> insert!(run, nil) end)

    refused(~r/column "channel" of relation "connections" does not exist/, fn ->
      insert!(run, "stack")
    end)

    up!()
    assert channels(run) == ["session"]
    insert!(run, "stack")
    assert channels(run) == ["session", "stack"]
  end
end
