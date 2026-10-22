defmodule Apiary.Sources.MigrationTest do
  # The migrations that keep the tickets, take work items in again, keep when a ticket was
  # last listed and keep when a complete set left a comment out, with the later ones that
  # queue prebuilds and hold runs for their build down first and up last, run down and up
  # again
  # inside the test's transaction, which rolls it all back. They change `work_items`,
  # `work_item_events` and `dispatch_runs` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  @items {20_261_017_143_000, Apiary.Repo.Migrations.KeepSourceItems, "keep_source_items"}
  @again {20_261_017_144_000, Apiary.Repo.Migrations.TakeWorkItemsInAgain,
          "take_work_items_in_again"}
  @listed {20_261_017_150_000, Apiary.Repo.Migrations.KeepWhenAnItemWasLastListed,
           "keep_when_an_item_was_last_listed"}
  @left_out {20_261_017_151_000, Apiary.Repo.Migrations.KeepWhenACompleteSetLeftACommentOut,
             "keep_when_a_complete_set_left_a_comment_out"}
  @prebuilds {20_261_017_160_000, Apiary.Repo.Migrations.QueuePrebuilds, "queue_prebuilds"}
  @hold {20_261_023_090_000, Apiary.Repo.Migrations.HoldRunsForTheirEnvironmentBuild,
         "hold_runs_for_their_environment_build"}

  @tables ~w(source_items source_item_comments source_item_listings)
  @functions ~w(source_item_public_id source_parts_valid source_texts_valid)
  @columns ~w(adapter_id item_id target_system target_path take_in declined_at declined_by_id)

  setup_all do
    for {version, migration, name} <- [@items, @again, @listed, @left_out, @prebuilds, @hold],
        not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp list(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)
    rows |> List.flatten() |> Enum.sort()
  end

  defp tables,
    do:
      list("SELECT table_name FROM information_schema.tables WHERE table_name = ANY($1)", [
        @tables
      ])

  defp functions, do: list("SELECT proname FROM pg_proc WHERE proname = ANY($1)", [@functions])

  defp columns do
    list(
      "SELECT column_name FROM information_schema.columns " <>
        "WHERE table_name = 'work_items' AND column_name = ANY($1)",
      [@columns]
    )
  end

  defp key(name) do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [
        name
      ])

    definition
  end

  defp check(name), do: key(name)

  test "down removes the tickets and the work item's new columns and keys; up brings them back" do
    assert tables() == Enum.sort(@tables)
    assert functions() == Enum.sort(@functions)
    assert columns() == Enum.sort(@columns)
    assert key("work_item_events_work_item_id_fkey") =~ "ON UPDATE CASCADE"
    assert key("dispatch_runs_work_item_id_fkey") =~ "(work_item_id, organisation_id)"
    assert check("work_items_state_check") =~ "declined"

    down!(@hold)
    down!(@prebuilds)
    down!(@left_out)
    down!(@listed)
    down!(@again)
    down!(@items)

    assert tables() == []
    assert functions() == []
    assert columns() == []
    refute key("work_item_events_work_item_id_fkey") =~ "ON UPDATE"
    assert key("dispatch_runs_work_item_id_fkey") =~ "(work_item_id, workspace_id)"

    assert key("work_items_connection_id_fkey") ==
             "FOREIGN KEY (connection_id, organisation_id) " <>
               "REFERENCES adapter_connections(id, organisation_id) MATCH FULL"

    refute check("work_items_state_check") =~ "declined"
    refute check("work_item_events_kind_check") =~ "declined"
    assert check("work_items_external_ref_check") =~ "255"
    assert check("work_items_url_check") =~ "https?"

    up!(@items)
    up!(@again)
    up!(@listed)
    up!(@left_out)
    up!(@prebuilds)
    up!(@hold)

    assert tables() == Enum.sort(@tables)
    assert functions() == Enum.sort(@functions)
    assert columns() == Enum.sort(@columns)
    assert key("work_item_events_work_item_id_fkey") =~ "ON UPDATE CASCADE"
    assert key("dispatch_runs_work_item_id_fkey") =~ "(work_item_id, organisation_id)"

    assert key("work_items_connection_id_fkey") ==
             "FOREIGN KEY (connection_id, organisation_id, adapter_id) " <>
               "REFERENCES adapter_connections(id, organisation_id, adapter_id) MATCH FULL"

    # The tables work as before.
    %{scope: scope} = sign_up_fixture()
    assert %{take_in: 1, item_id: item_id} = work_item_fixture(scope)
    assert item_id
  end

  test "taking work items in again refuses to run while work_items holds a row" do
    %{scope: scope} = sign_up_fixture()
    work_item_fixture(scope)

    down!(@hold)
    down!(@prebuilds)
    down!(@again)

    assert_raise Postgrex.Error, ~r/runs only while work_items is empty/, fn ->
      Ecto.Migrator.up(Repo, elem(@again, 0), elem(@again, 1), @options)
    end

    assert columns() == []

    Repo.query!("DELETE FROM work_items")
    up!(@again)
    up!(@prebuilds)
    up!(@hold)
    assert columns() == Enum.sort(@columns)
  end
end
