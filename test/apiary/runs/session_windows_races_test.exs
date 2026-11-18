defmodule Apiary.Runs.SessionWindowsRacesTest do
  # A gateway's key report that names a session (`Apiary.Runs.Sessions.record_windows/3`)
  # against a pass of the projector over the same run, each on a connection of its own,
  # outside the SQL sandbox: the first is held after its lock (`hold/1`), the second
  # started and seen waiting on it (`await_blocked/2`). Not async: what these tests commit
  # is visible to every other test while they run, and they delete it again before they
  # end.
  #
  # The rule under test: a report takes the run's projection lock
  # (`Apiary.Runs.Projector.lock/1`) before it writes the session's record, as a pass of
  # the projector does, so the two take turns on the run, and neither inserts the record
  # of a session the other has half written. The report's rows are those
  # `Apiary.ModelKeys.record/4` keeps and hands to `record_windows/3`.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.RunEventsFixtures, only: [run_fixture: 1, t0: 0]

  alias Apiary.Repo
  alias Apiary.Runs.{Projector, SessionKeyWindow, SessionRecord, Sessions}

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    owner = sign_up()
    %{run: run_fixture(owner.scope)}
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

    events = [
      %{
        type: "dev.qory.session.started",
        sequence: 1,
        time: t0(),
        data: %{"session" => 1, "runtime" => "claude"}
      },
      %{
        type: "dev.qory.runtime.result",
        sequence: 2,
        time: t0(),
        data: %{"session" => 1, "cost_usd" => 0.25}
      }
    ]

    # The pass holds the lock with the record written and not committed.
    {held, held_pid} =
      hold(fn ->
        Projector.lock(run.id)
        Sessions.write(run, events)
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

  # Postgres's own count of the deadlocks it found in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end
end
