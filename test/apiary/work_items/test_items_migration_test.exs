defmodule Apiary.WorkItems.TestItemsMigrationTest do
  # The migration that keeps test work items, run down and up again inside the test's
  # transaction, which rolls it all back. It changes `work_items` under every other
  # test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems

  @test_items {20_261_026_120_000, Apiary.Repo.Migrations.KeepTestWorkItems,
               "keep_test_work_items"}

  setup_all do
    {version, migration, name} = @test_items

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down, do: Ecto.Migrator.down(Repo, elem(@test_items, 0), elem(@test_items, 1), @options)

  defp up!,
    do: assert(:ok = Ecto.Migrator.up(Repo, elem(@test_items, 0), elem(@test_items, 1), @options))

  # Each column of `work_items` the migration changes, with whether it is nullable, then
  # the key to the connection and the check.
  defp shape do
    %{rows: columns} =
      Repo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'work_items' AND column_name = ANY($1) ORDER BY column_name",
        [~w(adapter_id connection_id external_ref test url)]
      )

    %{rows: [[key]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conname = 'work_items_connection_id_fkey'"
      )

    %{rows: [[checks]]} =
      Repo.query!("SELECT count(*) FROM pg_constraint WHERE conname = 'work_items_test_check'")

    {columns, key, checks}
  end

  @up {[
         ["adapter_id", "YES"],
         ["connection_id", "YES"],
         ["external_ref", "YES"],
         ["test", "NO"],
         ["url", "YES"]
       ],
       "FOREIGN KEY (connection_id, organisation_id, adapter_id) " <>
         "REFERENCES adapter_connections(id, organisation_id, adapter_id)", 1}

  @down {[
           ["adapter_id", "NO"],
           ["connection_id", "NO"],
           ["external_ref", "NO"],
           ["url", "NO"]
         ],
         "FOREIGN KEY (connection_id, organisation_id, adapter_id) " <>
           "REFERENCES adapter_connections(id, organisation_id, adapter_id) MATCH FULL", 0}

  test "down makes the columns required and the key MATCH FULL again; up brings the test back" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)

    assert shape() == @up
    assert :ok = down()
    assert shape() == @down

    # The schema reads `test`, which is gone: the row is asked of in SQL.
    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM work_items WHERE id = $1", [
               Ecto.UUID.dump!(work_item.id)
             ])

    up!()
    assert shape() == @up
    assert %WorkItems.WorkItem{test: false} = Repo.get(WorkItems.WorkItem, work_item.id)
  end

  test "down refuses while a test work item is there, and changes nothing" do
    %{scope: scope} = sign_up_fixture()
    {:ok, work_item} = WorkItems.take_in_test(scope, "Hello! Where are you running?")

    # The migration's transaction, a savepoint of the test's, is rolled back.
    assert_raise Postgrex.Error,
                 ~r/this migration rolls back only while no work item is a test/,
                 fn -> down() end

    assert shape() == @up
    assert %WorkItems.WorkItem{test: true} = Repo.get(WorkItems.WorkItem, work_item.id)
  end
end
