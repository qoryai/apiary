defmodule Apiary.Runs.SessionWindowsRacesTest do
  # A gateway's key report that names a session (`Apiary.Runs.Sessions.record_windows/3`)
  # against a pass of the projector over the same run, each on a separate connection,
  # outside the SQL sandbox: the first is held after its lock (`hold/1`), the second
  # started and seen waiting on it (`await_blocked/2`). Not async: what these tests commit
  # is visible to every other test while they run, and they delete it again before they
  # end.
  #
  # The rules under test. A report takes the run's projection lock
  # (`Apiary.Runs.Projector.lock/1`) before it writes the session's record, as the write
  # after a pass does (`Apiary.Runs.Sessions.write/1`), so the two take turns on the run,
  # and neither inserts the record of a session the other has half written. The report's
  # rows are those `Apiary.ModelKeys.record/4` keeps and hands to `record_windows/3`.
  # Both writes lock the work item, the run of the queue and the run, `FOR KEY SHARE`, in
  # the order the end of a run locks them (`Apiary.Dispatches.RunEnd`), and a pass is
  # over when they start: an end that holds the work item, and then locks the run of the
  # queue and the run, deadlocks with neither.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.RunEventsFixtures, only: [events_fixture: 2, run_fixture: 1, t0: 0]

  import Apiary.RunListFixtures, only: [queue_run!: 3]

  alias Apiary.Dispatches.RunEnd
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Projector, Run, SessionKeyWindow, SessionRecord, Sessions}
  alias Apiary.WorkItems.WorkItem

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    owner = sign_up()
    %{scope: owner.scope, run: run_fixture(owner.scope)}
  end

  defp rows(utilization, minute) do
    [
      %{
        secret_value_id: Ecto.UUID.generate(),
        window: "five_hour",
        utilization: utilization,
        observed_at: DateTime.add(t0(), minute * 60, :second)
      }
    ]
  end

  defp records(run), do: Repo.all(from r in SessionRecord, where: r.run_id == ^run.id)

  test "a report for a session with no record waits for the projector's lock, and writes it after",
       %{run: run} do
    before = deadlocks()
    {held, held_pid} = hold(fn -> Projector.lock(run.id) end)

    ours = start(fn -> Sessions.record_windows(run, 1, rows(7, 0)) end)
    await_blocked(ours.backend, held_pid)

    # The report has not written the record, nor does it finish, while the lock is held.
    assert Task.yield(ours.task, 200) == nil
    assert records(run) == []

    commit(held)

    assert Task.await(ours.task) == :ok
    assert [%SessionRecord{session_number: 1} = record] = records(run)
    assert [%SessionKeyWindow{} = window] = Repo.all(SessionKeyWindow)
    assert window.session_record_id == record.id
    assert Decimal.equal?(window.first_utilization, 7)
    assert deadlocks() == before
  end

  test "a report after a pass that wrote the record adds its windows to that record", %{
    run: run
  } do
    before = deadlocks()

    events_fixture(run, [
      {1, "session.started", %{"session" => 1, "runtime" => "claude"}},
      {2, "runtime.result", %{"session" => 1, "cost_usd" => 0.25}}
    ])

    # The pass holds the lock with the record written and not committed.
    {held, held_pid} =
      hold(fn ->
        Projector.lock(run.id)
        Sessions.write(run.id)
      end)

    assert held.result == :ok

    ours = start(fn -> Sessions.record_windows(run, 1, rows(7, 0)) end)
    await_blocked(ours.backend, held_pid)
    assert Task.yield(ours.task, 200) == nil

    commit(held)

    assert Task.await(ours.task) == :ok

    # One record, the pass's, with the report's window on it.
    assert [%SessionRecord{session_number: 1} = record] = records(run)
    assert Decimal.equal?(record.cost_usd, Decimal.new("0.25"))
    assert [%SessionKeyWindow{session_record_id: id}] = Repo.all(SessionKeyWindow)
    assert id == record.id
    assert deadlocks() == before
  end

  # A run of the queue with a work item of an adapter that outlives the organisation:
  # `on_exit` deletes it after the organisation.
  defp queued!(scope, run) do
    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from n in Apiary.Nodes.Node, where: n.id == ^work_item.adapter_id)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    queue_run!(scope, run, work_item: work_item, queued: [])
  end

  # The first lock of the end of a run (`Apiary.Dispatches.RunEnd`): its work item,
  # `FOR UPDATE`. Run inside a held transaction. The records' write waits for it; a pass
  # of the projector does not.
  defp lock_work_item(queued) do
    Repo.one(
      from w in WorkItem, where: w.id == ^queued.work_item_id, select: w.id, lock: "FOR UPDATE"
    )

    :ok
  end

  # The rest of the end: the run of the queue, then the run, `FOR UPDATE`.
  defp lock_queue_run_and_run(queued, run) do
    RunEnd.lock(queued.id)
    Repo.one(from r in Run, where: r.id == ^run.id, select: r.id, lock: "FOR UPDATE")
    :ok
  end

  defp unprojected(run),
    do:
      Repo.aggregate(
        from(e in Event, where: e.run_id == ^run.id and is_nil(e.projected_at)),
        :count
      )

  test "a pass commits, and the records wait for the end, which then locks the run", %{
    scope: scope,
    run: run
  } do
    before = deadlocks()
    queued = queued!(scope, run)

    events_fixture(run, [
      {1, "session.started", %{"session" => 1, "runtime" => "claude"}},
      {2, "runtime.result", %{"session" => 1, "cost_usd" => 0.25}}
    ])

    # The end holds the work item.
    {held, held_pid} = hold(fn -> lock_work_item(queued) end)

    ours = start(fn -> Projector.project(run) end)
    await_blocked(ours.backend, held_pid)

    # The pass has committed without waiting for the end: the events are projected, the run
    # has its cost, and only the records wait.
    assert unprojected(run) == 0
    assert Decimal.equal?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.25"))
    assert records(run) == []

    # The end goes on to lock the run of the queue and the run, which the records' write
    # does not hold while it waits for the work item.
    assert :ok = continue(held, fn -> lock_queue_run_and_run(queued, run) end)
    commit(held)

    assert {:ok, _run} = Task.await(ours.task)
    assert [%SessionRecord{session_number: 1, work_item_id: work_item_id}] = records(run)
    assert work_item_id == queued.work_item_id
    assert deadlocks() == before
  end

  test "a report's window waits for the end in the same order, and the end locks the run", %{
    scope: scope,
    run: run
  } do
    before = deadlocks()
    queued = queued!(scope, run)

    {held, held_pid} = hold(fn -> lock_work_item(queued) end)

    ours = start(fn -> Sessions.record_windows(run, 1, rows(7, 0)) end)
    await_blocked(ours.backend, held_pid)

    assert :ok = continue(held, fn -> lock_queue_run_and_run(queued, run) end)
    commit(held)

    assert Task.await(ours.task) == :ok
    assert [%SessionRecord{session_number: 1}] = records(run)
    assert [%SessionKeyWindow{}] = Repo.all(SessionKeyWindow)
    assert deadlocks() == before
  end

  test "the write after the end of a run holds no lock of the end while it waits for a pass",
       %{scope: scope, run: run} do
    before = deadlocks()
    queued = queued!(scope, run)

    events_fixture(run, [
      {1, "session.started", %{"session" => 1, "runtime" => "claude"}},
      {2, "runtime.result", %{"session" => 1, "cost_usd" => 0.25}},
      {3, "session.exited", %{"session" => 1, "state" => "succeeded"}}
    ])

    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [exited_at: DateTime.utc_now()])
    run = Repo.get!(Run, run.id)

    # A pass of the projector holds the run's projection lock.
    {held, held_pid} = hold(fn -> Projector.lock(run.id) && :ok end)

    # The end of the run, then the write the projector makes after it, as `project/2` does.
    ours =
      start(fn ->
        RunEnd.run_ended(run)
        Sessions.write(run.id)
      end)

    await_blocked(ours.backend, held_pid)

    # The write waits for the pass, and the end is over: its transaction has committed, so
    # the work item, the run of the queue and the run are not locked by it.
    assert Repo.get!(Apiary.Dispatches.DispatchRun, queued.id).state != :handed_over
    assert records(run) == []

    commit(held)

    assert Task.await(ours.task) == :ok
    assert [%SessionRecord{session_number: 1, work_item_id: work_item_id}] = records(run)
    assert work_item_id == queued.work_item_id
    assert deadlocks() == before
  end

  # Postgres's own count of the deadlocks it found in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end
end
