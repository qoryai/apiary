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

      # Forager's own time says nothing here: only when the server received it.
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

  describe "Forager's clock" do
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

    test "far ahead holds nothing alive, and the beats after it count by the offset it set", %{
      scope: scope
    } do
      ahead = DateTime.add(@now, 86_400 * 365, :second)
      run = run_fixture(scope, %{state: "running"})
      run = beat(run, 3, time: ahead, received_at: ago(200))
      assert run.last_heartbeat_at == ago(200)
      assert run.clock_offset_ms == Liveness.clock_offset(ago(200), ahead)

      # The clock set back: the beat counts by its own time and the offset, a year ago.
      run = beat(run, 4, time: ago(86_400), received_at: ago(100))
      assert run.clock_offset_ms == Liveness.clock_offset(ago(200), ahead)

      assert run.last_heartbeat_at ==
               DateTime.add(ago(86_400), run.clock_offset_ms + 300_000, :millisecond)

      assert [%Run{state: "lost"}] = Liveness.check(@now)
    end
  end

  describe "a heartbeat's own time" do
    @ping %{
      "forager_version" => "v0.6.0",
      "contract_version" => 1,
      "events" => [],
      "interval_seconds" => 30
    }

    defp heartbeat(run, sequence, time, received_at) do
      event_fixture(
        run,
        sequence,
        "run.heartbeat",
        %{"elapsed_seconds" => 30 * sequence, "interval_seconds" => 30},
        time: time,
        received_at: received_at
      )
    end

    defp project!(run) do
      {:ok, run} = Projector.project(run)
      run
    end

    # A session's run whose machine's clock is a second behind this server's: its ping, its
    # start and four heartbeats, the last 3480 s before @now, each received at once; then
    # the check finds it lost, at 3300 s before @now.
    defp lost_in_an_outage(scope) do
      run = run_fixture(scope, %{inserted_at: ago(3600)})
      event_fixture(run, 1, "ping", @ping, time: ago(3601), received_at: ago(3600))

      event_fixture(run, 2, "run.started", started_data(),
        time: ago(3601),
        received_at: ago(3600)
      )

      for k <- 1..4, do: heartbeat(run, 2 + k, ago(3601 - 30 * k), ago(3600 - 30 * k))

      assert %Run{state: "running", clock_offset_ms: 1000} = project!(run)
      assert [%Run{state: "lost"}] = Liveness.check(ago(3300))
      Repo.get!(Run, run.id)
    end

    # The heartbeats of the outage, sent at @now in batches: the last recorded 601 s before
    # @now, when the run ended.
    defp replay(run) do
      5..100
      |> Enum.chunk_every(24)
      |> Enum.map(fn ks ->
        for k <- ks, do: heartbeat(run, 2 + k, ago(3601 - 30 * k), @now)
        project!(run)
      end)
    end

    test "a replayed backlog keeps a lost run lost, and on the Overview, until its exit", %{
      scope: scope
    } do
      run = lost_in_an_outage(scope)
      since = ago(7 * 86_400)
      assert [%Run{id: id}] = Runs.lost_since(scope, since)
      assert id == run.id

      for replayed <- replay(run) do
        assert %Run{state: "lost", lost_at: lost_at, clock_offset_ms: 1000} = replayed
        assert lost_at == ago(3300)
        assert Enum.map(Runs.lost_since(scope, since), & &1.id) == [run.id]
        assert Runs.count_alive(scope) == 0
        assert Liveness.check(@now) == []
      end

      # Its last real heartbeat, by its own time and the offset, within the tolerance.
      assert Repo.get!(Run, run.id).last_heartbeat_at == ago(300)

      event_fixture(
        run,
        103,
        "run.exited",
        %{"state" => "failed", "exit_code" => -1, "reason" => "gateway_lost", "duration_ms" => 1},
        time: ago(600),
        received_at: @now
      )

      assert %Run{state: "failed", reason: "gateway_lost", lost_at: nil} = project!(run)
      assert Runs.lost_since(scope, since) == []
    end

    test "a rebuild gives the same offset, the same last heartbeat and, once checked, the same state",
         %{scope: scope} do
      run = lost_in_an_outage(scope)
      replay(run)
      before = Repo.get!(Run, run.id)

      assert {:ok, rebuilt} = Projector.rebuild(run)

      fields = [
        :clock_offset_ms,
        :last_heartbeat_at,
        :elapsed_seconds,
        :heartbeat_interval_seconds
      ]

      assert Map.take(rebuilt, fields) == Map.take(before, fields)
      assert [%Run{state: "lost"}] = Liveness.check(@now)
    end

    test "a live run behind a separate gateway whose machine's clock differs from the gateway's stays alive",
         %{scope: scope} do
      run = run_fixture(scope, %{inserted_at: ago(130)})
      # The ping on the gateway's clock, right; the session's start and heartbeats on its
      # machine's, twenty minutes behind.
      event_fixture(run, 1, "ping", @ping, time: ago(130), received_at: ago(130))

      event_fixture(run, 2, "run.started", started_data(%{"credential" => "issuer"}),
        time: ago(1330),
        received_at: ago(130)
      )

      for k <- 1..4, do: heartbeat(run, 2 + k, ago(1330 - 30 * k), ago(130 - 30 * k))

      assert %Run{state: "running", clock_offset_ms: 1_200_000} = run = project!(run)
      assert run.last_heartbeat_at == ago(10)
      assert Liveness.check(@now) == []
      assert Runs.count_alive(scope) == 1
    end

    test "a run a gateway opened starts from its ping's offset; a session's run does not", %{
      scope: scope
    } do
      [gateway, session] =
        for data <- [gateway_started_data(), started_data()] do
          run = run_fixture(scope, %{inserted_at: ago(600)})
          event_fixture(run, 1, "ping", @ping, time: ago(601), received_at: ago(600))
          event_fixture(run, 2, "run.started", data, time: ago(601), received_at: ago(600))
          project!(run)
        end

      assert gateway.clock_offset_ms == 1000
      assert session.clock_offset_ms == nil

      # The first heartbeat of each arrives only now, recorded nine minutes ago.
      for run <- [gateway, session], do: heartbeat(run, 3, ago(541), @now)

      assert %Run{clock_offset_ms: 1000, last_heartbeat_at: heard} = project!(gateway)
      assert heard == ago(240)
      assert %Run{clock_offset_ms: 541_000, last_heartbeat_at: @now} = project!(session)

      # The gateway's run is lost; the session's, which has no fresh offset, is not yet.
      assert Enum.map(Liveness.check(@now), & &1.id) == [gateway.id]
    end

    test "a run with no offset keeps the arrival rule", %{scope: scope} do
      # A run whose last heartbeat was kept by its arrival, before the offset was.
      run = run_fixture(scope, %{state: "running", last_heartbeat_at: ago(89)})
      assert Liveness.check(@now) == []

      # Its next heartbeat sets the offset and counts at its arrival, whatever its own time.
      heartbeat(run, 9, ago(86_400), ago(5))
      assert %Run{clock_offset_ms: 86_395_000, last_heartbeat_at: heard} = project!(run)
      assert heard == ago(5)
      assert Liveness.check(DateTime.add(@now, 85, :second)) == []
      assert [_] = Liveness.check(DateTime.add(@now, 86, :second))
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
            workspace_id: run.workspace_id,
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
    test "is lost on the same rule, counted from when the workspace first heard of it", %{
      scope: scope
    } do
      silent = run_fixture(scope, %{inserted_at: ago(91)})
      fresh = run_fixture(scope, %{inserted_at: ago(60)})

      assert [%Run{id: id}] = Liveness.check(@now)
      assert id == silent.id
      assert state(fresh) == "pending"
    end
  end

  test "a run that has ended or is lost is left alone", %{scope: scope} do
    runs =
      for state <- ~w(succeeded ended failed timed_out lost) do
        run_fixture(scope, %{state: state, last_heartbeat_at: ago(9000), inserted_at: ago(9000)})
      end

    assert Liveness.check(@now) == []
    assert Enum.map(runs, &state/1) == ~w(succeeded ended failed timed_out lost)
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
      "reason" => "gateway_lost",
      "duration_ms" => 1
    })

    assert {:ok, %Run{state: "failed", reason: "gateway_lost", lost_at: nil}} =
             Projector.project(run)

    assert Liveness.check(DateTime.add(@now, 3600, :second)) == []
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

  describe "alive/2" do
    test "holds alive exactly the runs the check would not mark lost", %{scope: scope} do
      attrs = %{started_at: ago(600), heartbeat_interval_seconds: 10}

      runs = [
        run_fixture(scope, Map.merge(attrs, %{state: "running", last_heartbeat_at: ago(31)})),
        run_fixture(scope, Map.merge(attrs, %{state: "running", last_heartbeat_at: ago(30)})),
        run_fixture(scope, %{state: "running", inserted_at: ago(91)}),
        run_fixture(scope, %{state: "running", inserted_at: ago(60)}),
        run_fixture(scope, %{state: "pending", inserted_at: ago(91)}),
        run_fixture(scope, %{state: "pending", inserted_at: ago(89)}),
        run_fixture(scope, %{state: "succeeded", inserted_at: ago(1)}),
        run_fixture(scope, %{state: "lost", inserted_at: ago(1)})
      ]

      ids = Enum.map(runs, & &1.id)

      alive =
        from(r in Run, as: :run, where: r.id in ^ids, select: r.id)
        |> Liveness.alive(@now)
        |> Repo.all()
        |> MapSet.new()

      lost = @now |> Liveness.check() |> Enum.map(& &1.id) |> MapSet.new()

      assert alive == MapSet.new(Enum.map([1, 3, 5], &Enum.at(ids, &1)))
      assert lost == MapSet.new(Enum.map([0, 2, 4], &Enum.at(ids, &1)))
    end
  end
end
