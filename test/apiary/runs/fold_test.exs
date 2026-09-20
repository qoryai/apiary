defmodule Apiary.Runs.FoldTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.Fold

  @run %{
    state: "pending",
    runner_version: nil,
    contract_version: nil,
    runtime: nil,
    runtime_version: nil,
    command: nil,
    args: [],
    dir: nil,
    interactive: nil,
    host: nil,
    wall: nil,
    image: nil,
    labels: %{},
    task: nil,
    forge: nil,
    repository: nil,
    started_at: nil,
    exited_at: nil,
    exit_code: nil,
    signal: nil,
    reason: nil,
    duration_ms: nil,
    last_heartbeat_at: nil,
    elapsed_seconds: nil,
    heartbeat_interval_seconds: nil,
    policy_digest: nil,
    run_configuration_digest: nil,
    lost_at: nil
  }

  @t0 ~U[2026-09-16 12:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  defp event(sequence, type, data, seconds \\ nil) do
    %{sequence: sequence, type: "ai.qory." <> type, data: data, time: at(seconds || sequence)}
  end

  defp started(sequence, extra \\ %{}) do
    event(
      sequence,
      "run.started",
      Map.merge(
        %{
          "runtime" => "claude",
          "runtime_version" => "2.1.0",
          "command" => "claude",
          "args" => ["-p", "fix the build"],
          "dir" => "/work",
          "interactive" => false,
          "runner_version" => "v0.4.0",
          "host" => "dev-laptop",
          "wall" => "docker",
          "image" => "example/agent:1",
          "labels" => %{
            "forge" => "git.example.com",
            "repository" => "acme/shop",
            "task" => "issue-12"
          }
        },
        extra
      )
    )
  end

  defp heartbeat(sequence, elapsed, interval \\ 30, seconds \\ nil),
    do:
      event(
        sequence,
        "run.heartbeat",
        %{"elapsed_seconds" => elapsed, "interval_seconds" => interval},
        seconds
      )

  defp exited(sequence, data),
    do: event(sequence, "run.exited", Map.merge(%{"exit_code" => 0, "duration_ms" => 1200}, data))

  defp egress(sequence, data, seconds \\ nil) do
    event(
      sequence,
      "run.egress",
      Map.merge(
        %{
          "host" => "api.example.com",
          "port" => 443,
          "method" => "CONNECT",
          "decision" => "allowed",
          "outcome" => "connected",
          "mode" => "enforce",
          "rule" => "api.example.com"
        },
        data
      ),
      seconds
    )
  end

  describe "ai.qory.ping" do
    test "records the versions and leaves the run pending" do
      data = %{"runner_version" => "v0.4.0", "contract_version" => 1, "events" => []}
      %{run: run} = Fold.fold(@run, [event(1, "ping", data)])

      assert run.runner_version == "v0.4.0"
      assert run.contract_version == 1
      assert run.state == "pending"
    end

    test "fields of the wrong type are read as absent" do
      data = %{"runner_version" => 4, "contract_version" => "1"}
      assert %{run: @run} = Fold.fold(@run, [event(1, "ping", data)])
    end
  end

  describe "ai.qory.run.started" do
    test "fills the header, the labels and what is read from them, and the run is running" do
      %{run: run} = Fold.fold(@run, [started(2)])

      assert run.state == "running"
      assert run.started_at == at(2)
      assert run.runtime == "claude"
      assert run.runtime_version == "2.1.0"
      assert run.command == "claude"
      assert run.args == ["-p", "fix the build"]
      assert run.dir == "/work"
      assert run.interactive == false
      assert run.runner_version == "v0.4.0"
      assert run.host == "dev-laptop"
      assert run.wall == "docker"
      assert run.image == "example/agent:1"
      assert run.task == "issue-12"
      assert run.forge == "git.example.com"
      assert run.repository == "acme/shop"
      assert run.labels["task"] == "issue-12"
    end

    test "a run without labels has none" do
      %{run: run} = Fold.fold(@run, [started(2, %{"labels" => nil})])
      assert run.labels == %{}
      assert run.forge == nil
    end

    test "arriving after the exit, it fills the header and leaves the state" do
      %{run: run} = Fold.fold(@run, [exited(9, %{"state" => "succeeded"})])
      %{run: run} = Fold.fold(run, [started(2)], %{"ai.qory.run.exited" => 9})

      assert run.state == "exited"
      assert run.runtime == "claude"
    end

    test "a closed run stays closed" do
      %{run: run} = Fold.fold(%{@run | state: "closed"}, [started(2)])
      assert run.state == "closed"
    end
  end

  describe "ai.qory.run.policy_applied" do
    @digest String.duplicate("ab", 32)

    test "keeps both digests" do
      data = %{"digest" => @digest, "run_configuration" => "sha256=" <> @digest}
      %{run: run} = Fold.fold(@run, [event(3, "run.policy_applied", data)])

      assert run.policy_digest == @digest
      assert run.run_configuration_digest == "sha256=" <> @digest
    end

    test "the highest sequence decides, in whatever order they come" do
      early = event(3, "run.policy_applied", %{"digest" => "early"})
      late = event(8, "run.policy_applied", %{"digest" => "late"})

      assert Fold.fold(@run, [late, early]).run.policy_digest == "late"

      %{run: run, latest: latest} = Fold.fold(@run, [late])
      assert Fold.fold(run, [early], latest).run.policy_digest == "late"
    end
  end

  describe "ai.qory.run.heartbeat" do
    test "records the beat" do
      %{run: run} = Fold.fold(%{@run | state: "running"}, [heartbeat(5, 30)])

      assert run.last_heartbeat_at == at(5)
      assert run.elapsed_seconds == 30
      assert run.heartbeat_interval_seconds == 30
      assert run.state == "running"
    end

    test "never moves backwards" do
      %{run: run} = Fold.fold(@run, [heartbeat(9, 60, 30, 60)])
      %{run: run} = Fold.fold(run, [heartbeat(5, 30, 15, 30)])

      assert run.last_heartbeat_at == at(60)
      assert run.elapsed_seconds == 60
      assert run.heartbeat_interval_seconds == 30
    end

    test "a lost run that beats again is running again" do
      lost = %{@run | state: "lost", lost_at: at(100), last_heartbeat_at: at(10)}
      %{run: run} = Fold.fold(lost, [heartbeat(7, 120, 30, 120)])

      assert run.state == "running"
      assert run.lost_at == nil
    end

    test "an old beat does not revive a lost run" do
      lost = %{@run | state: "lost", lost_at: at(100), last_heartbeat_at: at(10)}
      %{run: run} = Fold.fold(lost, [heartbeat(3, 5, 30, 5)])

      assert run.state == "lost"
      assert run.lost_at == at(100)
    end

    test "an exited or a closed run is not revived" do
      for state <- ~w(exited failed timed_out closed) do
        %{run: run} = Fold.fold(%{@run | state: state}, [heartbeat(5, 30)])
        assert run.state == state
      end
    end
  end

  describe "ai.qory.run.log" do
    test "decodes the bytes, in sequence order" do
      events = [
        event(7, "run.log", %{"stream" => "stderr", "bytes" => Base.encode64("two\n")}),
        event(5, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64(<<0, 255>>)})
      ]

      assert %{log_chunks: chunks, skipped_log_chunks: 0} = Fold.fold(@run, events)

      assert chunks == [
               %{sequence: 5, stream: "stdout", bytes: <<0, 255>>},
               %{sequence: 7, stream: "stderr", bytes: "two\n"}
             ]
    end

    test "bytes that are not base64 are skipped and counted" do
      events = [
        event(5, "run.log", %{"stream" => "stdout", "bytes" => "not base64!"}),
        event(6, "run.log", %{"stream" => "stdout"}),
        event(7, "run.log", %{"stream" => "elsewhere", "bytes" => ""})
      ]

      assert %{log_chunks: [], skipped_log_chunks: 3} = Fold.fold(@run, events)
    end
  end

  describe "ai.qory.run.egress" do
    test "one delta per host, port and path, counting every attempt once" do
      events = [
        egress(6, %{}),
        egress(7, %{"decision" => "denied", "outcome" => "refused", "rule" => ""}),
        egress(8, %{
          "method" => "HTTPS",
          "path" => "/v1/messages",
          "request_method" => "POST"
        }),
        egress(9, %{"port" => 8443})
      ]

      %{connections: connections} = Fold.fold(@run, events)

      assert map_size(connections) == 3

      assert connections[{"api.example.com", 443, ""}] == %{
               method: "CONNECT",
               attempts: 2,
               allowed: 1,
               denied: 1,
               last_decision: "denied",
               last_rule: "",
               last_outcome: "refused",
               first_seen_at: at(6),
               last_seen_at: at(7)
             }

      assert %{attempts: 1, method: "HTTPS"} =
               connections[{"api.example.com", 443, "/v1/messages"}]

      assert %{attempts: 1} = connections[{"api.example.com", 8443, ""}]
    end

    test "an event without a host or a port is not a connection" do
      assert %{connections: connections} =
               Fold.fold(@run, [egress(6, %{"host" => nil}), egress(7, %{"port" => "443"})])

      assert connections == %{}
    end
  end

  describe "ai.qory.run.exited" do
    test "maps the contract's states onto the run's" do
      for {data, state} <- [
            {%{"state" => "succeeded"}, "exited"},
            {%{"state" => "failed", "exit_code" => 2}, "failed"},
            {%{"state" => "failed", "reason" => "timeout"}, "timed_out"},
            {%{"state" => "failed", "reason" => "runner_lost", "exit_code" => -1}, "failed"},
            {%{"state" => "evaporated", "reason" => "unheard of"}, "failed"}
          ] do
        %{run: run} = Fold.fold(%{@run | state: "running"}, [exited(18, data)])

        assert run.state == state
        assert run.exited_at == at(18)
        assert run.reason == data["reason"]
        assert run.exit_code == Map.get(data, "exit_code", 0)
        assert run.duration_ms == 1200
      end
    end

    test "keeps the signal" do
      data = %{"state" => "failed", "exit_code" => -1, "signal" => "SIGKILL"}
      assert Fold.fold(@run, [exited(18, data)]).run.signal == "SIGKILL"
    end

    test "wins over lost, and the run is no longer lost" do
      lost = %{@run | state: "lost", lost_at: at(100)}
      %{run: run} = Fold.fold(lost, [exited(18, %{"state" => "succeeded"})])

      assert run.state == "exited"
      assert run.lost_at == nil
    end

    test "a closed run stays closed and keeps the result" do
      %{run: run} = Fold.fold(%{@run | state: "closed"}, [exited(18, %{"state" => "failed"})])

      assert run.state == "closed"
      assert run.exit_code == 0
      assert run.exited_at == at(18)
    end
  end

  test "session events and unknown types fold nothing" do
    events = [
      event(4, "session.started", %{"session_id" => "s"}),
      event(5, "something.new", %{"anything" => 1}),
      %{sequence: 6, type: "com.example.other", data: %{}, time: at(6)}
    ]

    assert %Fold{run: @run, connections: %{}, log_chunks: []} = Fold.fold(@run, events)
  end

  test "any order and any split into passes gives the same run" do
    events = [
      event(1, "ping", %{"runner_version" => "v0.4.0", "contract_version" => 1}),
      started(2),
      event(3, "run.policy_applied", %{"digest" => "first"}),
      heartbeat(4, 30, 30, 30),
      event(5, "run.policy_applied", %{"digest" => "second"}),
      heartbeat(6, 60, 30, 60),
      exited(7, %{"state" => "failed", "reason" => "timeout"})
    ]

    expected = Fold.fold(@run, events).run

    for seed <- 1..50 do
      :rand.seed(:exsss, {seed, seed, seed})

      {run, _latest} =
        events
        |> Enum.shuffle()
        |> Enum.chunk_every(Enum.random(1..3))
        |> Enum.reduce({@run, %{}}, fn pass, {run, latest} ->
          %{run: run, latest: latest} = Fold.fold(run, pass, latest)
          {run, latest}
        end)

      assert run == expected
    end
  end
end
