defmodule ApiaryWeb.WorkItemComponentsTest do
  @moduledoc """
  The components of a work item's pages (`ApiaryWeb.WorkItemComponents`): the stage track,
  the gate's line, the details rail and the Thread's events and comments.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias ApiaryWeb.WorkItemComponents

  @at ~U[2026-10-15 09:30:00Z]

  defp doc(fun, assigns), do: fun |> render_component(assigns) |> LazyHTML.from_fragment()

  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp query(doc, selector), do: LazyHTML.query(doc, selector)

  describe "stage_track/1" do
    test "the five stages in order, numbered, the active one the current step" do
      doc = doc(&WorkItemComponents.stage_track/1, active: :explore)

      [list] = doc |> query("ol#work-item-stages") |> Enum.to_list()
      assert LazyHTML.attribute(list, "aria-label") == ["Stages"]

      assert doc |> query("li") |> Enum.map(&text/1) ==
               ["1 Explore", "2 Shape", "3 Build", "4 Verify", "5 Release"]

      current = query(doc, "li[aria-current]")
      assert LazyHTML.attribute(current, "id") == ["work-item-stages-explore"]
      assert LazyHTML.attribute(current, "aria-current") == ["step"]
      assert doc |> query("li.q-stage-on") |> Enum.count() == 1
      assert doc |> query("li.q-stage-on#work-item-stages-explore") |> Enum.count() == 1
    end

    test "only the stage given is active" do
      doc = doc(&WorkItemComponents.stage_track/1, active: :verify)

      assert doc |> query("li[aria-current]") |> LazyHTML.attribute("id") ==
               ["work-item-stages-verify"]

      assert doc |> query("li.q-stage-on") |> Enum.count() == 1
    end
  end

  test "gate_note/1 is one muted line, placed by the page's class" do
    doc = doc(&WorkItemComponents.gate_note/1, class: "q-place")

    [note] = doc |> query("p#work-item-gate-note") |> Enum.to_list()
    assert text(note) == "Explore's gate comes with the phase 2 pages."
    assert LazyHTML.attribute(note, "class") == ["q-gate-note q-place"]
  end

  describe "details/1" do
    defp details(assigns) do
      ticket = %{
        ref: "TCK-12",
        integration: "Tracker",
        url: "https://tracker.example.com/t/12",
        updated_at: @at
      }

      doc(
        &WorkItemComponents.details/1,
        Keyword.merge([runs: 3, alive: 1, ticket: ticket], assigns)
      )
    end

    test "the run page's rail, with its disclosure button first, closed" do
      doc = details(owner: "Ada Lovelace")

      [toggle] = doc |> query("button#work-item-details-toggle") |> Enum.to_list()
      assert LazyHTML.attribute(toggle, "class") == ["q-run-dtoggle"]
      assert LazyHTML.attribute(toggle, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(toggle, "aria-controls") == ["work-item-details"]
      assert text(toggle) == "Details"

      [rail] = doc |> query("aside#work-item-details") |> Enum.to_list()
      assert LazyHTML.attribute(rail, "class") == ["q-run-rail"]
      assert LazyHTML.attribute(rail, "aria-label") == ["Details"]
      assert doc |> query("aside .q-rail-sec dl.q-rail-kv") |> Enum.count() == 1

      assert doc |> query("dt") |> Enum.map(&text/1) == ["Owner", "Runs", "Ticket"]

      open = details(owner: nil, open: true)

      assert open |> query("#work-item-details-toggle") |> LazyHTML.attribute("aria-expanded") ==
               ["true"]
    end

    test "Owner: the owner's name, or n/a" do
      assert details(owner: "Ada Lovelace") |> query("#work-item-details-owner") |> text() ==
               "Ada Lovelace"

      assert details(owner: nil) |> query("#work-item-details-owner") |> text() == "n/a"
    end

    test "Runs: how many, and how many are alive" do
      assert details(runs: 1240, alive: 2) |> query("#work-item-details-runs") |> text() ==
               "1,240 · 2 alive"

      assert details(runs: 3, alive: 0) |> query("#work-item-details-runs") |> text() ==
               "3 · none alive"
    end

    test "Ticket: a link out to the ticket, and when it was updated" do
      ticket = details([]) |> query("#work-item-details-ticket")

      [link] = ticket |> query("a") |> Enum.to_list()
      assert LazyHTML.attribute(link, "href") == ["https://tracker.example.com/t/12"]
      assert LazyHTML.attribute(link, "target") == ["_blank"]
      assert link |> query(".q-ext-icon") |> Enum.count() == 1
      assert text(link) == "TCK-12 in Tracker (opens in a new tab)"

      [updated] = ticket |> query(".q-rail-sub") |> Enum.to_list()
      assert text(updated) =~ ~r/^updated \S/

      assert updated |> query("time") |> LazyHTML.attribute("datetime") == [
               DateTime.to_iso8601(@at)
             ]
    end

    test "Ticket: with no url, its words as text" do
      ticket = %{ref: "TCK-12", integration: "Tracker", url: nil, updated_at: @at}
      cell = details(ticket: ticket) |> query("#work-item-details-ticket")

      assert cell |> query("a") |> Enum.empty?()
      assert text(cell) =~ ~r/^TCK-12 in Tracker updated \S/
    end

    test "Ticket: n/a with no ticket" do
      assert details(ticket: nil) |> query("#work-item-details-ticket") |> text() == "n/a"
    end
  end

  describe "thread_event/1" do
    test "each kind of event in its words, with its time beside it" do
      for {kind, words} <- [
            taken_in: "Ada Lovelace took this in from TCK-12",
            closed: "Ada Lovelace closed this",
            undone: "Ada Lovelace undid the take in",
            ticket_closed: "Its ticket was closed in Tracker"
          ] do
        doc =
          doc(&WorkItemComponents.thread_event/1,
            id: "event-1",
            kind: kind,
            who: "Ada Lovelace",
            integration: "Tracker",
            ref: "TCK-12",
            at: @at
          )

        [event] = doc |> query("p#event-1") |> Enum.to_list()
        assert event |> query("span") |> text() == words

        assert event |> query("time") |> LazyHTML.attribute("datetime") == [
                 DateTime.to_iso8601(@at)
               ]
      end
    end

    test "a name is escaped" do
      html =
        render_component(&WorkItemComponents.thread_event/1,
          kind: :closed,
          who: "<b>x</b>",
          at: @at
        )

      assert html =~ "&lt;b&gt;x&lt;/b&gt; closed this"
    end
  end

  describe "comment/1" do
    defp comment(assigns) do
      doc(
        &WorkItemComponents.comment/1,
        Keyword.merge([id: "comment-7", who: "Ada Lovelace", at: @at], assigns)
      )
    end

    test "who wrote it and when, then the text as written, escaped, its line breaks kept" do
      body = "First line\n\n  <script>alert(1)</script>\nlast"

      html =
        render_component(&WorkItemComponents.comment/1,
          id: "comment-7",
          who: "Ada",
          at: @at,
          body: body
        )

      doc = LazyHTML.from_fragment(html)

      head = query(doc, "p#comment-7-head")
      assert text(head) =~ ~r/^Ada commented \S/
      assert head |> query("b") |> text() == "Ada"
      assert head |> query("time") |> LazyHTML.attribute("datetime") == [DateTime.to_iso8601(@at)]

      written = query(doc, "#comment-7-body")
      assert LazyHTML.text(written) == body
      assert [class] = LazyHTML.attribute(written, "class")
      assert "whitespace-pre-wrap" in String.split(class)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script"

      assert doc |> query("button") |> Enum.empty?()
    end

    test "the time follows the words in lower case, and a time beside an event does not" do
      today = DateTime.utc_now()
      yesterday = DateTime.new!(Date.add(DateTime.to_date(today), -1), ~T[17:20:00], "Etc/UTC")
      just_now = DateTime.add(today, -5, :second)

      assert comment(at: yesterday) |> query("#comment-7-head") |> text() ==
               "Ada Lovelace commented yesterday, 17:20"

      assert comment(at: just_now) |> query("#comment-7-head") |> text() ==
               "Ada Lovelace commented just now"

      assert comment(at: yesterday, deleted: true) |> query("#comment-7-deleted") |> text() ==
               "A comment by Ada Lovelace was deleted · yesterday, 17:20"

      ticket = %{ref: "TCK-12", integration: "Tracker", url: nil, updated_at: yesterday}

      assert details(ticket: ticket) |> query("#work-item-details-ticket .q-rail-sub") |> text() ==
               "updated yesterday, 17:20"

      event = doc(&WorkItemComponents.thread_event/1, kind: :closed, who: "Ada", at: yesterday)
      assert event |> query("time") |> text() == "Yesterday, 17:20"
    end

    test "a deleted comment is one muted line, with no text and no Delete" do
      doc = comment(deleted: true, body: "gone", can_delete: true)

      [line] = doc |> query("#comment-7-deleted") |> Enum.to_list()
      assert text(line) =~ ~r/^A comment by Ada Lovelace was deleted · \S/
      assert line |> query("time") |> Enum.count() == 1

      assert [class] = doc |> query("#comment-7") |> LazyHTML.attribute("class")
      assert String.split(class) == ["q-comment", "q-comment-deleted"]

      refute LazyHTML.text(doc) =~ "gone"
      assert doc |> query("#comment-7-head, #comment-7-body, button") |> Enum.empty?()
    end

    test "Delete, a link button that sends the page's event with the comment's id" do
      doc = comment(body: "x", can_delete: true, delete_event: "ask_delete", comment_id: 42)

      [delete] = doc |> query("button#comment-7-delete") |> Enum.to_list()
      assert text(delete) == "Delete"
      assert LazyHTML.attribute(delete, "type") == ["button"]
      assert LazyHTML.attribute(delete, "phx-click") == ["ask_delete"]
      assert LazyHTML.attribute(delete, "phx-value-id") == ["42"]
      assert LazyHTML.attribute(delete, "aria-describedby") == ["comment-7-head"]
      assert [class] = LazyHTML.attribute(delete, "class")
      refute "btn" in String.split(class)
    end

    test "the page's confirmation takes the place of Delete while it asks" do
      assigns = %{at: @at}

      html =
        rendered_to_string(~H"""
        <WorkItemComponents.comment
          id="comment-7"
          who="Ada"
          at={@at}
          body="x"
          can_delete
          delete_event="ask_delete"
          comment_id={42}
        >
          <:confirm>
            <div id="comment-7-confirm">asking</div>
          </:confirm>
        </WorkItemComponents.comment>
        """)

      doc = LazyHTML.from_fragment(html)
      assert doc |> query("#comment-7 #comment-7-confirm") |> Enum.count() == 1
      assert doc |> query("#comment-7-delete") |> Enum.empty?()
    end
  end

  describe "the generated documentation" do
    # Every instance serves the module reference at /docs, which leaves this module out.
    test "leaves ApiaryWeb.WorkItemComponents out" do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(WorkItemComponents)

      assert docs != []

      for {{kind, _name, _arity}, _anno, _signature, doc, _meta} <- docs,
          kind != :type,
          do: assert(doc == :hidden)
    end
  end
end
