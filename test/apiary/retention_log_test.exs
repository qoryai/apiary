defmodule Apiary.RetentionLogTest do
  # Not async: it lowers the logger's level to read an info line.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Retention
  alias Apiary.Runs.{Projector, Run}

  test "the job says what it pruned in one line per hive" do
    scope = scope_fixture()
    {:ok, hive} = Retention.update_retention(scope, %{events_retention_days: 10})

    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, _run} = Projector.project(run)
    long_ago = DateTime.add(DateTime.utc_now(), -50 * 86_400, :second)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [last_event_at: long_ago])

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log([level: :info], fn -> Retention.prune_all() end)

    assert log =~ "retention pruned hive=#{hive.id} trigger=manual"
    assert log =~ "runs=1 events=14 log_chunks=2 log_bytes=12 deliveries=0"
    assert log =~ "complete=true"
    # Nothing of a run's data is in the line.
    refute log =~ "api.example.com"
  end
end
