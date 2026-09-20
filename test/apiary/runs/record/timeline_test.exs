defmodule Apiary.Runs.Record.TimelineTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.Record.Timeline

  @t0 ~U[2026-09-16 12:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@t0, round(seconds * 1000), :millisecond)

  # A full event; the light form the index reads is made from it the way the query does.
  defp event(sequence, type, data \\ %{}) do
    %{sequence: sequence, type: "ai.qory." <> type, time: at(sequence), data: data}
  end

  defp light(events) do
    for %{data: data} = event <- events do
      %{
        sequence: event.sequence,
        type: event.type,
        time: event.time,
        tool_use_id: data["tool_use_id"],
        agent_id: data["agent_id"],
        agent_type: data["agent_type"],
        host: data["host"],
        port: data["port"] && to_string(data["port"]),
        decision: data["decision"],
        background_tasks: data["background_tasks"]
      }
    end
  end

  defp index(events, opts \\ []), do: events |> light() |> Timeline.index(opts)

  defp build(events, opts \\ []) do
    index = index(events)
    Timeline.build(index.items, Map.new(events, &{&1.sequence, &1}), opts)
  end

  defp egress(sequence, extra \\ %{}) do
    event(
      sequence,
      "run.egress",
      Map.merge(
        %{
          "host" => "api.example",
          "port" => 443,
          "method" => "CONNECT",
          "decision" => "allowed",
          "outcome" => "connected",
          "mode" => "enforce",
          "rule" => "api.example"
        },
        extra
      )
    )
  end

  defp tool(sequence, phase, id, extra \\ %{}) do
    event(
      sequence,
      "session.tool_" <> phase,
      Map.merge(%{"tool" => "Bash", "tool_use_id" => id}, extra)
    )
  end

  defp subagent(sequence, phase, id, type, extra \\ %{}) do
    event(
      sequence,
      "session.subagent_" <> phase,
      Map.merge(%{"agent_id" => id, "agent_type" => type}, extra)
    )
  end

  describe "index/2: items" do
    test "heartbeats, log chunks, the ping and unknown types are not items" do
      index =
        index([
          event(1, "ping"),
          event(2, "run.started"),
          event(3, "run.log", %{"stream" => "stdout", "bytes" => ""}),
          event(4, "run.heartbeat"),
          event(5, "something.unheard_of"),
          event(6, "session.prompt_submitted", %{"prompt" => "hello"})
        ])

      assert Enum.map(index.items, &{&1.seq, &1.kind}) == [{2, :run_started}, {6, :prompt}]
      assert index.session_items == 1
      assert index.hook_events == 1
    end

    test "a tool's three events pair up by tool_use_id into one item at the start's sequence" do
      index =
        index([
          tool(1, "started", "a"),
          tool(2, "started", "b"),
          tool(3, "failed", "b"),
          tool(4, "finished", "a")
        ])

      assert [%{seq: 1, end_seq: 4, seqs: [1, 4]}, %{seq: 2, end_seq: 3, seqs: [2, 3]}] =
               index.items

      assert index.by_seq == %{1 => 1, 4 => 1, 2 => 2, 3 => 2}
    end

    test "an end without its start is an item of its own, and a start without an end stays open" do
      index = index([tool(1, "finished", "lost"), tool(2, "started", "open")])

      assert [%{seq: 1, end_seq: nil}, %{seq: 2, end_seq: nil}] = index.items

      assert [%{status: :finished}, %{status: :open}] =
               build([tool(1, "finished", "lost"), tool(2, "started", "open")])
    end

    test "session.result is the session's but not a hook's" do
      index = index([event(1, "session.result", %{"outcome" => "success"})])
      assert index.session_items == 1
      assert index.hook_events == 0
    end
  end

  describe "index/2: connections by sequence" do
    test "inside the one open call, between items when none or several are open" do
      index =
        index([
          egress(1),
          tool(2, "started", "a"),
          egress(3, %{"decision" => "denied"}),
          tool(4, "started", "b"),
          egress(5),
          tool(6, "finished", "b"),
          egress(7),
          tool(8, "finished", "a"),
          egress(9, %{"host" => "other.example"})
        ])

      assert [
               %{seq: 1, kind: :connection, open_calls: 0},
               %{seq: 2, kind: :tool, inner: [3, 7], seqs: [2, 3, 7, 8]},
               %{seq: 4, kind: :tool, inner: []},
               %{seq: 5, kind: :connection, open_calls: 2},
               %{seq: 9, kind: :connection, open_calls: 0}
             ] = index.items

      assert index.by_seq[7] == 2
    end

    test "a run of allowed connections to one host collapses; a denied one never does" do
      index =
        index([
          egress(1),
          egress(2),
          egress(3),
          egress(4, %{"decision" => "denied"}),
          egress(5, %{"decision" => "denied"}),
          egress(6),
          egress(7, %{"host" => "other.example"}),
          event(8, "session.notification"),
          egress(9, %{"host" => "other.example"})
        ])

      assert [
               %{seq: 1, kind: :connection_group, seqs: [1, 2, 3]},
               %{seq: 4, kind: :connection},
               %{seq: 5, kind: :connection},
               %{seq: 6, kind: :connection},
               %{seq: 7, kind: :connection},
               %{seq: 8, kind: :notification},
               %{seq: 9, kind: :connection}
             ] = index.items

      assert [
               %{
                 kind: :connection_group,
                 connections_count: 3,
                 host: "api.example",
                 first_at: first,
                 last_at: last
               }
               | _
             ] =
               build([egress(1), egress(2), egress(3)])

      assert first == at(1) and last == at(3)
    end
  end

  describe "index/2: lanes" do
    test "one rail per agent, bracketed by its start and finish; a rail is reused, the hue cycles" do
      index =
        index([
          event(1, "session.prompt_submitted"),
          subagent(2, "started", "a1", "Explore"),
          subagent(3, "started", "a2", "general-purpose"),
          tool(4, "started", "t1", %{"agent_id" => "a2", "agent_type" => "general-purpose"}),
          subagent(5, "finished", "a1", "Explore"),
          subagent(6, "started", "a3", "Plan"),
          subagent(7, "finished", "a2", "general-purpose"),
          subagent(8, "finished", "a3", "Plan"),
          event(9, "session.turn_finished")
        ])

      assert [
               %{id: "main", rail: 0, color: :main},
               %{id: "a1", type: "Explore", rail: 1, color: :a, started_seq: 2, finished_seq: 5},
               %{id: "a2", rail: 2, color: :b, started_seq: 3, finished_seq: 7},
               %{id: "a3", rail: 1, color: :c, started_seq: 6, finished_seq: 8}
             ] = index.lanes

      assert index.rails == 3

      rails = Map.new(index.items, &{&1.seq, Enum.map(&1.rails, fn r -> {r.rail, r.part} end)})

      assert rails[1] == [{0, :from}]
      assert rails[2] == [{0, :through}, {1, :from}]
      assert rails[4] == [{0, :through}, {1, :through}, {2, :through}]
      assert rails[5] == [{0, :through}, {1, :to}, {2, :through}]
      assert rails[6] == [{0, :through}, {1, :from}, {2, :through}]
      assert rails[9] == [{0, :to}]

      items = Map.new(index.items, &{&1.seq, &1})
      assert items[4].lane.id == "a2" and items[4].lane.rail == 2
      assert items[2].link == %{rail: 1, color: :a}
      assert items[2].who and items[5].who
      refute items[4].who
    end

    test "past four rails an agent sits on the last rail and says who in words" do
      started = for n <- 1..4, do: subagent(n, "started", "a#{n}", "Explore")

      index =
        index(
          started ++ [tool(5, "started", "t", %{"agent_id" => "a4", "agent_type" => "Explore"})]
        )

      assert index.rails == 4
      assert %{rail: 3, overflow: true} = List.last(index.lanes)
      assert %{who: true, lane: %{rail: 3}} = List.last(index.items)
      assert %{link: nil} = Enum.at(index.items, 3)
    end

    test "an agent the record opened no lane for sits on the main rail and says who" do
      assert [%{who: true, lane: %{rail: 0, id: "ghost"}}] =
               index([
                 tool(1, "started", "t", %{"agent_id" => "ghost", "agent_type" => "Explore"})
               ]).items
    end

    test "the last item's rails fade while the record is still being written" do
      events = [event(1, "session.prompt_submitted"), event(2, "session.turn_finished")]

      assert [_, %{rails: [%{part: :live}]}] = index(events, alive: true).items
      assert [_, %{rails: [%{part: :to}]}] = index(events, alive: false).items
    end
  end

  describe "index/2: background tasks" do
    test "a task runs from the first list that names it to the first later list that leaves it out" do
      task = fn id ->
        %{"id" => id, "type" => "shell", "status" => "running", "command" => "pytest -q"}
      end

      events = [
        event(1, "session.turn_finished", %{"background_tasks" => [task.("b1")]}),
        subagent(2, "finished", "a1", "Explore", %{
          "background_tasks" => [task.("b1"), task.("b2")]
        }),
        event(3, "session.turn_finished", %{}),
        event(4, "session.turn_finished", %{"background_tasks" => [task.("b2")]})
      ]

      assert %{
               count: 2,
               tasks: [%{id: "b1", listed_at: 1, what: "pytest -q"}, %{id: "b2", listed_at: 2}]
             } =
               index(Enum.take(events, 3)).background

      assert %{count: 1, tasks: [%{id: "b2", listed_at: 2, type: "shell"}]} =
               index(events).background

      assert %{count: 0, tasks: []} =
               index(events ++ [event(5, "session.turn_finished", %{"background_tasks" => []})]).background
    end

    test "an entry that is not an object with an id is ignored" do
      events = [
        event(1, "session.turn_finished", %{"background_tasks" => ["x", %{"type" => "shell"}, 7]})
      ]

      assert %{count: 0} = index(events).background
    end
  end

  describe "build/3" do
    test "a tool: the summary is copied from the input, the wells are its input and its response" do
      input = %{
        "command" => "npm test",
        "description" => "Run the tests",
        "run_in_background" => true
      }

      [item] =
        build([
          tool(1, "started", "a", %{"input" => input}),
          egress(2, %{"decision" => "denied", "rule" => ""}),
          tool(3, "finished", "a", %{
            "input" => input,
            "response" => %{"stdout" => "ok\n", "stderr" => "warn"},
            "duration_ms" => 3400
          })
        ])

      assert %{
               id: "e-1",
               kind: :tool,
               tool: "Bash",
               summary: {:text, "npm test"},
               status: :finished,
               duration_ms: 3400,
               in_background: true,
               denied_inside: true,
               connections: [%{sequence: 2, decision: "denied", rule: nil, host: "api.example"}],
               wells: [
                 %{label: "input", format: :json},
                 %{label: "stdout", format: :text, text: "ok\n", lines: 1, cut: false},
                 %{label: "stderr", tone: :error}
               ]
             } = item
    end

    test "summaries per tool" do
      summary = fn tool, input ->
        [item] =
          build([
            event(1, "session.tool_started", %{
              "tool" => tool,
              "tool_use_id" => "x",
              "input" => input
            })
          ])

        item.summary
      end

      assert summary.("Read", %{"file_path" => "/work/a.py", "limit" => 5}) ==
               {:text, "/work/a.py"}

      assert summary.("Grep", %{"pattern" => "vat", "path" => "/work"}) ==
               {:pattern, "vat", "/work"}

      assert summary.("Glob", %{"pattern" => "**/*.ex"}) == {:text, "**/*.ex"}

      assert summary.("WebFetch", %{"url" => "https://docs.example/a", "prompt" => "p"}) ==
               {:text, "https://docs.example/a"}

      assert summary.("Task", %{"description" => "Explore", "prompt" => "p"}) ==
               {:text, "Explore"}

      assert summary.("Custom", %{"a" => 1, "b" => "first string", "c" => "second"}) ==
               {:text, "first string"}

      assert summary.("Custom", %{}) == nil
    end

    test "a failed tool carries the error and whether it was interrupted" do
      [item] =
        build([
          tool(1, "started", "a"),
          tool(2, "failed", "a", %{"error" => "Exit code 1", "interrupted" => true})
        ])

      assert %{
               status: :failed,
               interrupted: true,
               wells: [%{label: "error", tone: :error, text: "Exit code 1"}]
             } = item
    end

    test "a payload over the cap is cut on a character, and given whole when asked" do
      big = String.duplicate("é", 5000)
      events = [tool(1, "started", "a"), tool(2, "finished", "a", %{"response" => big})]

      assert [%{full: false, wells: [%{cut: true, bytes: 10_000, text: text}]}] = build(events)
      assert byte_size(text) <= Timeline.well_limit()
      assert String.valid?(text)

      assert [%{full: true, wells: [%{cut: false, text: ^big}]}] = build(events, full: [1])
    end

    test "a file the tool read shows its content; any other object is JSON" do
      read = %{"type" => "text", "file" => %{"content" => "line 1\nline 2", "numLines" => 2}}

      assert [%{wells: [%{format: :text, text: "line 1\nline 2", lines: 2}]}] =
               build([tool(1, "started", "a"), tool(2, "finished", "a", %{"response" => read})])

      assert [%{wells: [%{format: :json, text: json}]}] =
               build([
                 tool(1, "started", "a"),
                 tool(2, "finished", "a", %{"response" => %{"numFiles" => 4}})
               ])

      assert json =~ ~s("numFiles": 4)
    end

    test "a subagent's finish carries the lane's length, from the two events' times" do
      events = [
        subagent(2, "started", "a1", "Explore"),
        subagent(8, "finished", "a1", "Explore", %{"message" => "done"})
      ]

      index = index(events)

      assert Timeline.needed([List.last(index.items)], index.lanes) |> Enum.sort() == [2, 8]

      assert [
               _,
               %{kind: :subagent_finished, duration_ms: 6000, text: "done", agent_type: "Explore"}
             ] = build(events)
    end

    test "the runner's own items and the session's simple ones" do
      items =
        build([
          event(1, "run.started", %{
            "runtime" => "claude",
            "runtime_version" => "2.1",
            "host" => "build-01",
            "wall" => "docker"
          }),
          event(2, "run.policy_applied", %{
            "mode" => "enforce",
            "allow" => ["a", "b"],
            "source" => "fetched",
            "terminated" => ["a"]
          }),
          event(3, "session.started", %{"model" => "m", "source" => "startup", "cwd" => "/work"}),
          event(4, "session.notification", %{
            "kind" => "permission_prompt",
            "message" => "needs permission"
          }),
          event(5, "session.turn_failed", %{"error" => "rate_limit", "details" => "429"}),
          event(6, "session.result", %{
            "outcome" => "success",
            "turns" => 7,
            "duration_ms" => 161_000,
            "cost_usd" => 0.42,
            "result" => "ok"
          }),
          event(7, "session.ended", %{"reason" => "other"}),
          event(8, "run.exited", %{
            "state" => "failed",
            "exit_code" => -1,
            "signal" => "SIGKILL",
            "duration_ms" => 5
          })
        ])

      assert [
               %{kind: :run_started, runtime: "claude", host: "build-01", wall: "docker"},
               %{
                 kind: :policy_applied,
                 mode: "enforce",
                 allowed_hosts: 2,
                 terminated: ["a"],
                 source: "fetched"
               },
               %{kind: :session_started, model: "m", cwd: "/work"},
               %{kind: :notification, notification_kind: "permission_prompt"},
               %{
                 kind: :turn_failed,
                 error: "rate_limit",
                 wells: [%{label: "details", tone: :error}]
               },
               %{kind: :result, outcome: "success", turns: 7, cost_usd: 0.42, text: "ok"},
               %{kind: :session_ended, reason: "other"},
               %{kind: :run_exited, exit_code: -1, signal: "SIGKILL"}
             ] = items
    end

    test "data of the wrong shape reads as absent, never as a crash" do
      assert [%{kind: :tool, tool: "tool", summary: nil, wells: []}] =
               build([
                 event(1, "session.tool_started", %{
                   "tool" => 7,
                   "input" => "not a map",
                   "tool_use_id" => []
                 })
               ])

      assert [%{kind: :result, turns: nil, cost_usd: nil, text: nil}] =
               build([
                 event(1, "session.result", %{
                   "turns" => "many",
                   "cost_usd" => "free",
                   "result" => 5
                 })
               ])
    end
  end
end
