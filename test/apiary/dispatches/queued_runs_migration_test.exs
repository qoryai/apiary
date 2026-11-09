defmodule Apiary.Dispatches.QueuedRunsMigrationTest do
  # The migration that writes a run record for each run of the queue that still waits, run
  # down and up again on real rows inside the test's transaction, which rolls it all back.
  # It changes the `runs` table under every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run

  @version 20_261_109_100_000
  @migration Apiary.Repo.Migrations.GiveEachWaitingRunItsRunRecord

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_give_each_waiting_run_its_run_record.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp queue!(scope) do
    work_item = work_item_fixture(scope)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  defp record(%DispatchRun{id: id}), do: Repo.one(from r in Run, where: r.dispatch_run_id == ^id)

  defp counter(workspace_id) do
    %{rows: [[last]]} =
      Repo.query!("SELECT last_number FROM run_counters WHERE workspace_id = $1", [
        Ecto.UUID.dump!(workspace_id)
      ])

    last
  end

  test "up numbers each waiting run in queue order after the highest number; down deletes them, and keeps the records of runs that ended while they waited" do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()

    # A run that ended while it waited keeps its record, cancelled, number 1.
    ended = queue!(scope)

    {:ok, :ok} =
      Repo.transact(fn ->
        {:ok,
         Dispatches.cancel_for_undo(Repo.get!(Apiary.WorkItems.WorkItem, ended.work_item_id))}
      end)

    first = queue!(scope)
    second = queue!(scope)
    gone = queue!(scope)
    elsewhere = queue!(other)

    # A run that failed while it waited keeps its record too, failed, number 5.
    failed = queue!(scope)

    {:ok, [_ended]} =
      Repo.transact(fn ->
        Repo.update_all(from(r in DispatchRun, where: r.id == ^failed.id),
          set: [state: :ended, end_cause: :harness_unresolved, result_outcome: :error]
        )

        {:ok, Apiary.Dispatches.Queued.ended([failed.id], DateTime.utc_now())}
      end)

    # As the previous release left them: no record for a run that waits.
    down!()
    assert record(first) == nil and record(second) == nil and record(elsewhere) == nil
    assert %Run{state: "cancelled", number: 1} = record(ended)
    assert %Run{state: "failed", reason: "harness_unresolved", number: 5} = record(failed)

    # A run of the queue that ended with no record gets none.
    Repo.update_all(from(r in DispatchRun, where: r.id == ^gone.id),
      set: [state: :ended, end_cause: :closed]
    )

    # The previous release took numbers since: the counter is past the highest number.
    assert counter(scope.workspace.id) == 5

    Repo.query!("UPDATE run_counters SET last_number = 6 WHERE workspace_id = $1", [
      Ecto.UUID.dump!(scope.workspace.id)
    ])

    up!()

    assert %Run{state: "pending", number: 7} = first_run = record(first)
    assert %Run{state: "pending", number: 8} = record(second)
    assert first_run.inserted_at == Repo.get!(DispatchRun, first.id).queued_at
    assert first_run.node_run_id == first.run_id
    assert Run.public_id?(first_run.public_id)
    assert Run.queued?(first_run)
    assert record(gone) == nil
    assert %Run{state: "cancelled", number: 1} = record(ended)
    assert %Run{state: "failed", number: 5} = record(failed)
    assert counter(scope.workspace.id) == 8

    assert %Run{number: 2} = record(elsewhere)
    assert counter(other.workspace.id) == 2

    # The next run takes the number after the counter.
    assert %Run{number: 9} = record(queue!(scope))

    # Rollback: the records of the runs that wait go; the counters stay.
    down!()
    assert record(first) == nil and record(second) == nil
    assert %Run{state: "cancelled"} = record(ended)
    assert %Run{state: "failed", number: 5} = record(failed)
    assert counter(scope.workspace.id) == 9
  end
end
