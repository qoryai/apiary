defmodule ApiaryWeb.WorkItemComponentsTest do
  @moduledoc """
  A work item's page parts (`ApiaryWeb.WorkItemComponents`): the status in each state and
  its "you" form, the header, the stages, the step card and its questions, the notices
  with and without the integration, Details, the tabs, the Ticket tab, the Thread's
  events, a comment in each state, and the composer. Every DOM id, `phx-value-*` and path
  is Qory Apiary's, never the ticket's ref or its number at the source.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.WorkItemComponents

  @now ~U[2026-10-17 12:00:00Z]
  @url "https://example.com/acme/shop/issues/1204"

  @dana %{id: "pr_dana", name: "Dana", you: true}
  @priya %{id: "pr_priya", name: "Priya", you: false}
  @lea %{id: "pr_lea", name: "Lea", you: false}

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  defp work_item(overrides \\ %{}) do
    Map.merge(
      %{
        number: 88,
        title: "Checkout totals are a cent off when a discount applies",
        external_ref: "acme/shop#1204",
        url: @url,
        repository: "acme/shop",
        status: :confirm,
        owner: @dana,
        ended_by: nil,
        ended_at: nil,
        updated_at: ago(2 * 86_400),
        taken_in_by: @lea,
        taken_in_at: ~U[2026-10-14 11:24:00Z],
        first_instruction:
          "Check the rounding in the basket and in the order total; the tax line may round separately.",
        runs: %{
          latest: %{id: "01a97b20", path: "/8wonders/main/runs/01a97b20"},
          count: 1,
          running: 0
        },
        run: nil,
        confirmed_by: nil,
        confirmed_at: nil
      },
      overrides
    )
  end

  defp ticket(overrides \\ %{}) do
    Map.merge(
      %{
        filer: %{name: "Priya"},
        filed_at: ago(14 * 86_400),
        updated_at: ago(12 * 60),
        labels: ["bug", "checkout"],
        body: "Two items at €12.45 with the code `SAVE10`.",
        format: "markdown",
        comment_count: 6
      },
      overrides
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector)

  defp text(html, selector) do
    html
    |> query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp texts(html, selector),
    do: html |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp words(html), do: html |> doc() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

  describe "work_item_status/1" do
    for {status, owner, ended_by, words, mark} <- [
          {:queued, :dana, nil, "Explore is queued", "todo"},
          {:running, :dana, nil, "Qory is exploring", "run"},
          {:confirm, :dana, nil, "Waits for you to confirm", "wait"},
          {:confirm, :priya, nil, "Waits for Priya to confirm", "wait_other"},
          {:shape, :priya, nil, "Ready for Shape", "ready"},
          {:declined, :lea, :priya, "Declined by Priya", "declined"},
          {:declined, :lea, :dana, "Declined by you", "declined"},
          {:closed, :lea, :priya, "Closed by Priya", "closed"},
          {:closed, :lea, :dana, "Closed by you", "closed"},
          {:undone, :lea, :priya, "Undone by Priya", "closed"},
          {:undone, :lea, :dana, "Undone by you", "closed"}
        ] do
      test "#{status}, #{owner}, #{inspect(ended_by)}: #{words}" do
        people = %{dana: @dana, priya: @priya, lea: @lea}

        w =
          work_item(%{
            status: unquote(status),
            owner: people[unquote(owner)],
            ended_by: people[unquote(ended_by)]
          })

        html = render_component(&WorkItemComponents.work_item_status/1, work_item: w)
        assert text(html, ".q-wi-st") == unquote(words)
        assert attr(html, ".q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{unquote(mark)}"]
        assert attr(html, ".q-wi-mk", "aria-hidden") == ["true"]
      end
    end

    test "the reader's turn is the one strong status" do
      hot = render_component(&WorkItemComponents.work_item_status/1, work_item: work_item())
      assert count(hot, ".q-wi-hot") == 1

      for w <- [work_item(%{owner: @priya}), work_item(%{status: :shape})] do
        html = render_component(&WorkItemComponents.work_item_status/1, work_item: w)
        assert count(html, ".q-wi-hot") == 0
      end
    end
  end

  defp header(w, extra \\ []) do
    render_component(
      &WorkItemComponents.work_item_header/1,
      Keyword.merge(
        [
          work_item: w,
          integration: "GitHub",
          link: "https://apiary.example.com/8wonders/main/work/88",
          can_close: true
        ],
        extra
      )
    )
  end

  describe "work_item_header/1" do
    test "the title and number, the meta line, More with Copy link and Close work item…" do
      html = header(work_item())

      assert text(html, "h1") == "Checkout totals are a cent off when a discount applies#88"
      assert text(html, "h1 .q-wi-no") == "#88"
      assert text(html, ".q-wi-meta .q-wi-st") == "Waits for you to confirm"

      assert attr(html, "a.q-wi-ref", "href") == [@url]
      assert attr(html, "a.q-wi-ref", "title") == ["Open acme/shop#1204 on GitHub"]
      assert attr(html, "a.q-wi-ref", "target") == ["_blank"]
      assert text(html, "a.q-wi-ref") =~ "acme/shop#1204"
      assert text(html, "a.q-wi-ref") =~ "(opens in a new tab)"
      assert html =~ "You own it"

      assert attr(html, "#work-item-head-more-button", "aria-label") == [
               "More for work item #88"
             ]

      assert attr(html, "#work-item-head-more-button", "title") == ["More"]
      assert text(html, "#work-item-head-copy") == "Copy link"
      assert attr(html, "#work-item-head-copy", "phx-hook") == ["CopyToClipboard"]

      assert attr(html, "#work-item-head-copy", "data-copy") == [
               "https://apiary.example.com/8wonders/main/work/88"
             ]

      assert text(html, "#work-item-head-close") == "Close work item…"
      assert attr(html, "#work-item-head-close", "phx-click") == ["ask_close"]
      assert attr(html, "#work-item-head-close", "phx-value-number") == ["88"]
    end

    test "another's work item: whose it is; no Close without the right to" do
      html = header(work_item(%{owner: @priya}), can_close: false)
      assert html =~ "Priya owns it"
      assert text(html, ".q-wi-meta .q-wi-st") == "Waits for Priya to confirm"
      assert count(html, "#work-item-head-close") == 0
      assert count(html, "#work-item-head-copy") == 1
    end

    test "an ended work item has no More" do
      for status <- [:closed, :declined, :undone] do
        html = header(work_item(%{status: status, ended_by: @priya, ended_at: ago(60)}))
        assert count(html, "#work-item-head-more") == 0
      end
    end

    test "a ticket url that may not be a link is the ref as text, with its mark" do
      html = header(work_item(%{url: "http://example.com/acme/shop/issues/1204"}))
      assert count(html, "a.q-wi-ref") == 0
      assert text(html, "span.q-wi-ref") == "G acme/shop#1204"
      assert attr(html, "span.q-wi-ref .q-bl-tile", "aria-label") == ["GitHub"]
    end
  end

  defp track(w), do: render_component(&WorkItemComponents.stage_track/1, work_item: w)

  defp states(html) do
    for li <- query(html, "li.q-wi-stage") do
      [class] = LazyHTML.attribute(li, "class")
      class |> String.split() |> Enum.find(&(&1 =~ ~r/^q-wi-stage-(done|now|stop|todo)$/))
    end
  end

  describe "stage_track/1" do
    test "named Stages; the current stage is the current step" do
      html = track(work_item(%{status: :queued}))
      assert attr(html, "ol", "aria-label") == ["Stages"]
      assert text(html, "li.q-wi-stage") == "1 Explore 2 Confirm 3 Shape"
      assert attr(html, "[aria-current]", "id") == ["work-item-stages-explore"]
      assert attr(html, "[aria-current]", "aria-current") == ["step"]
      assert states(html) == ["q-wi-stage-now", "q-wi-stage-todo", "q-wi-stage-todo"]
      assert count(html, ".q-wi-end") == 0
    end

    test "at Confirm: Explore done, Confirm current and waiting" do
      html = track(work_item())
      assert attr(html, "[aria-current]", "id") == ["work-item-stages-confirm"]
      assert states(html) == ["q-wi-stage-done", "q-wi-stage-now", "q-wi-stage-todo"]
      assert count(html, ".q-wi-stage-wait") == 1
    end

    test "at Shape" do
      html = track(work_item(%{status: :shape}))
      assert attr(html, "[aria-current]", "id") == ["work-item-stages-shape"]
      assert states(html) == ["q-wi-stage-done", "q-wi-stage-done", "q-wi-stage-now"]
      assert count(html, ".q-wi-stage-wait") == 0
    end

    test "closed at Confirm: no current step, and the end mark Closed" do
      html = track(work_item(%{status: :closed, stage: :confirm, ended_by: @priya}))
      assert count(html, "[aria-current]") == 0
      assert states(html) == ["q-wi-stage-done", "q-wi-stage-todo", "q-wi-stage-todo"]
      assert text(html, ".q-wi-end") == "Closed"
    end

    test "declined at Confirm: Confirm stopped, no current step; the end mark Declined" do
      html = track(work_item(%{status: :declined, stage: :confirm, ended_by: @priya}))
      assert count(html, "[aria-current]") == 0
      assert states(html) == ["q-wi-stage-done", "q-wi-stage-stop", "q-wi-stage-todo"]
      assert text(html, ".q-wi-end") == "Declined"
    end

    test "undone: nothing done, no current step; the end mark Undone" do
      html = track(work_item(%{status: :undone, ended_by: @dana}))
      assert count(html, "[aria-current]") == 0
      assert states(html) == ["q-wi-stage-todo", "q-wi-stage-todo", "q-wi-stage-todo"]
      assert text(html, ".q-wi-end") == "Undone"
    end
  end

  defp card(w, extra \\ []) do
    render_component(
      &WorkItemComponents.step_card/1,
      Keyword.merge(
        [work_item: w, integration: "GitHub", can_undo: true, can_act: true, now: @now],
        extra
      )
    )
  end

  describe "step_card/1, Explore queued" do
    defp queued(by, taken_in_at),
      do:
        work_item(%{
          number: 341,
          status: :queued,
          taken_in_by: by,
          taken_in_at: taken_in_at,
          runs: nil
        })

    test "taken in by the reader: the bee, the Undo line and Undo" do
      html = card(queued(@dana, ago(5)))

      assert text(html, "h2") == "Explore"
      assert text(html, ".q-wi-badge") == "Queued"
      assert count(html, ".q-wi-bee-line .q-bl-bee") == 1

      assert text(html, ".q-wi-bee-line") ==
               "Qory reads the ticket and the code when the run starts, and proposes how to build it."

      assert text(html, "#work-item-step-undo-line") ==
               "You took this in just now. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays."

      assert text(html, "#work-item-step-undo button") == "Undo"
      assert attr(html, "#work-item-step-undo button", "phx-click") == ["undo"]
      assert attr(html, "#work-item-step-undo button", "phx-value-number") == ["341"]
    end

    test "taken in by another member" do
      html = card(queued(@priya, ago(20 * 60)))

      assert text(html, "#work-item-step-undo-line") ==
               "Priya took this in 20 minutes ago. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays."
    end

    test "after the uninstall: the reader's line says nothing changes on the ticket" do
      html = card(queued(@dana, ago(20 * 60)), uninstalled: true)

      assert text(html, ".q-wi-bee-line") ==
               "Qory reads the ticket and the code when the run starts, and proposes how to build it."

      assert text(html, "#work-item-step-undo-line") ==
               "You took this in 20 minutes ago. Until a run starts, you can undo this. GitHub is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment."
    end

    test "after the uninstall, another's take in: who and when, nothing changes, and Undo" do
      html = card(queued(@priya, ago(20 * 60)), uninstalled: true)

      assert text(html, "#work-item-step-undo-line") ==
               "Priya took this in 20 minutes ago. Until a run starts, you can undo this. GitHub is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment."

      assert text(html, "#work-item-step-undo button") == "Undo"
    end

    test "without the right to undo: who and when, no sentence on undoing, and no Undo" do
      for {by, uninstalled, line} <- [
            {@dana, false, "You took this in just now."},
            {@priya, false, "Priya took this in just now."},
            {@dana, true,
             "You took this in just now. GitHub is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment."},
            {@priya, true,
             "Priya took this in just now. GitHub is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment."}
          ] do
        html = card(queued(by, ago(5)), can_undo: false, uninstalled: uninstalled)
        assert text(html, "#work-item-step-undo-line") == line
        refute html =~ "undo this"
        assert count(html, "#work-item-step-undo button") == 0
      end
    end

    test "Undo follows the right to undo, apart from the right to confirm or decline" do
      html = card(queued(@dana, ago(5)), can_act: false)
      assert text(html, "#work-item-step-undo button") == "Undo"
    end
  end

  describe "step_card/1, Explore running" do
    test "a first run, and when it started; the run's id links its page" do
      run = %{id: "01a9e3c7", path: "/8wonders/main/runs/01a9e3c7", started_at: ago(6 * 60)}
      html = card(work_item(%{status: :running, run: run}))

      assert text(html, "h2") == "Explore"
      assert text(html, ".q-wi-badge") == "Running"

      assert text(html, ".q-wi-bee-line") ==
               "Qory is exploring. It reads the ticket and the code, and proposes how to build it."

      assert text(html, "#work-item-step-run") == "Run 01a9e3c7 started 6 minutes ago."
      assert attr(html, "#work-item-step-run a", "href") == ["/8wonders/main/runs/01a9e3c7"]
      assert count(html, "button") == 0
    end

    test "again, with a member's answers; a run without a page is its id" do
      run = %{id: "rn_01a9e3c7", path: nil, started_at: ago(6 * 60), answers_by: [@priya]}
      html = card(work_item(%{status: :running, run: run}))

      assert text(html, ".q-wi-bee-line") ==
               "Qory is exploring again, with Priya's answers. It reads the ticket and the code, and proposes how to build it."

      assert count(html, "#work-item-step-run a") == 0
      assert text(html, "#work-item-step-run .q-wi-run-id") == "rn_01a9e3c7"
    end
  end

  describe "step_card/1, Confirm" do
    test "the reader's: Waits for you, the line, Confirm and Decline" do
      html = card(work_item())

      assert text(html, "h2") == "Confirm"
      assert text(html, ".q-wi-badge") == "Waits for you"
      assert count(html, ".q-wi-step-ask") == 1

      assert text(html, ".q-wi-bee-line") ==
               "Qory proposed how to build it. Confirm it, change it first, or decline the work item."

      refute html =~ "Mock-up"
      assert text(html, "#work-item-step-confirm") == "Confirm"
      assert attr(html, "#work-item-step-confirm", "phx-click") == ["confirm"]
      assert attr(html, "#work-item-step-confirm", "phx-value-number") == ["88"]
      assert text(html, "#work-item-step-decline") == "Decline"
      assert attr(html, "#work-item-step-decline", "phx-click") == ["ask_decline"]
      assert attr(html, "#work-item-step-decline", "phx-value-number") == ["88"]
    end

    test "another member's: no badge, Confirm and Decline stay" do
      html = card(work_item(%{owner: @priya}))
      assert count(html, ".q-wi-badge") == 0
      assert count(html, ".q-wi-step-ask") == 0
      assert count(html, "#work-item-step-confirm") == 1
    end

    test "the Decline question, in place of the buttons" do
      html = card(work_item(), asking: :decline, cancel: "/8wonders/main/work/88")

      assert attr(html, "#work-item-step-decline", "role") == ["group"]
      assert text(html, "#work-item-step-decline-question") == "Decline work item #88?"

      assert text(html, "#work-item-step-decline-sub") ==
               "The ticket stays open on GitHub and keeps Qory's label, and nothing new is posted there. In the Backlog, Take in again brings this work item back."

      assert text(html, "#work-item-step-decline-go") == "Decline"
      assert attr(html, "#work-item-step-decline-go", "phx-click") == ["decline"]
      assert attr(html, "#work-item-step-decline-go", "phx-value-number") == ["88"]
      assert text(html, "#work-item-step-decline-cancel") == "Cancel"
      assert count(html, "#work-item-step-confirm") == 0
      refute html =~ "Qory proposed"
    end

    test "without the right to act: whose turn it is, no Confirm, no Decline, no question" do
      for asking <- [nil, :decline] do
        html = card(work_item(%{owner: @priya}), can_act: false, asking: asking)

        assert text(html, ".q-wi-bee-line") ==
                 "Waits for Priya to confirm Qory's proposal or decline the work item."

        assert count(html, ".q-wi-bee-line .q-bl-bee") == 1
        refute html =~ "Qory proposed how to build it"
        assert count(html, "button") == 0
        assert count(html, "[role=group]") == 0
        refute html =~ "Decline work item"
      end

      acts = card(work_item(%{owner: @priya}), can_act: true)

      assert text(acts, ".q-wi-bee-line") ==
               "Qory proposed how to build it. Confirm it, change it first, or decline the work item."

      assert count(acts, "#work-item-step-confirm") == 1
    end

    test "without the right to act: the reader as you, another owner by name, escaped" do
      mine = card(work_item(), can_act: false)

      assert text(mine, ".q-wi-bee-line") ==
               "Waits for you to confirm Qory's proposal or decline the work item."

      html =
        card(work_item(%{owner: %{id: "pr_x", name: "<b>Ana</b>", you: false}}), can_act: false)

      assert html =~ "Waits for &lt;b&gt;Ana&lt;/b&gt; to confirm"
      assert count(html, ".q-wi-bee-line b") == 0
    end

    test "without the right to act and without an owner: no line, and no buttons" do
      html = card(work_item(%{owner: nil}), can_act: false)
      assert text(html, "h2") == "Confirm"
      assert count(html, ".q-wi-bee-line") == 0
      assert count(html, "button") == 0
    end

    test "the Decline question after the uninstall" do
      html = card(work_item(), asking: :decline, uninstalled: true)

      assert text(html, "#work-item-step-decline-sub") ==
               "GitHub is no longer connected, so nothing changes on the ticket. The work item stays in Qory Apiary, declined."

      assert attr(html, "#work-item-step-decline-cancel", "phx-click") |> hd() =~
               "cancel_question"
    end
  end

  describe "step_card/1, Shape and ended" do
    test "Shape: who confirmed and when" do
      w =
        work_item(%{
          status: :shape,
          owner: %{name: "Mirek", you: false},
          confirmed_by: %{name: "Mirek", you: false},
          confirmed_at: ago(3 * 3600)
        })

      html = card(w)
      assert text(html, "h2") == "Shape"
      assert text(html, ".q-wi-badge") == "Ready"

      assert text(html, ".q-wi-step > p") ==
               "Mirek confirmed Qory's proposal 3 hours ago. Shape is the plan and its acceptance criteria."

      mine = card(work_item(%{status: :shape, confirmed_by: @dana, confirmed_at: ago(3 * 3600)}))

      assert text(mine, ".q-wi-step > p") ==
               "You confirmed Qory's proposal 3 hours ago. Shape is the plan and its acceptance criteria."
    end

    test "an ended work item has no card" do
      for status <- [:closed, :declined, :undone] do
        html = card(work_item(%{status: status, ended_by: @priya, ended_at: ago(60)}))
        assert String.trim(html) == ""
      end
    end
  end

  describe "the notices" do
    test "after the uninstall" do
      html =
        render_component(&WorkItemComponents.uninstalled_notice/1,
          integration: "GitHub",
          at: ~U[2026-10-17 11:58:00Z],
          now: @now
        )

      assert text(html, "p:first-of-type") ==
               "The GitHub installation ended on 17 Oct, when GitHub reported it gone."

      assert html =~
               "This work item stays in Qory Apiary. Qory no longer changes anything on the ticket, and the ticket is no longer in the Backlog."
    end

    test "the close question, and after the uninstall" do
      html =
        render_component(&WorkItemComponents.close_question/1,
          number: 88,
          integration: "GitHub"
        )

      assert text(html, "#work-item-close-question") == "Close work item #88?"

      assert text(html, "#work-item-close-sub") ==
               "Closing ends the work on it in Qory Apiary. The ticket stays open on GitHub and keeps Qory's label, and nothing new is posted there. In the Backlog, Take in again brings this work item back."

      assert text(html, "#work-item-close-go") == "Close work item"
      assert attr(html, "#work-item-close-go", "phx-click") == ["close"]
      assert attr(html, "#work-item-close-go", "phx-value-number") == ["88"]
      assert text(html, "#work-item-close-cancel") == "Cancel"

      gone =
        render_component(&WorkItemComponents.close_question/1,
          number: 88,
          integration: "GitHub",
          uninstalled: true
        )

      assert text(gone, "#work-item-close-sub") ==
               "Closing ends the work on it in Qory Apiary. GitHub is no longer connected, so nothing changes on the ticket."
    end

    defp ended(status, by, at, extra \\ []) do
      w =
        work_item(%{
          number: 64,
          status: status,
          stage: :confirm,
          ended_by: by,
          ended_at: at
        })

      render_component(
        &WorkItemComponents.end_notice/1,
        Keyword.merge(
          [
            work_item: w,
            integration: "GitHub",
            again_path: "/8wonders/main/backlog?ticket=tk_01j9z7",
            now: @now
          ],
          extra
        )
      )
    end

    test "closed: who and on which day, the ticket's state, and Take in again" do
      html = ended(:closed, %{name: "Mirek", you: false}, ~U[2026-10-12 10:07:00Z])

      assert text(html, "#work-item-ended-line") == "Mirek closed this work item on 12 Oct."

      assert words(html) =~
               "The ticket is still open on GitHub and keeps Qory's label. In the Backlog, Take in again brings this work item back."

      assert text(html, "#work-item-ended-again") == "Take in again"

      assert attr(html, "#work-item-ended-again", "href") == [
               "/8wonders/main/backlog?ticket=tk_01j9z7"
             ]

      mine = ended(:closed, @dana, ~U[2026-10-12 10:07:00Z])
      assert text(mine, "#work-item-ended-line") == "You closed this work item on 12 Oct."
    end

    test "declined" do
      html = ended(:declined, @priya, ago(3 * 3600))

      assert text(html, "#work-item-ended-line") ==
               "Priya declined this work item 3 hours ago, at Confirm."

      assert words(html) =~ "The ticket is still open on GitHub and keeps Qory's label."
      assert count(html, "#work-item-ended-again") == 1

      mine = ended(:declined, @dana, ago(3 * 3600))

      assert text(mine, "#work-item-ended-line") ==
               "You declined this work item 3 hours ago, at Confirm."
    end

    test "undone by the reader" do
      html = ended(:undone, @dana, ago(5))

      assert text(html, "#work-item-ended-line") ==
               "You undid this just now, before a run started."

      assert words(html) =~
               "Qory took its label off the ticket, and its comment stays there. In the Backlog, Take in again brings this work item back."

      assert count(html, "#work-item-ended-again") == 1
    end

    test "undone by another member: who and when, what it left, and Take in again" do
      html = ended(:undone, @priya, ago(5))

      assert text(html, "#work-item-ended-line") ==
               "Priya undid this just now, before a run started."

      assert words(html) =~
               "Qory took its label off the ticket, and its comment stays there. In the Backlog, Take in again brings this work item back."

      assert count(html, "#work-item-ended-again") == 1
    end

    test "after the uninstall: the first line alone, and no Take in again" do
      for {status, by, line} <- [
            {:closed, %{name: "Mirek", you: false}, "Mirek closed this work item on 12 Oct."},
            {:declined, @priya, "Priya declined this work item"},
            {:undone, @dana, "You undid this"},
            {:undone, @priya, "Priya undid this"}
          ] do
        html = ended(status, by, ~U[2026-10-12 10:07:00Z], uninstalled: true)
        assert text(html, "#work-item-ended-line") =~ line
        assert count(html, ".q-wi-grow > p") == 1
        assert count(html, "#work-item-ended-again") == 0
        refute html =~ "Take in again"
      end
    end

    test "a live work item has no end notice" do
      html =
        render_component(&WorkItemComponents.end_notice/1,
          work_item: work_item(),
          integration: "GitHub"
        )

      assert String.trim(html) == ""
    end
  end

  defp details(w, extra \\ []) do
    render_component(
      &WorkItemComponents.work_item_details/1,
      Keyword.merge([work_item: w, ticket: ticket(), integration: "GitHub", now: @now], extra)
    )
  end

  describe "work_item_details/1" do
    test "the facts, the reader the owner" do
      html = details(work_item())

      assert text(html, "#work-item-details-toggle .q-wi-dtoggle-t") == "Details"

      assert text(html, "#work-item-details-toggle .q-wi-dtoggle-s") ==
               "You own it · G acme/shop#1204"

      assert attr(html, "#work-item-details-toggle", "aria-expanded") == ["false"]
      assert attr(html, "#work-item-details-toggle", "aria-controls") == ["work-item-details"]
      assert text(html, "h2") == "Details"

      assert texts(html, "dt") ==
               ["Owner", "Ticket", "Repository", "Taken in", "First instruction", "Runs"]

      assert text(html, "#work-item-details-owner") == "D Dana (you)"
      assert text(html, "#work-item-details-ticket a") =~ "acme/shop#1204"
      assert attr(html, "#work-item-details-ticket a", "href") == [@url]

      assert text(html, "#work-item-details-ticket .q-wi-sub") ==
               "On GitHub · Priya filed it 3 Oct 2026"

      assert text(html, "#work-item-details-repository") == "acme/shop"
      assert text(html, "#work-item-details-taken-in") == "14 Oct, by Lea"
      assert text(html, "#work-item-details-instruction") =~ "Check the rounding in the basket"
      assert text(html, "#work-item-details-runs") == "01a97b20 · 1 run, ended"
      assert attr(html, "#work-item-details-runs a", "href") == ["/8wonders/main/runs/01a97b20"]
    end

    test "another owner; taken in by the reader; no instruction; runs, one running" do
      w =
        work_item(%{
          owner: @priya,
          taken_in_by: @dana,
          first_instruction: nil,
          runs: %{latest: %{id: "01a9e3c7", path: nil}, count: 2, running: 1}
        })

      html = details(w)
      assert text(html, "#work-item-details-owner") == "P Priya"
      refute html =~ "(you)"

      assert text(html, "#work-item-details-toggle .q-wi-dtoggle-s") ==
               "Priya owns it · G acme/shop#1204"

      assert text(html, "#work-item-details-taken-in") == "14 Oct, by you"
      assert text(html, "#work-item-details-instruction") == "None"
      assert text(html, "#work-item-details-runs") == "01a9e3c7 · 2 runs, 1 running"
    end

    test "Taken in and the end row are one line: the time and the words after it in one element" do
      w = work_item(%{status: :declined, ended_by: @dana, ended_at: ~U[2026-10-12 10:07:00Z]})
      html = details(w, work_item: %{w | taken_in_by: @dana})

      for {id, line} <- [
            {"#work-item-details-taken-in", "14 Oct, by you"},
            {"#work-item-details-ended", "12 Oct, by you"}
          ] do
        assert count(html, "#{id} > *") == 1, id
        assert count(html, "#{id} > span > time") == 1, id
        assert text(html, "#{id} > span") == line, id
        assert html |> query(id) |> LazyHTML.text() |> String.trim() == line, id
      end
    end

    test "an empty or blank first instruction is none" do
      for blank <- ["", "   ", "\n\t "] do
        html = details(work_item(%{first_instruction: blank}))
        assert text(html, "#work-item-details-instruction") == "None"
        assert count(html, "#work-item-details-instruction .q-wi-q") == 0
      end
    end

    test "no runs yet" do
      html = details(work_item(%{runs: nil}))
      assert text(html, "#work-item-details-runs") == "None yet"
    end

    test "after the uninstall" do
      html = details(work_item(), uninstalled: true)

      assert text(html, "#work-item-details-ticket .q-wi-sub") ==
               "On GitHub, no longer connected · Priya filed it 3 Oct 2026"
    end

    test "ended: how, when and by whom" do
      for {status, by, row} <- [
            {:closed, %{name: "Mirek", you: false}, "Closed 12 Oct, by Mirek"},
            {:declined, @priya, "Declined 12 Oct, by Priya"},
            {:undone, @dana, "Undone 12 Oct, by you"}
          ] do
        html =
          details(work_item(%{status: status, ended_by: by, ended_at: ~U[2026-10-12 10:07:00Z]}))

        [dt | _] = html |> query("dt") |> Enum.reverse()
        assert LazyHTML.text(dt) <> " " <> text(html, "#work-item-details-ended") == row
      end
    end
  end

  describe "work_item_tabs/1" do
    test "Ticket and Thread, named for the work item, with the comments' count" do
      html =
        render_component(&WorkItemComponents.work_item_tabs/1,
          number: 88,
          current: :thread,
          ticket_path: "/8wonders/main/work/88",
          thread_path: "/8wonders/main/work/88/thread",
          comment_count: 3
        )

      assert attr(html, "nav", "aria-label") == ["Work item #88"]
      assert text(html, "#work-item-tabs-ticket") == "Ticket"
      assert attr(html, "#work-item-tabs-ticket", "href") == ["/8wonders/main/work/88"]
      assert text(html, "#work-item-tabs-thread") == "Thread 3"
      assert attr(html, "#work-item-tabs-thread", "href") == ["/8wonders/main/work/88/thread"]
      assert attr(html, "#work-item-tabs-thread", "aria-current") == ["page"]

      none =
        render_component(&WorkItemComponents.work_item_tabs/1,
          number: 88,
          current: :ticket,
          ticket_path: "/8wonders/main/work/88",
          thread_path: "/8wonders/main/work/88/thread"
        )

      assert text(none, "#work-item-tabs-thread") == "Thread"
    end
  end

  defp comments do
    [
      %{
        public_id: "tc_01",
        author: "Mirek",
        at: ago(86_400),
        body: "One rounding function.",
        format: "markdown"
      },
      %{
        public_id: "tc_02",
        author: "Priya",
        at: ago(12 * 60),
        body: "Round the sum.",
        format: "text"
      }
    ]
  end

  defp ticket_tab(extra \\ []) do
    render_component(
      &WorkItemComponents.ticket_tab/1,
      Keyword.merge(
        [
          work_item: work_item(),
          ticket: ticket(),
          comments: comments(),
          integration: "GitHub",
          now: @now
        ],
        extra
      )
    )
  end

  describe "ticket_tab/1" do
    test "the ticket as the integration sent it" do
      html = ticket_tab()

      assert text(html, ".q-wi-key") == "G acme/shop#1204"
      assert attr(html, ".q-wi-key .q-bl-tile", "aria-label") == ["GitHub"]

      assert text(html, ".q-wi-tkt-filed") ==
               "Priya filed this 3 Oct 2026 · updated 12 minutes ago"

      assert text(html, "#work-item-ticket-out") =~ "Open on GitHub"
      assert attr(html, "#work-item-ticket-out", "href") == [@url]
      assert text(html, ".q-wi-facts") == "Labels bug, checkout"
      assert text(html, "#work-item-ticket-text-show-written") == "Show as written"
      assert html =~ "SAVE10"

      assert text(html, "#work-item-ticket-comments-h") == "6 comments on the ticket"
      assert text(html, "#work-item-ticket-earlier") == "Show 4 earlier comments"
      assert attr(html, "#work-item-ticket-earlier", "phx-click") == ["show_earlier_comments"]
      assert count(html, ".q-wi-cmt") == 2
      assert text(html, "#work-item-ticket-comment-tc_02 .q-wi-who") =~ "Priya"
      assert text(html, "#work-item-ticket-comment-tc_02-text") == "Round the sum."
      assert count(html, "#work-item-ticket-stale") == 0
    end

    test "one comment, and one earlier comment" do
      one = ticket_tab(ticket: ticket(%{comment_count: 1}), comments: Enum.take(comments(), 1))
      assert text(one, "#work-item-ticket-comments-h") == "1 comment on the ticket"
      assert count(one, "#work-item-ticket-earlier") == 0

      two = ticket_tab(ticket: ticket(%{comment_count: 2}), comments: Enum.take(comments(), -1))
      assert text(two, "#work-item-ticket-comments-h") == "2 comments on the ticket"
      assert text(two, "#work-item-ticket-earlier") == "Show 1 earlier comment"
    end

    test "every comment shown: no earlier comments; no labels: no Labels" do
      html = ticket_tab(ticket: ticket(%{comment_count: 2, labels: []}))
      assert count(html, "#work-item-ticket-earlier") == 0
      assert count(html, ".q-wi-facts") == 0
    end

    test "after the uninstall: when it was last sent, and no longer kept current" do
      html = ticket_tab(uninstalled: true, ticket: ticket(%{received_at: ago(120)}))

      assert text(html, "#work-item-ticket-stale") ==
               "The ticket as GitHub last sent it, 2 minutes ago. It is no longer kept current."
    end
  end

  # The Thread line's words as drawn: the ref's box is inline-flex, so the space the
  # external link's markup leaves after it is not drawn before the "." that follows.
  defp line(html), do: html |> text("p:first-child") |> String.replace(~r/\s+\./, ".")

  defp event(extra) do
    render_component(
      &WorkItemComponents.thread_event/1,
      Keyword.merge(
        [id: "ev-1", at: ~U[2026-10-14 11:24:00Z], integration: "GitHub", now: @now],
        extra
      )
    )
  end

  describe "thread_event/1" do
    test "taken in, with its time, and the first instruction under it" do
      html =
        event(
          kind: :taken_in,
          actor: @lea,
          owner: @lea,
          external_ref: "acme/shop#1204",
          url: @url,
          integration: "GitHub",
          first_instruction: "Check the rounding."
        )

      assert line(html) =~ "Lea took this in from G acme/shop#1204"
      assert attr(html, ".q-wi-ev-ref .q-bl-tile", "aria-label") == ["GitHub"]
      assert attr(html, ".q-wi-ev-ref a", "href") == [@url]
      assert attr(html, ".q-wi-ev-ref a", "target") == ["_blank"]
      assert attr(html, ".q-wi-ev-ref a", "rel") == ["noopener noreferrer nofollow"]
      assert text(html, ".q-wi-ev-ref a") =~ "(opens in a new tab)"
      assert text(html, ".q-wi-when") == "14 Oct, 11:24"
      assert text(html, ".q-wi-q") == "First instruction: Check the rounding."
    end

    test "taken in: a ticket url that may not be a link is the ref as text" do
      html =
        event(
          kind: :taken_in,
          actor: @lea,
          owner: @lea,
          external_ref: "acme/shop#1204",
          url: "http://example.com/acme/shop/issues/1204",
          integration: "GitHub"
        )

      assert count(html, "a") == 0
      assert text(html, ".q-wi-ev-ref") == "G acme/shop#1204"
    end

    test "taken in: an empty or blank first instruction is none" do
      for blank <- ["", "   ", "\n\t "] do
        html =
          event(
            kind: :taken_in,
            actor: @lea,
            owner: @lea,
            external_ref: "acme/shop#1204",
            integration: "GitHub",
            first_instruction: blank
          )

        assert count(html, ".q-wi-q") == 0
        refute html =~ "First instruction"
      end
    end

    test "taken in: the owner is another person by id, not by name" do
      taker = %{id: "pr_priya_a", name: "Priya", you: false}
      namesake = %{id: "pr_priya_b", name: "Priya", you: false}

      for {owner, expected} <- [
            {namesake, "Priya took this in from G acme/shop#1204. Priya owns it"},
            {%{taker | name: "Priya A."}, "Priya took this in from G acme/shop#1204"}
          ] do
        html = event(kind: :taken_in, actor: taker, owner: owner, external_ref: "acme/shop#1204")
        assert line(html) == expected <> " 14 Oct, 11:24"
      end

      same = event(kind: :taken_in, actor: taker, owner: taker, external_ref: "acme/shop#1204")
      assert line(same) == "Priya took this in from G acme/shop#1204 14 Oct, 11:24"
    end

    test "taken in: every owner and reader form" do
      for {actor, owner, expected} <- [
            {@dana, @dana, "You took this in from G acme/shop#1204"},
            {@lea, @dana, "Lea took this in from G acme/shop#1204. You own it"},
            {@lea, @priya, "Lea took this in from G acme/shop#1204. Priya owns it"},
            {@dana, @priya, "You took this in from G acme/shop#1204. Priya owns it"}
          ] do
        html = event(kind: :taken_in, actor: actor, owner: owner, external_ref: "acme/shop#1204")
        assert line(html) == expected <> " 14 Oct, 11:24"
      end
    end

    test "closed, declined and undone" do
      assert text(event(kind: :closed, actor: @priya), "p") =~ "Priya closed this work item"
      assert text(event(kind: :closed, actor: @dana), "p") =~ "You closed this work item"

      assert text(event(kind: :declined, actor: @priya), "p") =~
               "Priya declined this work item at Confirm"

      assert text(event(kind: :declined, actor: @dana), "p") =~
               "You declined this work item at Confirm"

      assert text(event(kind: :undone, actor: @dana), "p") =~
               "You undid this, before a run started"

      assert text(event(kind: :undone, actor: @priya), "p") =~
               "Priya undid this, before a run started"
    end
  end

  defp comment(author, extra \\ []) do
    render_component(
      &WorkItemComponents.thread_comment/1,
      Keyword.merge(
        [
          id: "comment-cm_01",
          comment: %{
            public_id: "cm_01",
            author: author,
            at: ~U[2026-10-14 11:34:00Z],
            body: "Wrong work item, sorry: this note was for #94.\n<b>not bold</b>"
          },
          now: @now
        ],
        extra
      )
    )
  end

  describe "thread_comment/1" do
    test "shown: who and when, its text as written, escaped; More for the reader's" do
      html = comment(@dana, can_delete: true)

      assert text(html, ".q-wi-box-h b") == "Dana"
      assert text(html, ".q-wi-box-h time") == "14 Oct, 11:34"
      assert text(html, "#comment-cm_01-body") =~ "Wrong work item, sorry"
      assert html =~ "&lt;b&gt;not bold&lt;/b&gt;"
      assert attr(html, "#comment-cm_01-more-button", "aria-label") == ["More for your comment"]
      assert attr(html, "#comment-cm_01-more-button", "title") == ["More"]
      assert text(html, "#comment-cm_01-delete") == "Delete comment"
      assert attr(html, "#comment-cm_01-delete", "phx-click") == ["ask_delete_comment"]
      assert attr(html, "#comment-cm_01-delete", "phx-value-comment") == ["cm_01"]
    end

    test "another's: More names whose; without the right to delete, no More" do
      html = comment(@lea, can_delete: true)
      assert attr(html, "#comment-cm_01-more-button", "aria-label") == ["More for Lea's comment"]
      assert count(comment(@lea), "#comment-cm_01-more") == 0
    end

    test "asking: the question under the comment, in both forms" do
      mine = comment(@dana, can_delete: true, state: :asking)
      assert text(mine, "#comment-cm_01-confirm-question") == "Delete your comment?"

      assert text(mine, "#comment-cm_01-confirm-sub") ==
               "It leaves the Thread for everyone. The Thread keeps a line that you deleted it."

      assert text(mine, "#comment-cm_01-confirm-go") == "Delete comment"
      assert attr(mine, "#comment-cm_01-confirm-go", "phx-click") == ["delete_comment"]
      assert attr(mine, "#comment-cm_01-confirm-go", "phx-value-comment") == ["cm_01"]
      assert text(mine, "#comment-cm_01-confirm-cancel") == "Cancel"
      assert count(mine, "#comment-cm_01-more") == 0

      theirs = comment(@lea, can_delete: true, state: :asking)
      assert text(theirs, "#comment-cm_01-confirm-question") == "Delete Lea's comment?"
    end

    test "deleted: who deleted it and when, in its place" do
      for {by, line} <- [{@dana, "Comment deleted by you"}, {@priya, "Comment deleted by Priya"}] do
        html = comment(@dana, state: :deleted, deleted_by: by, deleted_at: ago(5))
        assert text(html, "p") == line <> " 5 seconds ago"
        refute html =~ "Wrong work item"
        assert count(html, "li#comment-cm_01") == 1
      end
    end
  end

  describe "composer/1" do
    test "its label and placeholder, its line, and Comment" do
      html =
        render_component(&WorkItemComponents.composer/1,
          number: 88,
          workspace: "Main",
          reader: "Dana"
        )

      assert attr(html, "form", "phx-submit") == ["comment"]
      assert attr(html, "form", "novalidate") != []
      assert text(html, "label") == "Comment on work item #88"
      assert attr(html, "textarea", "placeholder") == ["Comment on work item #88"]
      assert attr(html, "textarea", "name") == ["body"]
      assert html =~ "Members of Main see this. Nothing is posted on the ticket."
      assert text(html, "button[type=submit]") == "Comment"
    end
  end

  describe "the frame and the Thread" do
    test "the rail is named for the work item" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <WorkItemComponents.work_item_frame label="Work item #88">
          <:header>
            <p>head</p>
          </:header>
          <:rail>
            <p>rail</p>
          </:rail>
          <:body>
            <WorkItemComponents.thread>
              <li>one</li>
            </WorkItemComponents.thread>
          </:body>
        </WorkItemComponents.work_item_frame>
        """)

      assert attr(html, "aside", "aria-label") == ["Work item #88"]
      assert attr(html, "ol.q-wi-tl", "aria-label") == ["Thread"]
    end
  end

  describe "the ticket's ref" do
    test "is drawn beside the integration's mark wherever it is shown" do
      thread =
        event(
          kind: :taken_in,
          actor: @lea,
          owner: @lea,
          external_ref: "acme/shop#1204",
          url: @url,
          integration: "GitHub"
        )

      row =
        render_component(&ApiaryWeb.WorkItemListComponents.work_item_row/1,
          id: "work-item-88",
          work_item: work_item(),
          integration: "GitHub",
          navigate: "/8wonders/main/work/88",
          now: @now
        )

      for {where, html, selector} <- [
            {"the header", header(work_item()), "a.q-wi-ref"},
            {"the Details row", details(work_item()), "#work-item-details-ticket .q-wi-l1"},
            {"the Details fold", details(work_item()), ".q-wi-dtoggle-s .q-wi-refm"},
            {"the Ticket tab", ticket_tab(), ".q-wi-key"},
            {"the Thread", thread, ".q-wi-ev-ref"},
            {"the list row", row, ".q-wl-tk"}
          ] do
        assert text(html, selector) =~ "G acme/shop#1204", where
        assert attr(html, "#{selector} .q-bl-tile", "aria-label") == ["GitHub"], where

        refs = html |> words() |> String.split("acme/shop#1204") |> length()
        marks = count(html, ".q-bl-tile")
        assert refs - 1 == marks, "#{where}: every ref beside a mark"
      end
    end

    test "is never in a DOM id, a phx-value or a path of Qory Apiary's" do
      w = work_item()
      queued = work_item(%{status: :queued, taken_in_by: @dana, taken_in_at: ago(5)})

      html =
        Enum.join([
          header(w),
          track(w),
          card(w),
          card(w, asking: :decline),
          card(queued),
          render_component(&WorkItemComponents.close_question/1,
            number: 88,
            integration: "GitHub"
          ),
          ended(:closed, @priya, ago(60)),
          details(w),
          ticket_tab(),
          event(
            kind: :taken_in,
            actor: @lea,
            owner: @dana,
            external_ref: "acme/shop#1204",
            url: @url,
            integration: "GitHub"
          ),
          comment(@dana, can_delete: true),
          comment(@dana, can_delete: true, state: :asking)
        ])

      nodes = query(html, "*")

      values =
        for node <- nodes,
            {name, value} <- node |> LazyHTML.attributes() |> List.first([]),
            name == "id" or name == "href" or String.starts_with?(name, "phx-value-") or
              String.starts_with?(name, "data-copy"),
            do: {name, value}

      assert Enum.any?(values, &match?({"phx-value-number", "88"}, &1))

      for {name, value} <- values do
        refute value =~ "acme/shop#1204", "#{name}=#{value}"
        refute value =~ "%231204", "#{name}=#{value}"

        if value =~ "1204",
          do: assert({name, value} == {"href", @url}, "#{name}=#{value}")
      end
    end
  end

  test "the module's docs are hidden from the documentation" do
    assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, _docs} =
             Code.fetch_docs(WorkItemComponents)

    assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, _docs} =
             Code.fetch_docs(ApiaryWeb.WorkItemListComponents)
  end
end
