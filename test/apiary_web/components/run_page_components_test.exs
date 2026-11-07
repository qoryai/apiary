defmodule ApiaryWeb.RunPageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Runs.Record.Overview
  alias Apiary.Runs.Record.Timeline
  alias ApiaryWeb.RunLive.Concealed
  alias ApiaryWeb.RunPageComponents
  alias ApiaryWeb.TranscriptComponents

  # A bidirectional override and a zero-width space, which a page drops, and a bell and an
  # escape, which it shows as U+FFFD.
  @rlo <<0x202E::utf8>>
  @zwsp <<0x200B::utf8>>
  @shown_control "\u{FFFD}"

  # Text that holds every kind of character a page cleans: "Fix" and "it" around them.
  defp dirty(text), do: text <> @rlo <> @zwsp <> "\a" <> "it\e"
  defp clean(text), do: text <> @shown_control <> "it" <> @shown_control

  @blanks [" ", @zwsp, @rlo <> @zwsp]

  defp run(about) do
    Map.merge(%{about_kind: nil, about_subjects: [], about_details: nil}, about)
  end

  defp header(about), do: render_component(&RunPageComponents.about_header/1, run: run(about))
  defp section(about), do: render_component(&RunPageComponents.about_section/1, run: run(about))

  defp query(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp texts(html, selector), do: html |> query(selector) |> Enum.map(&LazyHTML.text/1)

  defp attributes(html, selector, name),
    do: html |> query(selector) |> LazyHTML.attribute(name)

  defp refute_dirty(html) do
    refute html =~ @rlo
    refute html =~ @zwsp
    refute html =~ "\a"
    refute html =~ "\e"
  end

  describe "the header's line" do
    test "shows the kind cleaned, isolated in <bdi>" do
      html = header(%{about_kind: dirty("Fix")})

      assert texts(html, "#run-about-kind > bdi") == [clean("Fix")]
      refute_dirty(html)
    end

    test "leaves out a blank kind, and the line when nothing else is there" do
      for blank <- @blanks do
        assert header(%{about_kind: blank}) == ""

        html =
          header(%{about_kind: blank, about_subjects: [%{"type" => "ticket", "ref" => "T-1"}]})

        assert query(html, "#run-about") |> Enum.count() == 1
        assert query(html, "#run-about-kind") |> Enum.count() == 0
      end
    end

    test "shows a subject's type, ref and title cleaned, the title in its tooltip" do
      subject = %{
        "type" => dirty("ticket"),
        "ref" => dirty("T-1"),
        "title" => dirty("Fix"),
        "url" => "https://tracker.example.com/T-1"
      }

      html = header(%{about_subjects: [subject]})

      assert texts(html, "#run-about a bdi") == [clean("ticket"), clean("T-1")]

      assert attributes(html, "#run-about a", "title") == [
               clean("Fix") <> " · tracker.example.com"
             ]

      refute_dirty(html)
    end

    test "leaves a blank title out of a subject's tooltip" do
      for blank <- @blanks do
        with_url =
          header(%{
            about_subjects: [
              %{
                "type" => "ticket",
                "ref" => "T-1",
                "title" => blank,
                "url" => "https://tracker.example.com/T-1"
              }
            ]
          })

        assert attributes(with_url, "#run-about a", "title") == ["tracker.example.com"]

        no_url =
          header(%{about_subjects: [%{"type" => "ticket", "ref" => "T-1", "title" => blank}]})

        assert attributes(no_url, "#run-about span[title]", "title") == []
      end
    end
  end

  describe "the rail's About" do
    test "shows the kind and a subject's type, ref and title cleaned" do
      html =
        section(%{
          about_kind: dirty("Fix"),
          about_subjects: [
            %{"type" => dirty("ticket"), "ref" => dirty("T-1"), "title" => dirty("Fix")}
          ]
        })

      assert texts(html, "#run-about-facts dd:not(.q-rail-subj) > bdi") == [clean("Fix")]

      assert texts(html, ".q-rail-subj > span:first-child > bdi") == [
               clean("ticket"),
               clean("T-1")
             ]

      assert texts(html, ".q-rail-sub > bdi") == [clean("Fix")]
      assert attributes(html, ".q-rail-sub", "title") == [clean("Fix")]
      refute_dirty(html)
    end

    test "leaves out a blank kind and a blank title, and the section when nothing else is there" do
      for blank <- @blanks do
        assert section(%{about_kind: blank}) == ""

        html =
          section(%{
            about_kind: blank,
            about_subjects: [%{"type" => "ticket", "ref" => "T-1", "title" => blank}]
          })

        assert texts(html, "#run-about-facts dt") == ["Subjects"]
        assert query(html, ".q-rail-sub") |> Enum.count() == 0
      end
    end

    test "shows the details' keys and values cleaned, a value isolated in <bdi>" do
      html =
        section(%{
          about_details: %{
            dirty("key") => dirty("value"),
            "outer" => %{dirty("inner") => [dirty("item")]}
          }
        })

      assert texts(html, "#run-about-details dt") == [
               clean("key"),
               "outer." <> clean("inner")
             ]

      assert texts(html, "#run-about-details dd > bdi") == [
               clean("value"),
               # JSON writes a control character as an escape; the invisible ones are dropped
               ~S(["item\u0007it\u001B"])
             ]

      refute_dirty(html)
    end

    test "the details as rows have their keys and values cleaned" do
      assert RunPageComponents.about_details(%{dirty("key") => dirty("value")}) == [
               {clean("key"), clean("value"), :text}
             ]

      assert RunPageComponents.about_details(%{"k" => [@rlo <> "a" <> @zwsp]}) == [
               {"k", ~s(["a"]), :json}
             ]
    end
  end

  @t0 ~U[2026-10-09 12:00:00Z]

  # The built item of one event of `type` with `data`.
  defp built(type, data) do
    event = %{sequence: 1, type: type, time: @t0, data: data}
    kind = if type == "dev.qory.runtime.text", do: data["kind"]
    index = Timeline.index([%{sequence: 1, type: type, time: @t0, text_kind: kind}])
    [item] = Timeline.build(index.items, %{1 => Timeline.slim(event)})
    item
  end

  # The timeline's item of one event of `type` with `data`, as the run page draws it.
  defp item_html(type, data) do
    event = %{sequence: 1, type: type, time: @t0, data: data}
    index = Timeline.index([%{sequence: 1, type: type, time: @t0}])
    [item] = Timeline.build(index.items, %{1 => Timeline.slim(event)})

    render_component(&RunPageComponents.timeline_item/1,
      id: "e-1",
      item: item,
      started_at: @t0,
      seq_path: fn seq -> "/runs/r?seq=#{seq}" end
    )
  end

  # The run's start item of a `run.started` with `data`, then a `session.started` with
  # `session`, which gives the item its runtime.
  defp started_html(data, session) do
    events = [
      %{sequence: 1, type: "dev.qory.run.started", time: @t0, data: data},
      %{sequence: 2, type: "dev.qory.session.started", time: @t0, data: session}
    ]

    index = Timeline.index(Enum.map(events, &Map.delete(&1, :data)))
    [item] = Timeline.build(index.items, Map.new(events, &{&1.sequence, Timeline.slim(&1)}))

    render_component(&RunPageComponents.timeline_item/1,
      id: "e-1",
      item: item,
      started_at: @t0,
      seq_path: fn seq -> "/runs/r?seq=#{seq}" end
    )
  end

  describe "the timeline's items, texts the run's report sent" do
    test "a tool call: its tool and its summary's first line cleaned, isolated in <bdi>" do
      html =
        item_html("dev.qory.runtime.tool_started", %{
          "tool" => dirty("Bash"),
          "summary" => dirty("ls") <> "\nsecond line",
          "input" => %{"command" => "not shown"}
        })

      assert texts(html, ".q-k-mono > bdi") == [clean("Bash")]
      assert texts(html, ".q-s-mono > bdi") == [clean("ls")]
      refute_dirty(html |> query("summary") |> LazyHTML.to_html())

      blank = item_html("dev.qory.runtime.tool_started", %{"tool" => @zwsp})
      assert texts(blank, ".q-k-mono > bdi") == [@shown_control]
    end

    test "a tool call with no summary shows its tool alone, whatever its input" do
      html =
        item_html("dev.qory.runtime.tool_started", %{
          "tool" => "Grep",
          "input" => %{"pattern" => "TODO", "path" => "/work"}
        })

      assert texts(html, ".q-k-mono > bdi") == ["Grep"]
      assert texts(html, ".q-s-mono > bdi") == []
    end

    test "a denied tool call reads Not run: denied" do
      events = [
        %{
          sequence: 1,
          type: "dev.qory.runtime.tool_denied",
          time: @t0,
          data: %{"tool" => "Bash", "tool_use_id" => "a", "message" => "no"}
        }
      ]

      index = Timeline.index([%{sequence: 1, type: hd(events).type, time: @t0, tool_use_id: "a"}])
      [item] = Timeline.build(index.items, Map.new(events, &{&1.sequence, Timeline.slim(&1)}))

      html =
        render_component(&RunPageComponents.timeline_item/1,
          id: "e-1",
          item: item,
          started_at: @t0,
          seq_path: fn seq -> "/runs/r?seq=#{seq}" end
        )

      assert texts(html, ".q-no-end") == ["Not run: denied"]
    end

    test "a text: Text, its first line without Markdown marks, and a link to the Terminal" do
      text = "## " <> dirty("Hello") <> ", **Dana**\n\nThe second paragraph."

      html =
        render_component(&RunPageComponents.timeline_item/1,
          id: "e-1",
          item:
            built("dev.qory.runtime.text", %{"text" => text, "kind" => "text"})
            |> Map.put(:terminal_seq, 1),
          started_at: @t0,
          seq_path: fn seq -> "/runs/r?seq=#{seq}" end,
          terminal_path: fn seq -> "/runs/r/terminal?seq=#{seq}" end
        )

      assert texts(html, ".q-k") == ["Text"]
      assert texts(html, ".q-s-fit > bdi") == [clean("Hello") <> ", Dana"]
      refute html =~ "second paragraph"
      assert attributes(html, ".q-t .q-to-term", "href") == ["/runs/r/terminal?seq=1"]
      assert attributes(html, ".q-to-term", "aria-label") == ["Show this in the Terminal"]

      no_log = item_html("dev.qory.runtime.text", %{"text" => "Hello", "kind" => "text"})
      assert query(no_log, ".q-to-term") |> Enum.count() == 0
    end

    test "Turn finished and Result show no text" do
      html = item_html("dev.qory.runtime.turn_finished", %{"message" => "Hello, Dana"})
      refute html =~ "Hello, Dana"

      html =
        item_html("dev.qory.runtime.result", %{
          "outcome" => "success",
          "turns" => 6,
          "duration_ms" => 14_000,
          "cost_usd" => 0.09,
          "result" => "Hello, Dana"
        })

      refute html =~ "Hello, Dana"
      assert LazyHTML.text(query(html, ".q-s")) =~ "success · 6 turns · $0.09"
      assert texts(html, ".q-tct") |> Enum.map(&String.trim/1) == ["14 s"]
    end

    test "a session started: its model, source and directory cleaned" do
      html =
        item_html("dev.qory.runtime.started", %{
          "model" => dirty("opus"),
          "source" => dirty("startup"),
          "cwd" => dirty("/work")
        })

      assert texts(html, ".q-s bdi") == [clean("opus"), clean("startup"), clean("/work")]
      refute_dirty(html)

      blank = item_html("dev.qory.runtime.started", %{"model" => " ", "cwd" => @zwsp})
      assert texts(blank, ".q-s bdi") == [@shown_control, @shown_control]
    end

    test "what a prompt said: cleaned, on one line; one sent blank is marked" do
      html =
        item_html("dev.qory.runtime.prompt_submitted", %{
          "prompt" => "Fix the build\n\t" <> dirty("now")
        })

      assert texts(html, ".q-s > bdi") == ["Fix the build " <> clean("now")]
      refute_dirty(html)

      for blank <- @blanks do
        html = item_html("dev.qory.runtime.prompt_submitted", %{"prompt" => blank})
        assert [shown] = texts(html, ".q-s > bdi")
        assert shown =~ @shown_control
      end
    end

    test "a notification, a failed turn and a result's outcome: cleaned" do
      html =
        item_html("dev.qory.runtime.notification", %{
          "kind" => dirty("idle"),
          "message" => dirty("waiting")
        })

      assert texts(html, ".q-s") |> Enum.map(&String.trim/1) == [
               clean("idle") <> " · " <> clean("waiting")
             ]

      html =
        item_html("dev.qory.runtime.turn_failed", %{
          "error" => dirty("rate_limit"),
          "message" => " "
        })

      assert texts(html, ".q-s") |> Enum.map(&String.trim/1) == [
               clean("rate_limit") <> " · " <> @shown_control
             ]

      html = item_html("dev.qory.runtime.result", %{"outcome" => dirty("error")})
      assert LazyHTML.text(query(html, ".q-s")) =~ clean("error")

      for html <- [html] do
        refute_dirty(html)
      end
    end

    test "a subagent's id: cleaned, isolated in <bdi>" do
      html =
        item_html("dev.qory.runtime.subagent_started", %{
          "agent_id" => dirty("agent-1"),
          "agent_type" => "Explore"
        })

      assert texts(html, ".q-s > bdi") == [clean("agent-1")]
      refute_dirty(html)
    end

    test "a run started: its runtime, version, host and wall cleaned; a host sent blank marked" do
      html =
        started_html(
          %{"host" => dirty("dev-box"), "wall" => dirty("docker")},
          %{"runtime" => dirty("claude"), "runtime_version" => dirty("2.1")}
        )

      said = LazyHTML.text(query(html, ".q-s"))

      for part <- ["claude", "2.1", "dev-box", "docker"],
          do: assert(said =~ clean(part), part)

      refute_dirty(html)

      blank = started_html(%{"host" => @zwsp}, %{"runtime" => "claude"})
      assert LazyHTML.text(query(blank, ".q-s")) =~ "on #{@shown_control}"
      refute LazyHTML.text(query(blank, ".q-s")) =~ "n/a"
    end

    test "a policy applied: its mode, tools, argument, hosts and terminated hosts cleaned" do
      html =
        item_html("dev.qory.run.policy_applied", %{
          "mode" => dirty("enforce"),
          "allow" => ["api.example"],
          "deny" => [],
          "source" => "config",
          "tools" => [
            %{
              "name" => dirty("files"),
              "argument" => dirty("acme"),
              "hosts" => [dirty("f.example")]
            }
          ],
          "terminated" => [dirty("t.example")]
        })

      assert LazyHTML.text(query(html, ".q-s")) =~ clean("enforce")
      assert texts(html, "#e-1-tools .font-mono > bdi") == [clean("files")]
      assert texts(html, "#e-1-tools code.q-rule > bdi") == [clean("acme")]
      assert attributes(html, "#e-1-tools code.q-rule", "title") == [clean("acme")]
      assert LazyHTML.text(query(html, "#e-1-tools")) =~ "(#{clean("f.example")})"
      assert LazyHTML.text(query(html, ".q-s")) =~ clean("t.example")
      refute_dirty(html)
    end

    test "a tool's output: cleaned, its line breaks kept; one sent blank is marked" do
      html = tool_html(%{"response" => "ok\n\t" <> dirty("done")})

      assert texts(html, ".q-well pre") == ["ok\n\t" <> clean("done")]
      refute_dirty(html)

      for blank <- [" ", "  \n", @zwsp, @rlo <> @zwsp] do
        for response <- [blank, %{"stdout" => blank}] do
          html = tool_html(%{"response" => response})

          assert [shown] = texts(html, ".q-well pre")
          assert shown =~ @shown_control
          refute String.trim(shown) == ""
        end
      end
    end
  end

  # A tool call and its end, as the timeline folds them into one item.
  defp tool_html(finished) do
    events = [
      %{
        sequence: 1,
        type: "dev.qory.runtime.tool_started",
        time: @t0,
        data: %{"tool" => "Bash", "tool_use_id" => "a"}
      },
      %{
        sequence: 2,
        type: "dev.qory.runtime.tool_finished",
        time: @t0,
        data: Map.merge(%{"tool" => "Bash", "tool_use_id" => "a"}, finished)
      }
    ]

    light =
      for event <- events,
          do: %{
            sequence: event.sequence,
            type: event.type,
            time: event.time,
            tool_use_id: "a",
            tool: "Bash"
          }

    index = Timeline.index(light)
    [item] = Timeline.build(index.items, Map.new(events, &{&1.sequence, Timeline.slim(&1)}))

    render_component(&RunPageComponents.timeline_item/1,
      id: "e-1",
      item: item,
      started_at: @t0,
      seq_path: fn seq -> "/runs/r?seq=#{seq}" end
    )
  end

  describe "the timeline's group of connections" do
    # Two allowed connections to `host`, calls to `tool` where one is given, which the
    # timeline folds into one group.
    defp group_html(host, tool \\ nil, extra \\ %{}) do
      events =
        for seq <- [1, 2] do
          data = %{"host" => host, "port" => 443, "decision" => "allowed", "rule" => ""}
          data = if tool, do: Map.put(data, "tool", tool), else: data
          data = Map.merge(data, extra)
          %{sequence: seq, type: "dev.qory.run.egress", time: @t0, data: data}
        end

      slim = Enum.map(events, &Timeline.slim/1)
      index = Timeline.index(slim)
      [item] = Timeline.build(index.items, Map.new(slim, &{&1.sequence, &1}))
      assert item.kind == :connection_group

      render_component(&RunPageComponents.timeline_item/1,
        id: "e-1",
        item: item,
        started_at: @t0,
        seq_path: fn seq -> "/runs/r?seq=#{seq}" end
      )
    end

    test "names the host in its summary cleaned, isolated in <bdi>" do
      html = group_html(dirty("api.example.com"))

      assert texts(html, ".q-cx-sum .q-dest > bdi") == [clean("api.example.com")]
      refute_dirty(html |> query(".q-cx-sum") |> LazyHTML.to_html())
    end

    test "marks a host sent blank in its summary, never n/a" do
      for {blank, marked} <- [{" ", "\uFFFD"}, {@zwsp, "\uFFFD"}, {@rlo <> @zwsp, "\uFFFD\uFFFD"}] do
        assert texts(group_html(blank), ".q-cx-sum .q-dest > bdi") == [marked]
      end
    end

    test "names the tool in its summary cleaned" do
      html = group_html("api.example.com", dirty("files"))

      assert texts(html, ".q-cx-sum .q-dest-tool .q-tool-name") == [clean("files")]
      assert texts(html, ".q-cx-sum .q-dest-tool .q-on > bdi") == ["api.example.com"]
      assert LazyHTML.text(query(html, ".q-cx-sum")) =~ "2 allowed requests"
      refute_dirty(html |> query(".q-cx-sum") |> LazyHTML.to_html())
    end

    test "reads a blank tool as none: the summary leads with the host and counts connections" do
      none = group_html("api.example.com")

      for html <- [none | Enum.map(@blanks, &group_html("api.example.com", &1))] do
        assert query(html, ".q-cx-sum .q-dest-tool") |> Enum.count() == 0
        assert texts(html, ".q-cx-sum .q-dest > bdi") == ["api.example.com"]
        assert LazyHTML.text(query(html, ".q-cx-sum")) =~ "2 allowed connections"
      end
    end

    test "shows a group of requests to the run API with the instance's host, no port" do
      run_api = %{"port" => 80, "method" => "HTTP", "rule" => "wall:run-api"}
      instance = Apiary.Instance.host()

      html = group_html("run-api.qory.invalid", nil, run_api)
      assert texts(html, ".q-cx-sum .q-dest > bdi") == [instance]
      assert query(html, ".q-cx-sum .q-port") |> Enum.count() == 0

      tool = group_html("run-api.qory.invalid", "files", run_api)
      assert texts(tool, ".q-cx-sum .q-dest-tool .q-on") == [instance]

      # Another host keeps its port.
      other = group_html("api.example.com")
      assert texts(other, ".q-cx-sum .q-dest > .q-port") == [":443"]

      assert texts(group_html("api.example.com", "files"), ".q-cx-sum .q-on") ==
               ["api.example.com:443"]
    end
  end

  describe "the timeline's Session ended" do
    defp session_ended(data), do: item_html("dev.qory.runtime.ended", data)

    test "shows the reason cleaned, isolated in <bdi>" do
      html = session_ended(%{"reason" => dirty("logout")})

      assert texts(html, ".q-s > bdi") == [clean("logout")]
      refute_dirty(html)
    end

    test "reads a blank reason as none, as an item with no reason draws" do
      none = session_ended(%{})
      assert texts(none, ".q-s") |> Enum.map(&String.trim/1) == [""]

      for blank <- @blanks do
        html = session_ended(%{"reason" => blank})
        assert query(html, ".q-s > bdi") |> Enum.count() == 0
        assert texts(html, ".q-s") |> Enum.map(&String.trim/1) == [""]
      end
    end
  end

  describe "the timeline's Run ended" do
    defp run_ended(data), do: item_html("dev.qory.run.exited", data)

    test "shows the signal cleaned, isolated in <bdi>" do
      html = run_ended(%{"state" => "failed", "signal" => dirty("SIGTERM"), "exit_code" => 143})

      assert texts(html, ".q-s > bdi") == [clean("SIGTERM")]
      refute html =~ "exit 143"
      refute_dirty(html)
    end

    test "reads a blank signal as none: the exit code is said instead, or nothing" do
      for blank <- @blanks do
        html = run_ended(%{"state" => "failed", "signal" => blank, "exit_code" => 1})
        assert query(html, ".q-s > bdi") |> Enum.count() == 0
        assert texts(html, ".q-s") |> Enum.map(&String.trim/1) == ["exit 1"]

        html = run_ended(%{"state" => "failed", "signal" => blank, "duration_ms" => 3000})
        assert query(html, ".q-s > bdi") |> Enum.count() == 0
        refute LazyHTML.text(query(html, ".q-s")) =~ "·"
      end
    end
  end

  describe "the Timeline as an overview of the run" do
    defp at(seconds), do: DateTime.add(@t0, round(seconds * 1000), :millisecond)

    defp event(sequence, type, data),
      do: %{sequence: sequence, type: "dev.qory." <> type, time: at(sequence), data: data}

    defp call(sequence, phase, id, extra \\ %{}),
      do:
        event(
          sequence,
          "runtime.tool_" <> phase,
          Map.merge(%{"tool" => "Bash", "tool_use_id" => id}, extra)
        )

    defp egress(sequence),
      do:
        event(sequence, "run.egress", %{
          "host" => "registry.example",
          "port" => 443,
          "decision" => "allowed"
        })

    # The main agent's prompt; a call open at two connections, then one open at none,
    # which the Timeline leaves out; the main agent's text; the result; the run's end.
    defp overview_events do
      [
        event(1, "runtime.text", %{"text" => "Redesign the checkout", "role" => "user"}),
        call(2, "started", "a", %{"summary" => "npm install @northwind/ui-steps"}),
        egress(3),
        egress(4),
        call(5, "finished", "a", %{"duration_ms" => 9_500}),
        call(6, "started", "b", %{"summary" => "ls"}),
        call(7, "finished", "b", %{"duration_ms" => 300}),
        event(8, "runtime.text", %{"text" => "The checkout is done.\nEvery step has a test."}),
        event(9, "runtime.result", %{
          "outcome" => "success",
          "turns" => 31,
          "duration_ms" => 997_000,
          "cost_usd" => 6.42
        }),
        event(10, "run.exited", %{
          "state" => "completed",
          "exit_code" => 0,
          "duration_ms" => 1_000_000
        })
      ]
    end

    @versions [
      %{
        type: "proposal",
        name: "main",
        number: 2,
        at: ~U[2026-10-09 12:00:05.500Z],
        public_id: "v2"
      },
      %{
        type: "screenshot",
        name: nil,
        number: 1,
        at: ~U[2026-10-09 12:00:09.500Z],
        public_id: "v1"
      }
    ]

    # The Timeline's rows of `events`, each as the run page shows it, with the sequence of
    # its Terminal line.
    defp overview_rows(events \\ overview_events(), versions \\ @versions) do
      light =
        for %{data: data} = event <- events do
          %{
            sequence: event.sequence,
            type: event.type,
            time: event.time,
            tool_use_id: data["tool_use_id"],
            tool: if(event.type == "dev.qory.run.egress", do: data["tool"]),
            host: data["host"],
            port: data["port"] && to_string(data["port"]),
            decision: data["decision"],
            text_kind:
              if(event.type == "dev.qory.runtime.text",
                do: if(data["role"] == "user", do: "prompt", else: "text")
              )
          }
        end

      index = Timeline.index(light)
      built = Timeline.build(index.items, Map.new(events, &{&1.sequence, Timeline.slim(&1)}))

      line? = &TranscriptComponents.line?(&1, index.texts)

      for row <- Overview.list(index.items, versions: versions) do
        shown =
          if row.seq,
            do: Enum.find(built, &(&1.seq == row.seq)),
            else: Overview.build(row, built)

        Map.put(shown, :terminal_seq, Overview.terminal_seq(row, line?))
      end
    end

    defp row(rows, id), do: Enum.find(rows, &(&1.id == id))

    defp row_html(item, opts \\ []) do
      render_component(&RunPageComponents.timeline_item/1,
        id: item.id,
        item: item,
        started_at: @t0,
        seq_path: fn seq -> "/runs/r?seq=#{seq}" end,
        terminal_path: Keyword.get(opts, :terminal_path, &"/runs/r/terminal?seq=#{&1}")
      )
    end

    defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()
    # The Took cell of a row's head, not the hidden copy in the line laid over a summary.
    defp took(html),
      do: texts(html, ".q-hd:not(.q-tool-over) > .q-t > .q-tct") |> Enum.map(&String.trim/1)

    # A row's text without that line.
    defp shown_text(html),
      do: html |> texts(".q-b > :not(.q-tool-box), .q-tool-box > details") |> Enum.join(" ")

    test "Main session: its calls, the first line of its last text, Took, and the prompt's number" do
      html = row_html(row(overview_rows(), "main-session"))

      assert texts(html, ".q-k") == ["Main session"]
      assert texts(html, ".q-s-fit") == ["2 calls"]
      assert texts(html, ".q-s > bdi") == ["The checkout is done."]
      refute html =~ "Every step has a test."
      assert took(html) == ["16 m 37 s"]
      assert texts(html, ".q-q") == ["#0001"]
      assert query(html, ".q-n .hero-command-line-micro") |> Enum.count() == 1
      assert attributes(html, ".q-to-term", "href") == ["/runs/r/terminal?seq=8"]
    end

    test "a Pushed row: the artifact's type and name, the type alone without a name; no number, no link" do
      rows = overview_rows()

      for {id, words} <- [
            {"push-v2", "proposal/main version 2"},
            {"push-v1", "screenshot version 1"}
          ] do
        html = row_html(row(rows, id))

        assert texts(html, ".q-k") == ["Pushed"]
        assert texts(html, ".q-s > bdi") == [words]
        assert query(html, ".q-n .hero-arrow-up-tray-micro") |> Enum.count() == 1
        assert query(html, ".q-q") |> Enum.count() == 0
        assert texts(html, ".q-tc2") == [""]
        assert query(html, ".q-to-term") |> Enum.count() == 0
        assert took(html) == [""]
      end
    end

    test "Took: a call's, a result's and the run's duration, in the Took cell and not in the words" do
      rows = overview_rows()

      for {id, duration, words} <- [
            {"e-2", "9.5 s", "npm install @northwind/ui-steps"},
            {"e-9", "16 m 37 s", "success · 31 turns · $6.42"},
            {"e-10", "16 m 40 s", "exit 0"}
          ] do
        html = row_html(row(rows, id))

        assert took(html) == [duration]
        assert shown_text(html) =~ words

        assert length(String.split(shown_text(html), duration)) == 2,
               "#{id}: #{shown_text(html)}"
      end

      for id <- ~w(e-1 e-8), do: assert(took(row_html(row(rows, id))) == [""])
    end

    test "Took: a subagent's head and its finish, with no duration in their words" do
      head =
        built("dev.qory.runtime.subagent_started", %{
          "agent_id" => "a1",
          "agent_type" => "Explore"
        })
        |> Map.merge(%{
          duration_ms: 73_000,
          sub: %{
            type: "Explore",
            state: :finished,
            calls: 16,
            open: false,
            lines: 0,
            hidden_denied: []
          }
        })

      html = row_html(head)
      assert texts(html, ".q-s-fit") == ["16 calls"]
      refute text(html) =~ "finished in"
      assert took(html) == ["1 m 13 s"]

      # A finish's duration is the time from its start, which the run page reads.
      html =
        built("dev.qory.runtime.subagent_finished", %{
          "agent_id" => "a1",
          "agent_type" => "Explore"
        })
        |> Map.put(:duration_ms, 159_000)
        |> row_html()

      assert took(html) == ["2 m 39 s"]
      assert length(String.split(text(html), "2 m 39 s")) == 2
    end

    test "a call open at connections: only open call at a connection, or at that many" do
      html = row_html(row(overview_rows(), "e-2"))

      assert texts(html, ".q-only-open") |> Enum.map(&String.trim/1) == [
               "only open call at 2 connections"
             ]

      one = List.delete_at(overview_events(), 3)
      html = row_html(row(overview_rows(one), "e-2"))

      assert texts(html, ".q-only-open") |> Enum.map(&String.trim/1) == [
               "only open call at a connection"
             ]

      html = item_html("dev.qory.runtime.tool_started", %{"tool" => "Bash", "summary" => "ls"})
      assert query(html, ".q-only-open") |> Enum.count() == 0
    end

    test "the Terminal link: on each row with a Terminal line, none without one or without the log" do
      rows = overview_rows()

      for {id, seq} <- [{"e-1", 1}, {"main-session", 8}, {"e-2", 2}, {"e-8", 8}, {"e-9", 9}] do
        html = row_html(row(rows, id))
        assert attributes(html, ".q-t a.q-to-term", "href") == ["/runs/r/terminal?seq=#{seq}"], id
        assert attributes(html, "a.q-to-term", "aria-label") == ["Show this in the Terminal"]
      end

      for id <- ~w(push-v2 e-10) do
        assert query(row_html(row(rows, id)), ".q-to-term") |> Enum.count() == 0, id
      end

      for row <- rows do
        assert query(row_html(row, terminal_path: nil), ".q-to-term") |> Enum.count() == 0
      end
    end

    test "a call that opens has its Terminal link outside its summary, laid over the summary's place for it" do
      html = row_html(row(overview_rows(), "e-2"))

      # A link inside a summary would be a control inside a control.
      assert query(html, "summary a") |> Enum.count() == 0
      assert query(html, "summary .q-t .q-to-term-place[aria-hidden]") |> Enum.count() == 1

      assert attributes(html, ".q-tool-box > .q-tool-over .q-t a.q-to-term", "href") ==
               ["/runs/r/terminal?seq=2"]

      # The line over the summary has the cells after the link too, as the summary has
      # them, and no second permalink.
      assert texts(html, ".q-tool-over .q-tc1") == texts(html, "summary .q-tc1")
      assert texts(html, ".q-tool-over .q-tct") == texts(html, "summary .q-tct")
      assert query(html, "[data-permalink]") |> Enum.count() == 1
      assert query(html, "summary [data-permalink]") |> Enum.count() == 1

      # Without the log, no link and no place for one.
      html = row_html(row(overview_rows(), "e-2"), terminal_path: nil)
      assert query(html, ".q-to-term, .q-tool-over") |> Enum.count() == 0
    end

    test "the line over a summary has the summary's tool and state, hidden, so that the two wrap alike" do
      events = [
        event(1, "runtime.text", %{"text" => "Redesign the checkout", "role" => "user"}),
        call(2, "started", "a", %{"summary" => "npm test"}),
        call(3, "failed", "a")
      ]

      html = row_html(row(overview_rows(events, []), "e-2"))

      assert texts(html, "summary .q-k-mono > bdi") == ["Bash"]
      assert texts(html, "summary .q-bad") == ["Failed"]
      assert query(html, "summary .q-bad[aria-hidden]") |> Enum.count() == 0

      assert query(html, ".q-tool-over > .q-chev[aria-hidden=true]") |> Enum.count() == 1
      assert texts(html, ".q-tool-over > .q-k-mono[aria-hidden=true] > bdi") == ["Bash"]
      assert texts(html, ".q-tool-over > .q-t > .q-bad[aria-hidden=true]") == ["Failed"]

      # A screen reader reads each cell before the link in the summary alone. The summary's
      # words are on a line after the link, so the line over the summary has none.
      assert query(html, ".q-tool-over > :not(.q-t):not([aria-hidden=true])") |> Enum.count() ==
               0

      assert query(html, ".q-tool-over .q-s") |> Enum.count() == 0
      assert query(html, ".q-tool-over a, .q-tool-over [tabindex]") |> Enum.count() == 1
    end

    test "for a reader without the log, Main session shows its calls and Took, and no text" do
      main = Concealed.item(row(overview_rows(), "main-session"))
      html = row_html(main, terminal_path: nil)

      assert texts(html, ".q-k") == ["Main session"]
      assert texts(html, ".q-s-fit") == ["2 calls"]
      assert took(html) == ["16 m 37 s"]
      refute html =~ "The checkout is done."
      assert query(html, ".q-s > bdi") |> Enum.count() == 0
    end

    test "the legend over the rows: Since run start, Took, Event" do
      html =
        render_component(&RunPageComponents.timeline/1,
          id: "timeline",
          stream: [],
          rails: 1,
          started_at: @t0,
          seq_path: fn seq -> "/runs/r?seq=#{seq}" end,
          legend: true
        )

      assert texts(html, ".q-tlegend > span") == ["Since run start", "Took", "Event"]
    end
  end
end
