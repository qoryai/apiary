defmodule ApiaryWeb.RunPageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Runs.Record.Timeline
  alias ApiaryWeb.RunPageComponents

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

  describe "the timeline's items, texts the run's report sent" do
    test "a tool call: its tool and its summary cleaned, isolated in <bdi>" do
      html =
        item_html("dev.qory.session.tool_started", %{
          "tool" => dirty("Bash"),
          "input" => %{"command" => dirty("ls")}
        })

      assert texts(html, ".q-k-mono > bdi") == [clean("Bash")]
      assert texts(html, ".q-s-mono > bdi") == [clean("ls")]
      refute_dirty(html |> query("summary") |> LazyHTML.to_html())
    end

    test "a tool call's pattern and path: each cleaned; one sent blank is marked" do
      html =
        item_html("dev.qory.session.tool_started", %{
          "tool" => "Grep",
          "input" => %{"pattern" => dirty("TODO"), "path" => " "}
        })

      assert texts(html, ".q-s-mono > bdi") == [clean("TODO"), @shown_control]
      assert texts(html, ".q-k-mono > bdi") == ["Grep"]

      blank = item_html("dev.qory.session.tool_started", %{"tool" => @zwsp})
      assert texts(blank, ".q-k-mono > bdi") == [@shown_control]
    end

    test "a session started: its model, source and directory cleaned" do
      html =
        item_html("dev.qory.session.started", %{
          "model" => dirty("opus"),
          "source" => dirty("startup"),
          "cwd" => dirty("/work")
        })

      assert texts(html, ".q-s bdi") == [clean("opus"), clean("startup"), clean("/work")]
      refute_dirty(html)

      blank = item_html("dev.qory.session.started", %{"model" => " ", "cwd" => @zwsp})
      assert texts(blank, ".q-s bdi") == [@shown_control, @shown_control]
    end

    test "what a prompt said: cleaned, its line breaks kept; one sent blank is marked" do
      html =
        item_html("dev.qory.session.prompt_submitted", %{
          "prompt" => "Fix the build\n\t" <> dirty("now")
        })

      assert texts(html, ".q-say") == ["Fix the build\n\t" <> clean("now")]
      refute_dirty(html)

      for blank <- @blanks do
        html = item_html("dev.qory.session.prompt_submitted", %{"prompt" => blank})
        assert html |> texts(".q-say") |> Enum.map(&String.trim/1) |> Enum.all?(&(&1 != ""))
        assert LazyHTML.text(query(html, ".q-say")) =~ @shown_control
      end
    end

    test "a notification, a failed turn and a result's outcome: cleaned" do
      html =
        item_html("dev.qory.session.notification", %{
          "kind" => dirty("idle"),
          "message" => dirty("waiting")
        })

      assert texts(html, ".q-s") |> Enum.map(&String.trim/1) == [
               clean("idle") <> " · " <> clean("waiting")
             ]

      html =
        item_html("dev.qory.session.turn_failed", %{
          "error" => dirty("rate_limit"),
          "message" => " "
        })

      assert texts(html, ".q-s") |> Enum.map(&String.trim/1) == [
               clean("rate_limit") <> " · " <> @shown_control
             ]

      html = item_html("dev.qory.session.result", %{"outcome" => dirty("error")})
      assert LazyHTML.text(query(html, ".q-s")) =~ clean("error")

      for html <- [html] do
        refute_dirty(html)
      end
    end

    test "a subagent's id: cleaned, isolated in <bdi>" do
      html =
        item_html("dev.qory.session.subagent_started", %{
          "agent_id" => dirty("agent-1"),
          "agent_type" => "Explore"
        })

      assert texts(html, ".q-s > bdi") == [clean("agent-1")]
      refute_dirty(html)
    end

    test "a run started: its runtime, version, host and wall cleaned; a host sent blank marked" do
      html =
        item_html("dev.qory.run.started", %{
          "runtime" => dirty("claude"),
          "runtime_version" => dirty("2.1"),
          "host" => dirty("dev-box"),
          "wall" => dirty("docker")
        })

      said = LazyHTML.text(query(html, ".q-s"))

      for part <- ["claude", "2.1", "dev-box", "docker"],
          do: assert(said =~ clean(part), part)

      refute_dirty(html)

      blank = item_html("dev.qory.run.started", %{"runtime" => "claude", "host" => @zwsp})
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
        type: "dev.qory.session.tool_started",
        time: @t0,
        data: %{"tool" => "Bash", "tool_use_id" => "a"}
      },
      %{
        sequence: 2,
        type: "dev.qory.session.tool_finished",
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
    defp group_html(host, tool \\ nil) do
      events =
        for seq <- [1, 2] do
          data = %{"host" => host, "port" => 443, "decision" => "allowed", "rule" => ""}
          data = if tool, do: Map.put(data, "tool", tool), else: data
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
  end

  describe "the timeline's Session ended" do
    defp session_ended(data), do: item_html("dev.qory.session.ended", data)

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
end
