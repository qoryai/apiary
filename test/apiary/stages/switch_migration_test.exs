defmodule Apiary.Stages.SwitchMigrationTest do
  # The migration that lets an escalation be resolved with `switch`, run down and up again
  # inside the test's transaction, which rolls it all back. It changes the table under
  # every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: [:factory, :workflow_model]

  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

  @version 20_261_117_100_000
  @migration Apiary.Repo.Migrations.KeepASwitchAsAResolution
  @options [log: false, migration_lock: false]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_a_switch_as_a_resolution.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{work_item: taken_in_fixture(scope)}
  end

  # Inserts an escalation of the work item resolved with `resolution`, a string so that
  # the database, not the schema, decides whether it is allowed.
  defp resolved(work_item, resolution) do
    Repo.query(
      """
      INSERT INTO escalations
        (id, organisation_id, workspace_id, work_item_id, process_version_id, stage_id, round,
         cause, points, resolution, resolved_at, inserted_at)
      VALUES (gen_random_uuid(), $1, $2, $3, $4, 'st_6ns22c4pav', 1, 'escalate', '{}', $5,
              now(), now())
      """,
      [
        Ecto.UUID.dump!(work_item.organisation_id),
        Ecto.UUID.dump!(work_item.workspace_id),
        Ecto.UUID.dump!(work_item.id),
        Ecto.UUID.dump!(work_item.process_version_id),
        resolution
      ]
    )
  end

  # The error of the check, with the insert rolled back to its savepoint so the test's
  # transaction goes on.
  defp refused(work_item, resolution) do
    {:error, error} =
      Repo.transaction(fn ->
        case resolved(work_item, resolution) do
          {:error, error} -> Repo.rollback(error)
          {:ok, _result} -> :inserted
        end
      end)

    error
  end

  defp count(resolution) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM escalations WHERE resolution = $1", [resolution])

    n
  end

  test "the database keeps switch as a resolution, and refuses an unknown one", %{
    work_item: work_item
  } do
    assert {:ok, _result} = resolved(work_item, "switch")

    assert %Postgrex.Error{postgres: %{constraint: "escalations_resolution_check"}} =
             refused(work_item, "decline")
  end

  test "down deletes the escalations resolved with switch and keeps the others", %{
    work_item: work_item
  } do
    assert {:ok, _result} = resolved(work_item, "switch")
    assert {:ok, _result} = resolved(work_item, "close")

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert count("switch") == 0
    assert count("close") == 1
  end

  test "up allows switch again after down", %{work_item: work_item} do
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert %Postgrex.Error{postgres: %{constraint: "escalations_resolution_check"}} =
             refused(work_item, "switch")

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert {:ok, _result} = resolved(work_item, "switch")
    assert count("switch") == 1
  end
end
