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
  defp items(events, open \\ []) do
    light =
      for %{data: data} = event <- events do
        %{
          sequence: event.sequence,
          type: event.type,
          time: event.time,
          tool_use_id: data["tool_use_id"],
          agent_id: data["agent_id"],
          agent_type: data["agent_type"],
          tool: data["tool"],
          text_kind:
            if(event.type == "dev.qory.runtime.text",
              do: if(data["text"] in [nil, ""], do: "empty", else: data["kind"])
            )
        }
      end

    index = Timeline.index(light)
    full = Timeline.full_limit()

    index.items
    |> Timeline.build(Map.new(events, &{&1.sequence, Timeline.slim(&1, full)}))
    |> Enum.map(&Map.put(&1, :open, &1.sequence in open))
  end

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

    assert texts(denied.(%{"message" => "Quoted text can't be checked"}), ".q-tr-warn .q-tr-ln")
           |> Enum.map(&squeeze/1) == ["Denied: Quoted text can't be checked"]

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
end
