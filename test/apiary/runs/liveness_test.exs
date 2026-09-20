defmodule Apiary.Runs.LivenessTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs
  alias Apiary.Runs.{Liveness, Projector, Run}

  @now ~U[2026-09-16 13:00:00.000000Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  defp state(%Run{id: id}), do: Repo.get!(Run, id).state

  setup do
    %{scope: scope_fixture()}
  end

  describe "a running run" do
    test "is lost after three of the intervals it announced", %{scope: scope} do
      attrs = %{state: "running", started_at: ago(600), heartbeat_interval_seconds: 10}
      silent = run_fixture(scope, Map.put(attrs, :last_heartbeat_at, ago(31)))
      beating = run_fixture(scope, Map.put(attrs, :last_heartbeat_at, ago(30)))

      assert [%Run{id: id, state: "lost", lost_at: @now}] = Liveness.check(@now)
      assert id == silent.id
      assert state(beating) == "running"
    end

    test "that announced no interval is held to thirty seconds a beat", %{scope: scope} do
      silent = run_fixture(scope, %{state: "running", last_heartbeat_at: ago(91)})
      beating = run_fixture(scope, %{state: "running", last_heartbeat_at: ago(89)})

      Liveness.check(@now)

      assert state(silent) == "lost"
      assert state(beating) == "running"
    end

    test "that never beat is measured from its start", %{scope: scope} do
      silent = run_fixture(scope, %{state: "running", started_at: ago(91)})
      fresh = run_fixture(scope, %{state: "running", started_at: ago(60)})

      Liveness.check(@now)

      assert state(silent) == "lost"
      assert state(fresh) == "running"
    end
  end

  describe "a pending run" do
    test "is lost on the same rule, counted from when the hive first heard of it", %{
      scope: scope
    } do
      silent = run_fixture(scope, %{inserted_at: ago(91)})
      fresh = run_fixture(scope, %{inserted_at: ago(60)})

      assert [%Run{id: id}] = Liveness.check(@now)
      assert id == silent.id
      assert state(fresh) == "pending"
    end
  end

  test "a run that has ended or is closed is left alone", %{scope: scope} do
    runs =
      for state <- ~w(exited failed timed_out closed lost) do
        run_fixture(scope, %{state: state, started_at: ago(9000), inserted_at: ago(9000)})
      end

    assert Liveness.check(@now) == []
    assert Enum.map(runs, &state/1) == ~w(exited failed timed_out closed lost)
  end

  test "a second check finds nothing new, and each lost run is announced once", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", started_at: ago(600)})
    Runs.subscribe(scope)
    Runs.subscribe(scope, run)

    assert [_] = Liveness.check(@now)
    assert [] = Liveness.check(@now)

    assert_receive {:run_changed, %Run{state: "lost"}}
    assert_receive {:run_changed, %Run{state: "lost"}}
    refute_receive {:run_changed, _}
  end

  test "a beat revives a lost run", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", started_at: ago(600)})
    Liveness.check(@now)
    assert state(run) == "lost"

    event_fixture(run, 9, "run.heartbeat", %{"elapsed_seconds" => 600, "interval_seconds" => 30},
      time: @now
    )

    assert {:ok, %Run{state: "running", lost_at: nil}} = Projector.project(run)
    assert Liveness.check(DateTime.add(@now, 60, :second)) == []
    assert [%Run{state: "lost"}] = Liveness.check(DateTime.add(@now, 91, :second))
  end

  test "an exit wins over lost", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", started_at: ago(600)})
    Liveness.check(@now)

    event_fixture(run, 9, "run.exited", %{
      "state" => "failed",
      "exit_code" => -1,
      "reason" => "runner_lost",
      "duration_ms" => 1
    })

    assert {:ok, %Run{state: "failed", reason: "runner_lost", lost_at: nil}} =
             Projector.project(run)

    assert Liveness.check(DateTime.add(@now, 3600, :second)) == []
  end

  test "a closed run stays closed", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", started_at: ago(600)})
    {:ok, _} = Runs.close_run(scope, run)

    assert Liveness.check(@now) == []

    event_fixture(run, 9, "run.heartbeat", %{"elapsed_seconds" => 1, "interval_seconds" => 30})
    assert {:ok, %Run{state: "closed"}} = Projector.project(run)
  end

  test "the process is not started in test, and checks on every tick when it is", %{
    scope: scope
  } do
    refute Liveness.enabled?()
    assert Process.whereis(Liveness) == nil

    run = run_fixture(scope, %{state: "running", started_at: ago(86_400 * 365)})
    Runs.subscribe(scope)

    pid = start_supervised!({Liveness, interval: 10})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    assert_receive {:run_changed, %Run{state: "lost"}}, 1000
    assert state(run) == "lost"
  end
end
