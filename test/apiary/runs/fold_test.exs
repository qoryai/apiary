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

  # Received a hundred seconds after it was sent: the two clocks are told apart.
  defp event(sequence, type, data, seconds \\ nil) do
    seconds = seconds || sequence

    %{
      sequence: sequence,
      type: "ai.qory." <> type,
      data: data,
      time: at(seconds),
      received_at: at(seconds + 100)
    }
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

    test "the later of ping and run.started says the runner's version, in any order" do
      ping = event(1, "ping", %{"runner_version" => "v0.4.0", "contract_version" => 1})
      start = started(2, %{"runner_version" => "v0.4.1"})

      assert Fold.fold(@run, [ping, start]).run.runner_version == "v0.4.1"

      %{run: run, latest: latest} = Fold.fold(@run, [start])
      %{run: run} = Fold.fold(run, [ping], latest)
      assert run.runner_version == "v0.4.1"
      assert run.contract_version == 1
    end

    test "the ping with the highest sequence decides" do
      first = event(1, "ping", %{"runner_version" => "v1", "contract_version" => 1})
      second = event(9, "ping", %{"runner_version" => "v2", "contract_version" => 2})

      %{run: run, latest: latest} = Fold.fold(@run, [second])
      %{run: run} = Fold.fold(run, [first], latest)

      assert {run.runner_version, run.contract_version} == {"v2", 2}
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

      assert run.state == "succeeded"
      assert run.runtime == "claude"
    end

    test "a closed run stays closed" do
      %{run: run} = Fold.fold(%{@run | state: "closed"}, [started(2)])
      assert run.state == "closed"
    end

    test "arriving for a lost run, the run is running and no longer lost" do
      %{run: run} = Fold.fold(%{@run | state: "lost", lost_at: at(100)}, [started(2)])
      assert {run.state, run.lost_at} == {"running", nil}
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
    test "records the beat at the time this server received it" do
      %{run: run} = Fold.fold(%{@run | state: "running"}, [heartbeat(5, 30)])

      assert run.last_heartbeat_at == at(105)
      assert run.elapsed_seconds == 30
      assert run.heartbeat_interval_seconds == 30
      assert run.state == "running"
    end

    test "the highest sequence decides, whatever the runner's clock says" do
      # The later beat is dated before the earlier one: a clock that was set back.
      later = heartbeat(9, 60, 30, 3)
      earlier = heartbeat(5, 30, 15, 50)

      %{run: run, latest: latest} = Fold.fold(@run, [later])
      %{run: run} = Fold.fold(run, [earlier], latest)

      assert run.last_heartbeat_at == later.received_at
      assert run.elapsed_seconds == 60
      assert run.heartbeat_interval_seconds == 30
      assert Fold.fold(@run, [earlier, later]).run == run
    end

    test "a beat dated in the future does not mask the beats after it" do
      future = heartbeat(5, 30, 30, 86_400 * 365)
      next = heartbeat(6, 60)

      %{run: run} = Fold.fold(@run, [future, next])
      assert run.last_heartbeat_at == next.received_at
      assert run.elapsed_seconds == 60
    end

    test "an interval outside 1..3600 is read as absent" do
      for interval <- [0, -5, 3601, 2_000_000_000, "30"] do
        %{run: run} = Fold.fold(@run, [heartbeat(5, 30, interval)])
        assert run.heartbeat_interval_seconds == nil
        assert run.last_heartbeat_at == at(105)
      end

      assert Fold.fold(@run, [heartbeat(5, 30, 3600)]).run.heartbeat_interval_seconds == 3600
    end

    test "a lost run that beats again is running again" do
      lost = %{@run | state: "lost", lost_at: at(100), last_heartbeat_at: at(10)}
      %{run: run} = Fold.fold(lost, [heartbeat(7, 120)], %{"ai.qory.run.heartbeat" => 4})

      assert run.state == "running"
      assert run.lost_at == nil
    end

    test "an earlier beat arriving late does not revive a lost run" do
      lost = %{@run | state: "lost", lost_at: at(100), last_heartbeat_at: at(10)}
      %{run: run} = Fold.fold(lost, [heartbeat(3, 5)], %{"ai.qory.run.heartbeat" => 4})

      assert run.state == "lost"
      assert run.lost_at == at(100)
      assert run.last_heartbeat_at == at(10)
    end

    test "a succeeded or a closed run is not revived" do
      for state <- ~w(succeeded failed timed_out closed) do
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
               last_mode: "enforce",
               last_path_rule: nil,
               last_credential: nil,
               last_request_method: nil,
               last_sequence: 7,
               first_seen_at: at(6),
               last_seen_at: at(7)
             }

      assert %{attempts: 1, method: "HTTPS", last_request_method: "POST"} =
               connections[{"api.example.com", 443, "/v1/messages"}]

      assert %{attempts: 1} = connections[{"api.example.com", 8443, ""}]
    end

    test "the highest sequence is the last, at equal times and against the clock" do
      events = [
        egress(6, %{"outcome" => "connected"}, 50),
        egress(7, %{"outcome" => "dial_failed"}, 50),
        egress(8, %{"outcome" => "refused", "decision" => "denied"}, 10)
      ]

      for order <- [events, Enum.reverse(events)] do
        %{connections: connections} = Fold.fold(@run, order)

        assert %{
                 last_sequence: 8,
                 last_outcome: "refused",
                 last_decision: "denied",
                 attempts: 3,
                 first_seen_at: first,
                 last_seen_at: last
               } = connections[{"api.example.com", 443, ""}]

        assert {first, last} == {at(10), at(50)}
      end
    end

    test "a port outside 0..65535 is not a connection, and long names are cut" do
      path = "/" <> String.duplicate("é", 4000)

      %{connections: connections} =
        Fold.fold(@run, [
          egress(6, %{"port" => 65_536}),
          egress(7, %{"port" => -1}),
          egress(8, %{"port" => 9_999_999_999_999_999_999}),
          egress(9, %{"path" => path, "host" => String.duplicate("h", 300)})
        ])

      assert [{{host, 443, cut}, %{attempts: 1}}] = Map.to_list(connections)
      assert byte_size(host) == 255
      assert byte_size(cut) <= 1024
      assert String.valid?(cut)
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
            {%{"state" => "succeeded"}, "succeeded"},
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

    test "integers outside their columns are read as absent" do
      huge = 9_999_999_999_999_999_999

      for data <- [
            %{"exit_code" => huge, "duration_ms" => huge},
            %{"exit_code" => 2_147_483_648, "duration_ms" => -1},
            %{"exit_code" => 1.5, "duration_ms" => "long"}
          ] do
        %{run: run} = Fold.fold(@run, [exited(18, Map.put(data, "state", "failed"))])
        assert {run.state, run.exit_code, run.duration_ms} == {"failed", nil, nil}
      end

      ping = event(1, "ping", %{"contract_version" => huge, "runner_version" => "v"})
      assert Fold.fold(@run, [ping]).run.contract_version == nil

      assert Fold.fold(@run, [heartbeat(5, huge)]).run.elapsed_seconds == nil
    end

    test "keeps the signal" do
      data = %{"state" => "failed", "exit_code" => -1, "signal" => "SIGKILL"}
      assert Fold.fold(@run, [exited(18, data)]).run.signal == "SIGKILL"
    end

    test "wins over lost, and the run is no longer lost" do
      lost = %{@run | state: "lost", lost_at: at(100)}
      %{run: run} = Fold.fold(lost, [exited(18, %{"state" => "succeeded"})])

      assert run.state == "succeeded"
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
      # Every heartbeat at the same instant on both clocks: only the sequence can decide.
      heartbeat(4, 30, 30, 30),
      event(5, "run.policy_applied", %{"digest" => "second"}),
      heartbeat(6, 60, 15, 30),
      heartbeat(7, 90, 45, 30),
      event(8, "ping", %{"runner_version" => "v0.4.2", "contract_version" => 2}),
      exited(9, %{"state" => "failed", "reason" => "timeout"})
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
