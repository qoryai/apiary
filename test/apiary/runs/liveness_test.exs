defmodule Apiary.Runs.LivenessTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs
  alias Apiary.Runs.{Event, Liveness, Projector, Run}

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

    test "that never beat is measured from the arrival of its run.started", %{scope: scope} do
      silent = run_fixture(scope, %{state: "running", inserted_at: ago(60)})
      fresh = run_fixture(scope, %{state: "running", inserted_at: ago(600)})

      # The runner's own time says nothing here: only when the server received it.
      event_fixture(silent, 2, "run.started", started_data(), time: @now, received_at: ago(91))

      event_fixture(fresh, 2, "run.started", started_data(),
        time: ago(9000),
        received_at: ago(60)
      )

      for run <- [silent, fresh], do: {:ok, %Run{state: "running"}} = Projector.project(run)

      assert [%Run{id: id}] = Liveness.check(@now)
      assert id == silent.id
      assert state(fresh) == "running"
    end

    test "with neither a beat nor a run.started is measured from its first event", %{
      scope: scope
    } do
      silent = run_fixture(scope, %{state: "running", inserted_at: ago(91)})
      fresh = run_fixture(scope, %{state: "running", inserted_at: ago(60)})

      Liveness.check(@now)

      assert state(silent) == "lost"
      assert state(fresh) == "running"
    end

    test "no stored interval makes the check raise, and none holds a run for ever", %{
      scope: scope
    } do
      attrs = %{state: "running", heartbeat_interval_seconds: 2_000_000_000}
      held = run_fixture(scope, Map.put(attrs, :last_heartbeat_at, ago(3 * 3600)))
      silent = run_fixture(scope, Map.put(attrs, :last_heartbeat_at, ago(3 * 3600 + 1)))
      pending = run_fixture(scope, %{attrs | state: "pending"} |> Map.put(:inserted_at, ago(1)))
      negative = run_fixture(scope, %{attrs | heartbeat_interval_seconds: -2_000_000_000})

      lost = Liveness.check(@now)

      assert Enum.map(lost, & &1.id) == [silent.id]
      assert Enum.map([held, pending, negative], &state/1) == ~w(running pending running)
    end

    test "the heartbeat that announces such an interval is folded without it", %{scope: scope} do
      run = run_fixture(scope, %{state: "running"})

      event_fixture(
        run,
        3,
        "run.heartbeat",
        %{"elapsed_seconds" => 1, "interval_seconds" => 2_000_000_000},
        received_at: ago(91)
      )

      assert {:ok, %Run{heartbeat_interval_seconds: nil}} = Projector.project(run)
      assert [%Run{state: "lost"}] = Liveness.check(@now)
    end
  end

  describe "the runner's clock" do
    defp beat(run, sequence, opts) do
      event_fixture(
        run,
        sequence,
        "run.heartbeat",
        %{"elapsed_seconds" => sequence, "interval_seconds" => 30},
        opts
      )

      {:ok, run} = Projector.project(run)
      run
    end

    test "far behind does not make a beating run lost", %{scope: scope} do
      run = run_fixture(scope, %{state: "running"})
      run = beat(run, 3, time: ago(86_400), received_at: ago(5))

      assert run.last_heartbeat_at == ago(5)
      assert Liveness.check(@now) == []
    end

    test "far ahead does not hold a silent run alive, nor mask the beats after it", %{
      scope: scope
    } do
      run = run_fixture(scope, %{state: "running"})
      run = beat(run, 3, time: DateTime.add(@now, 86_400 * 365, :second), received_at: ago(200))
      assert run.last_heartbeat_at == ago(200)

      run = beat(run, 4, time: ago(86_400), received_at: ago(100))
      assert run.last_heartbeat_at == ago(100)

      assert [%Run{state: "lost"}] = Liveness.check(@now)
    end
  end

  describe "sweep/1" do
    test "projects what was left unprojected for more than ten seconds", %{scope: scope} do
      left = run_fixture(scope, %{state: "running"})
      recent = run_fixture(scope, %{state: "running"})
      exit = %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 5}

      event_fixture(left, 9, "run.exited", exit, received_at: ago(11))
      event_fixture(recent, 9, "run.exited", exit, received_at: ago(9))

      assert Liveness.sweep(@now) == 1
      assert state(left) == "succeeded"
      assert state(recent) == "running"
      assert Liveness.sweep(@now) == 0
    end

    test "runs before the lost rules: a run whose exit is stored is not found lost", %{
      scope: scope
    } do
      run = run_fixture(scope, %{state: "running", last_heartbeat_at: ago(600)})

      event_fixture(
        run,
        9,
        "run.exited",
        %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 5},
        received_at: ago(500)
      )

      assert Liveness.check(@now) == []
      assert state(run) == "succeeded"
    end

    test "is bounded, oldest first, and the rest waits for the next check", %{scope: scope} do
      now = DateTime.utc_now()

      rows =
        for n <- 1..105 do
          run = run_fixture(scope)

          %{
            id: Ecto.UUID.generate(),
            organisation_id: run.organisation_id,
            hive_id: run.hive_id,
            run_id: run.id,
            sequence: 1,
            event_id: Ecto.UUID.generate(),
            type: "dev.qory.session.started",
            time: now,
            data: %{},
            received_at: DateTime.add(now, -(20 + n), :second)
          }
        end

      Repo.insert_all(Event, rows)

      assert Liveness.sweep(now) == 100
      assert Liveness.sweep(now) == 5
      assert Liveness.sweep(now) == 0
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
      for state <- ~w(succeeded failed timed_out closed lost) do
        run_fixture(scope, %{state: state, last_heartbeat_at: ago(9000), inserted_at: ago(9000)})
      end

    assert Liveness.check(@now) == []
    assert Enum.map(runs, &state/1) == ~w(succeeded failed timed_out closed lost)
  end

  test "a second check finds nothing new, and each lost run is announced once", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", inserted_at: ago(600)})
    Runs.subscribe(scope)
    Runs.subscribe(scope, run)

    assert [_] = Liveness.check(@now)
    assert [] = Liveness.check(@now)

    assert_receive {:run_changed, %Run{state: "lost"}}
    assert_receive {:run_changed, %Run{state: "lost"}}
    refute_receive {:run_changed, _}
  end

  test "a beat revives a lost run", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", inserted_at: ago(600)})
    Liveness.check(@now)
    assert state(run) == "lost"

    event_fixture(run, 9, "run.heartbeat", %{"elapsed_seconds" => 600, "interval_seconds" => 30},
      received_at: @now
    )

    assert {:ok, %Run{state: "running", lost_at: nil}} = Projector.project(run)
    assert Liveness.check(DateTime.add(@now, 60, :second)) == []
    assert [%Run{state: "lost"}] = Liveness.check(DateTime.add(@now, 91, :second))
  end

  test "an exit wins over lost", %{scope: scope} do
    run = run_fixture(scope, %{state: "running", inserted_at: ago(600)})
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
    run = run_fixture(scope, %{state: "running", inserted_at: ago(600)})
    {:ok, _} = Runs.close_run(scope, run)

    assert Liveness.check(@now) == []

    event_fixture(run, 9, "run.heartbeat", %{"elapsed_seconds" => 1, "interval_seconds" => 30})
    assert {:ok, %Run{state: "closed"}} = Projector.project(run)
  end

  # Started before the sandbox lets it in, its sweep at boot fails, says so and goes on.
  @tag :capture_log
  test "the process is not started in test, and checks on every tick when it is", %{
    scope: scope
  } do
    refute Liveness.enabled?()
    assert Process.whereis(Liveness) == nil

    run = run_fixture(scope, %{state: "running", inserted_at: ago(86_400 * 365)})
    Runs.subscribe(scope)

    pid = start_supervised!({Liveness, interval: 10})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    assert_receive {:run_changed, %Run{state: "lost"}}, 1000
    assert state(run) == "lost"
  end
end
