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

    test "shows the details' keys and values cleaned, isolated in <bdi>" do
      html =
        section(%{
          about_details: %{
            dirty("key") => dirty("value"),
            "outer" => %{dirty("inner") => [dirty("item")]}
          }
        })

      assert texts(html, "#run-about-details dt > bdi") == [
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

  describe "the timeline's Run ended" do
    @t0 ~U[2026-10-09 12:00:00Z]

    defp run_ended(data) do
      type = "dev.qory.run.exited"
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
