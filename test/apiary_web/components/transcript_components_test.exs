defmodule ApiaryWeb.TranscriptComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Runs.Record.Timeline
  alias ApiaryWeb.TranscriptComponents

  @t0 ~U[2026-11-01 12:00:00Z]

  defp event(sequence, type, data) do
    %{sequence: sequence, type: "dev.qory.runtime." <> type, time: @t0, data: data}
  end

  # The items of `events` as the run page builds them, each with `open` as the page sets it.
  defp items(events, open \\ [], lines? \\ false) do
    index = Timeline.index(light(events))
    full = Timeline.full_limit()
    light = if lines?, do: TranscriptComponents.lines(index.items, index.texts), else: index.items

    light
    |> Timeline.build(Map.new(events, &{&1.sequence, Timeline.slim(&1, full)}))
    |> Enum.map(&Map.put(&1, :open, &1.sequence in open))
  end

  # The lines of `events` as the Terminal tab shows them, each subagent's under its start
  # (`TranscriptComponents.arrange/4`): `alive` is whether the record is being written,
  # `choices` the reader's, `focused` the line `?seq=` points at.
  defp grouped(events, opts \\ []) do
    index = Timeline.index(light(events), alive: Keyword.get(opts, :alive, true))
    subagents = TranscriptComponents.subagents(index.items, index.alive)
    full = Timeline.full_limit()

    index.items
    |> TranscriptComponents.lines(index.texts, subagents: true)
    |> TranscriptComponents.arrange(subagents, Keyword.get(opts, :choices, %{}), opts[:focused])
    |> Timeline.build(Map.new(events, &{&1.sequence, Timeline.slim(&1, full)}))
    |> Enum.map(&Map.put(&1, :open, false))
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
        tool: data["tool"],
        text_kind: text_kind(event.type, data)
      }
    end
  end

  # The event `seconds` after the first.
  defp at(event, seconds), do: %{event | time: DateTime.add(@t0, seconds)}

  # The lines of `events` as the Terminal tab shows them (`TranscriptComponents.lines/2`).
  defp lines(events), do: items(events, [], true)

  # As the light query reads it: "empty" for a text without text, "prompt" for a user's.
  defp text_kind("dev.qory.runtime.text", data) do
    cond do
      data["text"] in [nil, ""] -> "empty"
      data["role"] == "user" -> "prompt"
      true -> data["kind"]
    end
  end

  defp text_kind(_type, _data), do: nil

  defp html(items, attrs \\ []) do
    render_component(
      &TranscriptComponents.transcript/1,
      Keyword.merge([id: "transcript", stream: Enum.map(items, &{&1.id, &1})], attrs)
    )
  end

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp texts(html, selector), do: html |> query(selector) |> Enum.map(&LazyHTML.text/1)

  defp squeeze(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp started(sequence, id, extra \\ %{}),
    do:
      event(sequence, "tool_started", Map.merge(%{"tool" => "Bash", "tool_use_id" => id}, extra))

  defp result(sequence, id, content, extra \\ %{}) do
    event(
      sequence,
      "tool_result",
      Map.merge(%{"session_id" => "s1", "tool_use_id" => id, "content" => content}, extra)
    )
  end

  defp text(sequence, text, extra \\ %{}) do
    event(
      sequence,
      "text",
      Map.merge(%{"session_id" => "s1", "text" => text, "kind" => "text"}, extra)
    )
  end

  test "the prompt, a tool call with its summary, and the result" do
    html =
      [
        event(1, "prompt_submitted", %{"prompt" => "/harness:hello"}),
        started(2, "a", %{"tool" => "Skill", "summary" => "harness:greet\nmore"}),
        result(3, "a", "Launching skill: harness:greet"),
        event(4, "tool_finished", %{"tool" => "Skill", "tool_use_id" => "a"}),
        event(5, "result", %{
          "outcome" => "success",
          "is_error" => false,
          "turns" => 6,
          "duration_ms" => 14_000,
          "cost_usd" => 0.09,
          "result" => "Hello, Dana"
        })
      ]
      |> items()
      |> html()

    assert texts(html, ".q-tr-prompt .q-tr-head") |> Enum.map(&squeeze/1) == ["/harness:hello"]

    assert texts(html, ".q-tr-tool .q-tr-head") |> Enum.map(&squeeze/1) == [
             "Skill(harness:greet)"
           ]

    assert texts(html, ".q-tr-tool .q-tr-ln") |> Enum.map(&squeeze/1) == [
             "Launching skill: harness:greet"
           ]

    assert texts(html, ".q-tr-result .q-tr-head") == ["success · 6 turns · 14 s · $0.09"]
    refute html =~ "Hello, Dana"
  end

  test "a result shows 3 lines, then a button for the rest; opened, all and Show less" do
    events = [started(1, "a"), result(2, "a", "1\n2\n3\n4\n5\n")]

    folded = events |> items() |> html()
    assert texts(folded, ".q-tr-ln") == ["1", "2", "3"]
    assert texts(folded, ".q-tr-fold") |> Enum.map(&squeeze/1) == ["… 2 more lines"]

    assert folded |> query("[phx-click=transcript_open]") |> LazyHTML.attribute("phx-value-seq") ==
             ["1"]

    opened = events |> items([1]) |> html()
    assert texts(opened, ".q-tr-ln") == ["1", "2", "3", "4", "5"]
    assert texts(opened, ".q-tr-fold") |> Enum.map(&squeeze/1) == ["Show less"]

    one_more = [started(1, "a"), result(2, "a", "1\n2\n3\n4")] |> items() |> html()
    assert texts(one_more, ".q-tr-fold") |> Enum.map(&squeeze/1) == ["… 1 more line"]
  end

  test "a call with no result has no line under it, and no error" do
    html =
      [started(1, "a"), event(2, "tool_finished", %{"tool" => "Bash", "tool_use_id" => "a"})]
      |> items()
      |> html()

    assert query(html, ".q-tr-out") |> Enum.count() == 0
    refute html =~ "q-tr-bad"
  end

  test "a denial shows its reason, or Not run: denied without one" do
    denied = fn extra ->
      [
        started(1, "a"),
        event(2, "tool_denied", Map.merge(%{"tool" => "Bash", "tool_use_id" => "a"}, extra))
      ]
      |> items()
      |> html()
    end

    # One line: the mark and the reason, with no break or space around the reason.
    reason = denied.(%{"message" => "Quoted text can't be checked"})
    assert texts(reason, ".q-tr-warn .q-tr-ln") == ["Denied: Quoted text can't be checked"]
    assert texts(reason, ".q-tr-warn .q-tr-hook") == ["⎿"]

    assert texts(denied.(%{}), ".q-tr-warn .q-tr-ln") |> Enum.map(&squeeze/1) == [
             "Not run: denied"
           ]
  end

  test "a failed call shows its error in the failure colour" do
    html =
      [
        started(1, "a"),
        event(2, "tool_failed", %{
          "tool" => "Bash",
          "tool_use_id" => "a",
          "error" => "Exit code 1"
        })
      ]
      |> items()
      |> html()

    assert texts(html, ".q-tr-bad .q-tr-ln") == ["Exit code 1"]
  end

  test "a text is Markdown with its line breaks kept, and no HTML of the text" do
    html =
      [text(1, "## Hello\nfirst line\nsecond line <script>alert(1)</script>")]
      |> items()
      |> html()

    md = query(html, ".q-tr-md")
    assert md |> LazyHTML.query("h2, h3, h4") |> Enum.count() == 1
    assert md |> LazyHTML.query("br") |> Enum.count() == 1
    assert md |> LazyHTML.query("script") |> Enum.count() == 0
  end

  test "thinking with text is folded under Thinking" do
    html = [text(1, "Weighing it", %{"kind" => "thinking"})] |> items() |> html()
    assert texts(html, ".q-tr-think summary .q-tr-head") == ["Thinking"]
    assert html =~ "Weighing it"
  end

  test "a text or result cut at 64 KiB says so" do
    html =
      [
        text(1, "long", %{"truncated" => true}),
        started(2, "a"),
        result(3, "a", "big", %{"truncated" => true})
      ]
      |> items()
      |> html()

    assert texts(html, ".q-tr-cut") == List.duplicate("Cut at 64 KiB. Raw has every byte.", 2)
  end

  test "a subagent's lines are indented, by agent_id alone" do
    html =
      [
        started(1, "t", %{"tool" => "Agent", "summary" => "Explore the shop"}),
        text(2, "Reading", %{"agent_id" => "a1"})
      ]
      |> items()
      |> html()

    assert query(html, ".q-tr-sub") |> Enum.count() == 1
    assert texts(html, ".q-tr-sub .q-tr-md") |> Enum.map(&squeeze/1) == ["Reading"]
  end

  test "a user's text, such as a subagent's prompt, is a prompt line indented with its agent" do
    html =
      [
        started(1, "t", %{"tool" => "Task", "summary" => "Look around"}),
        text(2, "Report the kernel release", %{"agent_id" => "a1", "role" => "user"})
      ]
      |> lines()
      |> html()

    assert texts(html, ".q-tr-prompt.q-tr-sub .q-tr-head") == ["Report the kernel release"]
    assert texts(html, ".q-tr-prompt .q-tr-mark") == ["❯"]
    assert query(html, ".q-tr-text") |> Enum.count() == 0
  end

  test "a result after another agent's lines is drawn after them, at its call's indent" do
    agent = %{"agent_id" => "a1"}

    html =
      [
        started(1, "t", %{"tool" => "Task", "summary" => "Look around"}),
        event(2, "subagent_started", Map.put(agent, "agent_type", "Explore")),
        text(3, "Report the kernel release", Map.put(agent, "role", "user")),
        started(4, "b", Map.put(agent, "summary", "uname -r")),
        result(5, "b", "7.0.0", agent),
        text(6, "Linux 7.0.0", agent),
        event(7, "subagent_finished", agent),
        result(8, "t", "Linux 7.0.0, from the subagent"),
        event(9, "tool_finished", %{"tool" => "Task", "tool_use_id" => "t"})
      ]
      |> lines()
      |> html()

    assert query(html, "li") |> LazyHTML.attribute("id") == ["e-1", "e-3", "e-4", "e-6", "e-8"]
    assert query(html, "#e-1 .q-tr-out") |> Enum.count() == 0
    assert texts(html, "#e-4 .q-tr-ln") == ["7.0.0"]
    assert texts(html, "#e-8 .q-tr-ln") == ["Linux 7.0.0, from the subagent"]
    assert query(html, "#e-8.q-tr-sub") |> Enum.count() == 0
    assert query(html, ~s(#e-8[data-part="result"] .q-tr-hook)) |> Enum.count() == 1
  end

  test "calls of one agent keep their results under them, whatever the order" do
    html =
      [started(1, "a"), started(2, "b"), result(3, "a", "A"), result(4, "b", "B")]
      |> lines()
      |> html()

    assert query(html, "li") |> LazyHTML.attribute("id") == ["e-1", "e-2"]
    assert texts(html, "#e-1 .q-tr-ln") == ["A"]
    assert texts(html, "#e-2 .q-tr-ln") == ["B"]
  end

  test "a line read from the output links to it in Raw, while Raw has the log" do
    events = [text(1, "Hello", %{"line" => 7, "session" => 1}), text(2, "No line")]

    html = events |> items() |> html()
    link = query(html, ".q-tr-raw")
    assert LazyHTML.attribute(link, "aria-label") == ["Show line 7 in Raw"]
    assert LazyHTML.attribute(link, "data-raw-line") == ["7"]
    assert LazyHTML.attribute(link, "data-session") == ["1"]

    assert events |> items() |> html(raw: false) |> query(".q-tr-raw") |> Enum.count() == 0
  end

  test "a run recorded before the text events: turn ends in their place, a response folded" do
    events = [
      started(1, "a", %{"tool" => "Read"}),
      event(2, "tool_finished", %{
        "tool" => "Read",
        "tool_use_id" => "a",
        "response" => %{"type" => "text", "lines" => 3}
      }),
      event(3, "turn_finished", %{"message" => "Done, Dana"})
    ]

    all = items(events)
    index_texts = 0
    shown = Enum.filter(all, &TranscriptComponents.transcript?(&1, index_texts))
    assert Enum.map(shown, & &1.kind) == [:tool, :turn_finished]

    html = html(shown)
    assert html =~ "Done, Dana"
    assert texts(html, ".q-tr-ln") == []
    assert [button] = texts(html, ".q-tr-fold")
    assert squeeze(button) =~ ~r/^… \d+ more lines$/

    opened = shown |> Enum.map(&Map.put(&1, :open, &1.kind == :tool)) |> html()
    assert texts(opened, ".q-tr-ln") |> Enum.join("\n") =~ ~s("lines": 3)
  end

  test "a turn's end is a line only in a run with no texts" do
    assert TranscriptComponents.transcript?(%{kind: :turn_finished}, 0)
    refute TranscriptComponents.transcript?(%{kind: :turn_finished}, 2)
    assert TranscriptComponents.transcript?(%{kind: :text}, 2)
    refute TranscriptComponents.transcript?(%{kind: :connection}, 0)
  end

  test "with neither texts nor turn ends, the result shows its text" do
    html =
      [event(1, "result", %{"outcome" => "success", "is_error" => false, "result" => "Hi, Dana"})]
      |> items()
      |> html(results: false)

    assert html =~ "Hi, Dana"
  end

  # Three subagents at once: two Explore that finished, after 51 s and 38 s, and a
  # general-purpose one that runs. Their calls and results arrive interleaved.
  defp three_at_once do
    a1 = %{"agent_id" => "a1", "agent_type" => "Explore"}
    a2 = %{"agent_id" => "a2", "agent_type" => "Explore"}
    a3 = %{"agent_id" => "a3", "agent_type" => "general-purpose"}

    [
      event(1, "prompt_submitted", %{"prompt" => "Explore work item #41"}),
      started(2, "t1", %{"tool" => "Task", "summary" => "Find where the PDF sets the currency"}),
      started(3, "t2", %{"tool" => "Task", "summary" => "Check how orders store the currency"}),
      started(4, "t3", %{"tool" => "Task", "summary" => "Run the invoice tests"}),
      event(5, "subagent_started", a1),
      event(6, "subagent_started", a2),
      event(7, "subagent_started", a3),
      text(8, "Install the dependencies and run the invoice tests.", Map.put(a3, "role", "user")),
      started(9, "g1", Map.merge(a1, %{"tool" => "Grep", "summary" => "currency"})),
      started(10, "r1", Map.merge(a2, %{"tool" => "Read", "summary" => "src/orders/model.ts"})),
      started(11, "b1", Map.merge(a3, %{"tool" => "Bash", "summary" => "npm ci"})),
      result(12, "g1", "src/invoices/pdf/template.ts", a1),
      started(13, "r2", Map.merge(a1, %{"tool" => "Read", "summary" => "template.ts"})),
      result(14, "b1", "added 1184 packages", a3),
      started(15, "g2", Map.merge(a2, %{"tool" => "Grep", "summary" => "10482"})),
      started(16, "r3", Map.merge(a1, %{"tool" => "Read", "summary" => "format.ts"})),
      event(17, "subagent_finished", Map.put(a2, "message", "Orders store an ISO code."))
      |> at(38),
      event(
        18,
        "subagent_finished",
        Map.put(a1, "message", "The PDF falls back to EUR.\nSee template.ts:88.")
      )
      |> at(51),
      started(19, "b2", Map.merge(a3, %{"tool" => "Bash", "summary" => "npm test -- invoices"}))
    ]
  end

  defp ids(html), do: html |> query("li") |> LazyHTML.attribute("id")

  test "a subagent is finished, running, or ended without a recorded finish" do
    index = three_at_once() |> light() |> Timeline.index(alive: true)
    subagents = TranscriptComponents.subagents(index.items, true)

    assert subagents |> Map.values() |> Enum.sort_by(& &1.seq) == [
             %{seq: 5, type: "Explore", calls: 3, finished_seq: 18, state: :finished},
             %{seq: 6, type: "Explore", calls: 2, finished_seq: 17, state: :finished},
             %{seq: 7, type: "general-purpose", calls: 2, finished_seq: nil, state: :running}
           ]

    # The record stopped without the finish: the subagent is neither running nor finished.
    assert TranscriptComponents.subagents(index.items, false)
           |> Map.values()
           |> Enum.map(& &1.state)
           |> Enum.sort() == [:ended, :finished, :finished]

    ended =
      (three_at_once() ++ [event(20, "ended", %{"reason" => "other"})])
      |> light()
      |> Timeline.index(alive: true)

    assert ended.items
           |> TranscriptComponents.subagents(true)
           |> Enum.find_value(fn {_lane, sub} -> sub.seq == 7 && sub.state end) == :ended
  end

  test "a running subagent's lines are grouped under it; a finished one is one line" do
    html = three_at_once() |> grouped() |> html()

    # The two finished groups are closed; the running one has its lines, in order, under it,
    # and npm ci's result is under its call again.
    assert ids(html) == ["e-1", "e-2", "e-3", "e-4", "e-5", "e-6", "e-7", "e-8", "e-11", "e-19"]
    assert texts(html, "#e-11 .q-tr-ln") == ["added 1184 packages"]
    assert query(html, ~s(li[data-group="7"].q-tr-sub.q-tr-in)) |> Enum.count() == 3
    assert query(html, "#e-5.q-tr-sub, #e-5.q-tr-in") |> Enum.count() == 0

    assert texts(html, "#e-5 .q-tr-head") |> Enum.map(&squeeze/1) == [
             "Explore · finished in 51 s · 3 calls"
           ]

    assert texts(html, "#e-5 .q-tr-ln") == ["The PDF falls back to EUR.", "See template.ts:88."]
    assert texts(html, "#e-5 .q-tr-fold") |> Enum.map(&squeeze/1) == ["Show 3 calls"]
    assert html |> query("#e-5 .q-tr-caret") |> LazyHTML.attribute("aria-expanded") == ["false"]
    assert texts(html, "#e-5 .q-tr-caret") |> Enum.map(&squeeze/1) == ["▸"]

    assert texts(html, "#e-6 .q-tr-head") |> Enum.map(&squeeze/1) == [
             "Explore · finished in 38 s · 2 calls"
           ]

    assert texts(html, "#e-6 .q-tr-fold") |> Enum.map(&squeeze/1) == ["Show 2 calls"]

    assert texts(html, "#e-7 .q-tr-head") |> Enum.map(&squeeze/1) == [
             "general-purpose · running · 2 calls so far"
           ]

    assert texts(html, "#e-7 .q-tr-fold") |> Enum.map(&squeeze/1) == ["Hide 2 calls"]
    assert html |> query("#e-7 .q-tr-caret") |> LazyHTML.attribute("aria-expanded") == ["true"]
    assert texts(html, "#e-7 .q-tr-caret") |> Enum.map(&squeeze/1) == ["▾"]
    assert query(html, "#e-7 .q-tr-ln") |> Enum.count() == 0

    assert html |> query("[phx-click=subagent_toggle]") |> LazyHTML.attribute("phx-value-seq") ==
             ~w(5 5 6 6 7 7)
  end

  test "the reader's choice opens a finished subagent and closes a running one" do
    html = three_at_once() |> grouped(choices: %{5 => true, 7 => false}) |> html()

    assert ids(html) == ["e-1", "e-2", "e-3", "e-4", "e-5", "e-9", "e-13", "e-16", "e-6", "e-7"]
    assert texts(html, "#e-9 .q-tr-ln") == ["src/invoices/pdf/template.ts"]
    assert texts(html, "#e-5 .q-tr-fold") |> Enum.map(&squeeze/1) == ["Hide 3 calls"]
    assert texts(html, "#e-7 .q-tr-fold") |> Enum.map(&squeeze/1) == ["Show 2 calls"]

    # A group with the line `?seq=` points at opens, unless the reader closed it.
    assert three_at_once() |> grouped(focused: 15) |> html() |> ids() |> Enum.member?("e-15")

    refute three_at_once()
           |> grouped(focused: 15, choices: %{6 => false})
           |> html()
           |> ids()
           |> Enum.member?("e-15")
  end

  test "a subagent whose finish the record lacks keeps its lines open, with no state" do
    html = three_at_once() |> grouped(alive: false) |> html()

    assert texts(html, "#e-7 .q-tr-head") |> Enum.map(&squeeze/1) == ["general-purpose · 2 calls"]
    assert texts(html, "#e-7 .q-tr-fold") |> Enum.map(&squeeze/1) == ["Hide 2 calls"]
    assert "e-19" in ids(html)
  end

  test "a subagent's start or finish without an agent id hides no line of the main agent" do
    explore = %{"agent_type" => "Explore"}

    events = [
      started(1, "a"),
      event(2, "subagent_started", explore),
      started(3, "b", %{"tool" => "Read"}),
      text(4, "Read it."),
      event(5, "subagent_finished", Map.put(explore, "message", "Done.")),
      text(6, "After the finish.")
    ]

    index = events |> light() |> Timeline.index(alive: true)
    assert TranscriptComponents.subagents(index.items, true) == %{}

    html = events |> grouped() |> html()
    assert ids(html) == ["e-1", "e-3", "e-4", "e-6"]
    assert query(html, "[phx-click=subagent_toggle]") |> Enum.count() == 0
  end

  test "an agent id started again while it runs keeps its first start, lines and count" do
    a1 = %{"agent_id" => "a1", "agent_type" => "Explore"}

    events = [
      started(1, "t1", %{"tool" => "Task"}),
      event(2, "subagent_started", a1),
      started(3, "g1", Map.merge(a1, %{"tool" => "Grep"})),
      event(4, "subagent_started", a1),
      started(5, "r1", Map.merge(a1, %{"tool" => "Read"}))
    ]

    html = events |> grouped() |> html()
    assert ids(html) == ["e-1", "e-2", "e-3", "e-5"]
    assert query(html, ~s(li[data-group="2"])) |> Enum.count() == 2

    assert texts(html, "#e-2 .q-tr-head") |> Enum.map(&squeeze/1) == [
             "Explore · running · 2 calls so far"
           ]
  end

  test "without subagents the lines are as they were, each at its sequence" do
    events = [started(1, "a"), text(2, "Reading", %{"agent_id" => "x"}), result(3, "a", "A")]
    index = events |> light() |> Timeline.index()
    plain = TranscriptComponents.lines(index.items, index.texts)

    assert TranscriptComponents.arrange(plain, %{}) ==
             Enum.map(plain, &Map.put(&1, :pos, {&1.seq, &1.seq}))
  end

  test "the bar counts the subagents and those that run, then Expand all and Collapse all" do
    html = render_component(&TranscriptComponents.subagents_bar/1, count: 3, running: 1)

    assert texts(html, ".q-tr-subs") |> Enum.map(&squeeze/1) == ["3 subagents, 1 running"]

    assert texts(html, "[phx-click=subagents_all]") |> Enum.map(&squeeze/1) == [
             "Expand all",
             "Collapse all"
           ]

    assert html |> query("[phx-click=subagents_all]") |> LazyHTML.attribute("phx-value-open") == [
             "true",
             "false"
           ]
  end
end
