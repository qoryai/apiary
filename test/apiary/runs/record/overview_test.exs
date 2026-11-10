defmodule Apiary.Runs.Record.OverviewTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.Record.Overview
  alias Apiary.Runs.Record.Timeline
  alias ApiaryWeb.TranscriptComponents

  @t0 ~U[2026-09-16 12:00:00.000000Z]

  # The light query reads a tool on an egress event only.
  @tool_types ~w(dev.qory.run.egress)

  defp at(seconds), do: DateTime.add(@t0, round(seconds * 1000), :millisecond)

  defp event(sequence, type, data \\ %{}) do
    %{sequence: sequence, type: "dev.qory." <> type, time: at(sequence), data: data}
  end

  # The light form the index reads, made from a full event the way the query makes it.
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
        tool: if(event.type in @tool_types, do: data["tool"]),
        background_tasks: data["background_tasks"],
        text_kind: text_kind(event.type, data),
        session: if(is_integer(data["session"]), do: data["session"])
      }
    end
  end

  defp text_kind("dev.qory.runtime.text", data) do
    cond do
      data["text"] in [nil, ""] -> "empty"
      data["role"] == "user" -> "prompt"
      true -> data["kind"]
    end
  end

  defp text_kind(_type, _data), do: nil

  defp index(events, opts \\ []), do: events |> light() |> Timeline.index(opts)

  defp items(events, opts \\ []), do: index(events, opts).items

  defp seqs(rows), do: Enum.map(rows, &(&1.seq || &1.id))

  defp tool(sequence, phase, id, extra \\ %{}) do
    event(
      sequence,
      "runtime.tool_" <> phase,
      Map.merge(%{"tool" => "Bash", "tool_use_id" => id}, extra)
    )
  end

  defp egress(sequence, decision, host \\ "registry.example") do
    event(sequence, "run.egress", %{"host" => host, "port" => 443, "decision" => decision})
  end

  defp text(sequence, text, extra \\ %{}) do
    event(sequence, "runtime.text", Map.merge(%{"text" => text, "role" => "assistant"}, extra))
  end

  defp prompt(sequence, text, extra \\ %{}),
    do: text(sequence, text, Map.put(extra, "role", "user"))

  @sub %{"agent_id" => "agent-1", "agent_type" => "Explore"}

  # A whole run: the main agent's prompt and texts, its calls (routine, with a connection
  # inside, failed, denied, and a subagent call), a subagent with a prompt, a routine call
  # and a text, a notification, an allowed and a denied connection outside a call, and the
  # session's and the run's end.
  defp run_events do
    [
      event(1, "run.started"),
      event(2, "run.policy_applied"),
      event(3, "runtime.started"),
      prompt(4, "Redesign the checkout"),
      text(5, "Thinking it over", %{"kind" => "thinking"}),
      text(6, "I'll map the checkout first."),
      tool(7, "started", "a"),
      tool(8, "finished", "a"),
      tool(9, "started", "b"),
      egress(10, "allowed"),
      tool(11, "finished", "b"),
      tool(12, "started", "c"),
      tool(13, "failed", "c"),
      tool(14, "started", "d", %{"tool" => "Read"}),
      tool(15, "denied", "d", %{"tool" => "Read"}),
      tool(16, "started", "t", %{"tool" => "Task"}),
      event(17, "runtime.subagent_started", @sub),
      prompt(18, "Find the checkout form", @sub),
      tool(19, "started", "e", Map.put(@sub, "tool", "Grep")),
      tool(20, "finished", "e", Map.put(@sub, "tool", "Grep")),
      text(21, "CheckoutForm is in the storefront.", @sub),
      event(22, "runtime.subagent_finished", @sub),
      tool(23, "finished", "t", %{"tool" => "Task"}),
      event(24, "runtime.notification", %{"kind" => "permission_prompt"}),
      egress(25, "allowed", "metrics.example"),
      egress(26, "denied", "tracker.example"),
      text(27, "The checkout is done.\nEvery step has a test."),
      event(28, "runtime.turn_finished"),
      event(29, "runtime.result", %{"outcome" => "success", "duration_ms" => 997_000}),
      event(30, "runtime.ended", %{"reason" => "other"}),
      event(31, "run.exited", %{"exit_code" => 0})
    ]
  end

  defp built(events, index, seqs) do
    Timeline.build(
      Enum.filter(index.items, &(&1.seq in seqs)),
      Map.new(events, &{&1.sequence, Timeline.slim(&1)})
    )
  end

  defp main(rows), do: Enum.find(rows, &(&1.kind == :main_session))

  # A row's place as the run page compares it.
  defp pos(row), do: row[:pos] || {row.seq, row.seq}

  defp version(at, number, public_id),
    do: %{type: "proposal", name: "main", number: number, at: at, public_id: public_id}

  # Whether a light item has a Transcript line, as the run page reads it.
  defp line?(index), do: &TranscriptComponents.line?(&1, index.texts)

  # The light item of a sequence.
  defp item(items, seq), do: Enum.find(items, &(&1.seq == seq))

  describe "rows/2 and routine?/1" do
    test "a finished call with nothing inside leaves; a failed, a denied and a connection's call stay" do
      rows = Overview.rows(items(run_events()))

      refute 7 in seqs(rows)
      assert 9 in seqs(rows)
      assert 12 in seqs(rows)
      assert 14 in seqs(rows)

      [routine, connection, failed, denied] =
        Enum.map([7, 9, 12, 14], fn seq -> Enum.find(items(run_events()), &(&1.seq == seq)) end)

      assert Overview.routine?(routine)
      refute Overview.routine?(connection)
      refute Overview.routine?(failed)
      refute Overview.routine?(denied)
    end

    test "a call with a denied connection inside stays" do
      rows =
        Overview.rows(
          items([tool(1, "started", "a"), egress(2, "denied"), tool(3, "finished", "a")])
        )

      assert [%{seq: 1, denied_inside: true}] = rows
    end

    test "a running call leaves until it fails, is denied or has a connection inside" do
      running = items([tool(1, "started", "a")], alive: true)
      assert [%{tool_state: :open}] = running
      assert Overview.rows(running) == []

      with_connection = items([tool(1, "started", "a"), egress(2, "allowed")], alive: true)
      assert [%{seq: 1}] = Overview.rows(with_connection)

      failed = items([tool(1, "started", "a"), tool(2, "failed", "a")], alive: true)
      assert [%{seq: 1}] = Overview.rows(failed)
    end

    test "a call with no end stays once its turn, its session or the run ended" do
      for ended <- [
            event(2, "runtime.turn_finished"),
            event(2, "runtime.ended"),
            event(2, "run.exited")
          ] do
        items = items([tool(1, "started", "a"), ended], alive: true)
        assert [%{seq: 1, tool_state: :no_end} | _] = items
        assert 1 in seqs(Overview.rows(items))
      end

      stopped = items([tool(1, "started", "a")], alive: false)
      assert [%{seq: 1, tool_state: :no_end}] = Overview.rows(stopped)
    end

    test "a Task or Agent call leaves unless it failed, was denied, or has a connection or denial inside" do
      for name <- ["Task", "Agent"] do
        call = %{"tool" => name}

        finished = items([tool(1, "started", "a", call), tool(2, "finished", "a", call)])
        assert Overview.rows(finished) == []

        running = items([tool(1, "started", "a", call)], alive: true)
        assert Overview.rows(running) == []

        failed = items([tool(1, "started", "a", call), tool(2, "failed", "a", call)])
        assert [%{seq: 1}] = Overview.rows(failed)

        denied = items([tool(1, "denied", "a", call)])
        assert [%{seq: 1}] = Overview.rows(denied)

        inside =
          for decision <- ["allowed", "denied"] do
            [tool(1, "started", "a", call), egress(2, decision), tool(3, "finished", "a", call)]
            |> items()
            |> Overview.rows()
          end

        assert [[%{seq: 1}], [%{seq: 1}]] = inside

        no_end = items([tool(1, "started", "a", call), event(2, "runtime.ended")], alive: true)
        assert 1 in seqs(Overview.rows(no_end))
      end

      refute 16 in seqs(Overview.rows(items(run_events())))
    end

    test "every item that is not a tool call stays, but thinking" do
      events = [
        event(1, "run.started"),
        event(2, "run.policy_applied"),
        event(3, "runtime.started"),
        event(4, "runtime.prompt_submitted", %{"prompt" => "Go"}),
        prompt(5, "Redesign the checkout"),
        text(6, "Thinking it over", %{"kind" => "thinking"}),
        text(7, "On it."),
        event(8, "runtime.subagent_started", @sub),
        event(9, "runtime.subagent_finished", @sub),
        event(10, "runtime.notification"),
        event(11, "runtime.turn_finished"),
        event(12, "runtime.turn_failed"),
        event(13, "runtime.result"),
        event(14, "runtime.ended"),
        egress(15, "denied"),
        event(16, "run.exited"),
        event(17, "run.refused")
      ]

      items = items(events)
      assert Enum.find(items, &(&1.seq == 6)).kind == :thinking
      assert seqs(Overview.rows(items)) == List.delete(Enum.to_list(1..17), 6)
    end

    test "an allowed connection outside a call, alone or in a group, stays only with Connections inline" do
      events = [
        egress(1, "allowed", "metrics.example"),
        egress(2, "denied", "tracker.example"),
        egress(3, "allowed"),
        egress(4, "allowed")
      ]

      items = items(events)

      assert [%{kind: :connection}, %{kind: :connection}, %{seq: 3, kind: :connection_group}] =
               items

      assert seqs(Overview.rows(items)) == [2]
      assert seqs(Overview.rows(items, connections: true)) == [1, 2, 3]
    end
  end

  describe "list/2: the Main session row" do
    test "one row after the main agent's first prompt, with that prompt's sequence and a unique id" do
      rows = Overview.list(items(run_events()))

      assert seqs(rows) == [
               1,
               2,
               3,
               4,
               "main-session",
               6,
               9,
               12,
               14,
               17,
               18,
               21,
               22,
               24,
               26,
               27,
               28,
               29,
               30,
               31
             ]

      main = main(rows)
      assert %{kind: :main_session, seq: nil, sequence: 4, id: "main-session"} = main
      assert pos(main) > {4, 4} and pos(main) < {6, 6}
    end

    test "calls are every tool call of the main agent, routine ones included" do
      # 7 routine, 9 with a connection, 12 failed, 14 denied, 16 the Task call; 19
      # is a call of the subagent.
      assert %{calls: 5} = main(Overview.list(items(run_events())))
    end

    test "the words are the first line of the main agent's last text; Took is the result's" do
      events = run_events()
      index = index(events)
      row = main(Overview.list(index.items))

      assert %{text_seq: 27, result_seqs: [29], seqs: [27, 29]} = row

      shown = Overview.build(row, built(events, index, row.seqs))

      assert %{
               kind: :main_session,
               id: "main-session",
               sequence: 4,
               calls: 5,
               words: "The checkout is done.",
               duration_ms: 997_000
             } = shown

      assert shown.time == at(4)
      refute Map.has_key?(shown, :pos)
    end

    test "Took is empty while the live run has no result" do
      events = Enum.take(run_events(), 24)
      index = index(events, alive: true)
      row = main(Overview.list(index.items))

      assert %{text_seq: 6, result_seqs: [], seqs: [6]} = row

      assert %{words: "I'll map the checkout first.", duration_ms: nil} =
               Overview.build(row, built(events, index, row.seqs))
    end

    test "a run with two main prompts has one row, after the first; Took is both results' sum" do
      events = [
        event(1, "runtime.started"),
        prompt(2, "Redesign the checkout"),
        text(3, "Done."),
        event(4, "runtime.result", %{"duration_ms" => 1000}),
        prompt(5, "Add a test"),
        text(6, "Added."),
        event(7, "runtime.result", %{"duration_ms" => 2000})
      ]

      index = index(events)
      rows = Overview.list(index.items)
      assert seqs(rows) == [1, 2, "main-session", 3, 4, 5, 6, 7]
      row = main(rows)
      assert %{text_seq: 6, result_seqs: [4, 7], seqs: [6, 4, 7]} = row

      assert %{words: "Added.", duration_ms: 3000} =
               Overview.build(row, built(events, index, row.seqs))
    end

    test "each agent session has its row, after its first prompt, with its calls and Took" do
      events = [
        prompt(1, "Before the runtime started"),
        event(2, "runtime.started", %{"session" => 1}),
        tool(3, "failed", "a"),
        text(4, "One."),
        event(5, "runtime.result", %{"duration_ms" => 1000}),
        event(6, "runtime.started", %{"session" => 2}),
        event(7, "runtime.notification", %{"kind" => "idle"}),
        event(8, "runtime.started", %{"session" => 3}),
        prompt(9, "Add a test"),
        tool(10, "failed", "b"),
        tool(11, "failed", "c"),
        text(12, "Three."),
        event(13, "runtime.result", %{"duration_ms" => 3000})
      ]

      index = index(events)
      rows = Overview.list(index.items)
      # Session 2 has no prompt, so no row: the second row is session 3's.
      assert seqs(rows) == [
               1,
               "main-session",
               2,
               3,
               4,
               5,
               6,
               7,
               8,
               9,
               "main-session-2",
               10,
               11,
               12,
               13
             ]

      assert [first, third] = Enum.filter(rows, &(&1.kind == :main_session))
      assert %{sequence: 1, calls: 1, text_seq: 4, result_seqs: [5]} = first
      assert %{sequence: 9, calls: 2, text_seq: 12, result_seqs: [13]} = third
      assert pos(third) > {9, 9} and pos(third) < {10, 10}

      assert %{id: "main-session-2", words: "Three.", duration_ms: 3000} =
               Overview.build(third, built(events, index, third.seqs))
    end

    test "sessions that overlap in time keep their items apart by their session number" do
      one = %{"session" => 1}
      two = %{"session" => 2}

      # Session 2 starts while session 1 still works: its call, text and result come after.
      events = [
        event(3, "runtime.started", one),
        prompt(4, "Map the checkout", one),
        event(5, "runtime.started", two),
        prompt(6, "Add a test", two),
        tool(7, "failed", "a", one),
        text(8, "The checkout has four steps.", one),
        event(9, "runtime.result", Map.put(one, "duration_ms", 1000))
      ]

      index = index(events)
      rows = Overview.list(index.items)
      assert seqs(rows) == [3, 4, "main-session", 5, 6, "main-session-2", 7, 8, 9]

      assert [first, second] = Enum.filter(rows, &(&1.kind == :main_session))
      assert %{sequence: 4, session: 1, calls: 1, text_seq: 8, result_seqs: [9]} = first
      assert %{sequence: 6, session: 2, calls: 0, text_seq: nil, result_seqs: []} = second
    end

    test "a subagent's result is no part of the Main session's Took" do
      events = [
        prompt(1, "Redesign the checkout"),
        event(2, "runtime.subagent_started", @sub),
        event(3, "runtime.result", Map.put(@sub, "duration_ms", 5000)),
        event(4, "runtime.subagent_finished", @sub),
        event(5, "runtime.result", %{"duration_ms" => 1000})
      ]

      index = index(events)
      row = main(Overview.list(index.items))
      assert %{result_seqs: [5]} = row
      assert %{duration_ms: 1000} = Overview.build(row, built(events, index, row.seqs))
    end

    test "a run without a prompt of the main agent has none" do
      events = [event(1, "runtime.started"), prompt(2, "Find the form", @sub)]
      assert main(Overview.list(items(events))) == nil
      assert length(Overview.list(items(events))) == 2
    end
  end

  describe "list/2: Pushed rows" do
    test "a version sits by time between two rows, with no sequence" do
      rows = Overview.list(items(run_events()), versions: [version(at(7.5), 2, "av_one")])

      assert seqs(rows) |> Enum.slice(4, 4) == ["main-session", 6, "push-av_one", 9]

      pushed = Enum.find(rows, &(&1.kind == :pushed))

      assert %{
               id: "push-av_one",
               seq: nil,
               sequence: nil,
               type: "proposal",
               name: "main",
               number: 2
             } = pushed

      assert pos(pushed) > {6, 6} and pos(pushed) < {9, 9}

      assert %{time: time, type: "proposal"} = Overview.build(pushed)
      assert time == at(7.5)
    end

    test "a version at a row's time sits after it" do
      rows = Overview.list(items(run_events()), versions: [version(at(6), 1, "av_one")])
      assert seqs(rows) |> Enum.slice(5, 3) == [6, "push-av_one", 9]
    end

    test "a version before the first row comes first, one after the last comes last" do
      rows =
        Overview.list(items(run_events()),
          versions: [version(at(100), 3, "av_late"), version(at(0), 1, "av_early")]
        )

      assert ["push-av_early", 1 | _] = seqs(rows)
      assert [31, "push-av_late"] = seqs(rows) |> Enum.take(-2)
      assert pos(hd(rows)) < {1, 1}
      assert pos(List.last(rows)) > {31, 31}
    end

    test "two versions in one place are in order of time, then number" do
      versions = [
        version(at(7.5), 2, "av_b"),
        version(at(7.5), 1, "av_a"),
        version(at(7.2), 5, "av_first")
      ]

      rows = Overview.list(items(run_events()), versions: versions)

      assert seqs(rows) |> Enum.slice(5, 5) == [6, "push-av_first", "push-av_a", "push-av_b", 9]
    end

    test "every row's place compares in the order of the list" do
      versions = [
        version(at(0), 1, "av_a"),
        version(at(4), 1, "av_b"),
        version(at(40), 1, "av_c")
      ]

      rows = Overview.list(items(run_events()), versions: versions)

      assert Enum.sort_by(rows, &pos/1) == rows
      assert rows |> Enum.map(&pos/1) |> Enum.uniq() |> length() == length(rows)
    end
  end

  describe "rails" do
    test "a row without a sequence continues the rails of the row before it" do
      rows = Overview.list(items(run_events()))
      [prompt, main] = Enum.filter(rows, &(&1.seq == 4 or &1.kind == :main_session))

      assert Enum.map(main.rails, & &1.rail) == Enum.map(prompt.rails, & &1.rail)
      assert Enum.all?(main.rails, &(&1.part == :through))
    end

    test "the last row ends the rails when the index's last item is not listed" do
      events = [
        event(1, "run.started"),
        prompt(2, "Go"),
        tool(3, "started", "a"),
        tool(4, "finished", "a")
      ]

      rows = Overview.list(items(events))
      assert [%{rail: 0, part: :to}] = List.last(rows).rails

      live = Overview.list(items(events, alive: true))
      assert [%{rail: 0, part: :live}] = List.last(live).rails
    end
  end

  describe "list/2: the count" do
    test "the rows listed, Main session and Pushed rows included" do
      items = items(run_events())
      versions = [version(at(7.5), 1, "av_one")]

      assert length(Overview.list(items)) == 20
      assert length(Overview.list(items, versions: versions)) == 21
    end

    test "an allowed connection is listed only with Connections inline" do
      items = items(run_events())

      assert length(Overview.list(items, connections: true)) ==
               length(Overview.list(items)) + 1

      assert 25 in seqs(Overview.list(items, connections: true))
      refute 25 in seqs(Overview.list(items))
    end
  end

  describe "terminal_seq/2" do
    test "a row with a Transcript line links to its sequence; the others link nowhere" do
      index = index(run_events())
      line? = line?(index)

      links =
        index.items
        |> Overview.list(versions: [version(at(7.5), 1, "av_one")])
        |> Map.new(&{&1.seq || &1.id, Overview.terminal_seq(&1, line?)})

      for seq <- [4, 6, 9, 12, 14, 17, 18, 21, 27, 29], do: assert(links[seq] == seq)
      for seq <- [1, 2, 3, 22, 24, 26, 28, 30, 31], do: assert(links[seq] == nil)

      assert links["main-session"] == 27
      assert links["push-av_one"] == nil
    end

    test "a turn's end links only in a run whose Transcript has its line: one without texts" do
      events = [prompt(1, "Go"), event(2, "runtime.turn_finished")]
      index = index(events)
      assert index.texts == 0
      assert [_prompt, _main, turn] = Overview.list(index.items)
      assert Overview.terminal_seq(turn, line?(index)) == 2

      index = index(events ++ [text(3, "Done.")])
      assert Overview.terminal_seq(item(index.items, 2), line?(index)) == nil
    end

    test "a subagent's start without a lane, and a Main session without a text, link nowhere" do
      index = index([prompt(1, "Go"), event(2, "runtime.subagent_started")])
      line? = line?(index)

      assert [_prompt, main, start] = Overview.list(index.items)
      assert Overview.terminal_seq(main, line?) == nil
      assert Overview.terminal_seq(start, line?) == nil
    end

    test "a row links where the Transcript has a line at its sequence" do
      for events <- [run_events(), Enum.take(run_events(), 28)] do
        index = index(events)

        lines =
          MapSet.new(
            TranscriptComponents.lines(index.items, index.texts, subagents: true),
            & &1.seq
          )

        for row <- Overview.list(index.items), is_integer(row.seq) do
          assert Overview.terminal_seq(row, line?(index)) ==
                   if(MapSet.member?(lines, row.seq), do: row.seq)
        end
      end
    end
  end

  describe "focus/3" do
    test "a listed row's sequence goes to its row" do
      items = items(run_events())
      rows = Overview.list(items)
      assert {:row, %{seq: 9}} = Overview.focus(rows, item(items, 9), true)
      assert {:row, %{seq: 9}} = Overview.focus(rows, item(items, 9), false)
    end

    test "a routine call goes to the Terminal for a reader of the log" do
      items = items(run_events())
      rows = Overview.list(items)
      assert Overview.focus(rows, item(items, 7), true) == {:terminal, 7}
      assert Overview.focus(rows, item(items, 19), true) == {:terminal, 19}
    end

    test "for a reader without the log, a routine call goes to the nearest row before it" do
      items = items(run_events())
      rows = Overview.list(items)
      assert {:row, %{seq: 6}} = Overview.focus(rows, item(items, 7), false)
      assert {:row, %{seq: 18}} = Overview.focus(rows, item(items, 19), false)
    end

    test "a row without a sequence before a routine call is passed over" do
      items = items(run_events())
      rows = Overview.list(items, versions: [version(at(6.5), 1, "av_one")])
      assert "push-av_one" in seqs(rows)
      assert {:row, %{seq: 6}} = Overview.focus(rows, item(items, 7), false)

      # The routine call comes after the Main session row, which has no sequence.
      events = [prompt(1, "Go"), tool(2, "started", "a"), tool(3, "finished", "a")]
      items = items(events)
      rows = Overview.list(items)
      assert seqs(rows) == [1, "main-session"]
      assert {:row, %{seq: 1}} = Overview.focus(rows, item(items, 2), false)
    end

    test "with no row before it, nowhere" do
      items =
        items([tool(1, "started", "a"), tool(2, "finished", "a"), event(3, "run.started")])

      assert Overview.focus(Overview.list(items), item(items, 1), false) == nil
    end

    test "thinking and an allowed connection with Connections inline off have no row: unlisted" do
      items = items(run_events())
      rows = Overview.list(items)

      for seq <- [5, 25] do
        assert Overview.focus(rows, item(items, seq), true) == :unlisted
        assert Overview.focus(rows, item(items, seq), false) == :unlisted
      end

      assert {:row, %{seq: 25}} =
               Overview.focus(Overview.list(items, connections: true), item(items, 25), true)
    end
  end
end
