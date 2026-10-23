defmodule ApiaryWeb.WorkItemExploreTest do
  @moduledoc """
  Explore's parts of a work item's page (`ApiaryWeb.WorkItemComponents`): the statuses and
  marks Explore adds, the step card in each Explore state, a take in again's undo, the
  declined at Explore notice, the tabs, Explore's tab in each state, the questions form,
  the proposal and its sources, the edit page, and Explore's lines in the Thread. Every
  DOM id, `phx-value-*` and path is Qory Apiary's: runs by their `rn_` id, questions by
  their public id, never the ticket's ref or a source's.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ApiaryWeb.WorkItemComponents, as: C

  @now ~U[2026-10-17 10:00:00Z]

  @dana %{id: "pr_dana", name: "Dana", email: "dana@example.com", you: true}
  @priya %{id: "pr_priya", name: "Priya", email: "priya@example.com", you: false}
  @lea %{id: "pr_lea", name: "Lea", email: "lea@example.com", you: false}

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  ## Fixtures: neutral example data

  defp proposal(overrides \\ %{}) do
    Map.merge(
      %{
        complexity: %{
          level: :standard,
          reason:
            "Two places compute the total, the basket and the order service. Both need the same function and its tests."
        },
        understanding:
          "The basket discounts each line and rounds it.\n\nThe order service rounds once.",
        scope_in: [
          "Compute the basket's total as the order service does.",
          "Move that rounding into one function."
        ],
        scope_out: ["Totals of orders already placed."],
        approach: "Extract the order service's rounding into a function in the pricing module.",
        alternatives: [
          %{
            text: "Round each line in the order service too.",
            reason: "Invoices follow the order service's total."
          }
        ],
        knowledge: [
          %{
            text: "The order service rounds half to even; the basket rounds half up.",
            sources: [
              "https://code.example.com/acme/shop/lib/pricing/order_total.ex",
              "https://docs.example.org/decimal/rounding#half-even"
            ]
          }
        ]
      },
      overrides
    )
  end

  defp run(overrides) do
    Map.merge(
      %{
        id: "rn_01a97b20c4e81f3d",
        path: "/8wonders/main/runs/rn_01a97b20c4e81f3d",
        attempt: 1,
        of: 3,
        state: :completed,
        started_at: ago(3 * 86_400 - 60),
        ended_at: ~U[2026-10-14 11:36:00Z],
        duration: "11 minutes",
        outcome: :proposal,
        proposal: proposal(),
        answers_by: []
      },
      overrides
    )
  end

  defp questions(answers \\ [nil, nil, nil]) do
    [
      "Should the discount apply first, so the gift card pays the discounted total?",
      "Can more than one discount code be used with a gift card?",
      "Should this work in the apps too, or only in the web checkout?"
    ]
    |> Enum.zip(answers)
    |> Enum.with_index(1)
    |> Enum.map(fn {{text, answer}, i} ->
      %{public_id: "qq_0#{i}", text: text, answer: answer}
    end)
  end

  @answers [
    "The discount first; the gift card pays what is left.",
    "At most one code, as today.",
    "Web checkout only."
  ]

  # #94: run 1 asked three questions, Dana answered; run 2 asked one, Priya answered.
  defp run1_answered do
    run(%{
      id: "rn_01aa1f3e5c0d82a4",
      path: "/8wonders/main/runs/rn_01aa1f3e5c0d82a4",
      attempt: 1,
      outcome: :questions,
      proposal: nil,
      understanding: "Today the basket holds one payment adjustment.",
      questions: questions(@answers),
      ended_at: ago(18 * 3600 + 29 * 60),
      answered_by: @dana,
      answered_at: ago(62 * 60)
    })
  end

  defp run2_answered do
    run(%{
      id: "rn_01aa40b29e71c6d3",
      path: "/8wonders/main/runs/rn_01aa40b29e71c6d3",
      attempt: 2,
      outcome: :questions,
      proposal: nil,
      understanding: nil,
      questions: [
        %{
          public_id: "qq_04",
          text: "Should the receipt change to the new order?",
          answer: "Change it: the discount first, then the gift card."
        }
      ],
      ended_at: ago(50 * 60),
      answered_by: @priya,
      answered_at: ago(20 * 60)
    })
  end

  defp work_item(overrides) do
    Map.merge(
      %{
        number: 88,
        title: "Checkout totals are a cent off when a discount applies",
        external_ref: "123456#42",
        key: "#1204",
        url: "https://example.com/acme/shop/issues/1204",
        repository: "acme/shop",
        status: :confirm,
        owner: @dana,
        ended_by: nil,
        ended_at: nil,
        updated_at: ago(3600),
        taken_in_by: @lea,
        taken_in_at: ~U[2026-10-14 11:24:00Z],
        first_instruction: nil,
        runs: nil,
        run: run(%{}),
        confirmed_by: nil,
        confirmed_at: nil
      },
      overrides
    )
  end

  ## Helpers

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> squish()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp texts(html, selector),
    do: html |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))

  defp card(w, extra \\ []) do
    render_component(
      &C.step_card/1,
      Keyword.merge([work_item: w, integration: "GitHub", can_act: true, now: @now], extra)
    )
  end

  defp tab(w, extra \\ []) do
    render_component(&C.explore_tab/1, Keyword.merge([work_item: w, now: @now], extra))
  end

  ## The statuses and marks

  describe "the statuses Explore adds" do
    test "their words and marks; questions and the run limit wait for the reader who may act" do
      used = run(%{attempt: 2, outcome: :questions})

      for {status, words, acts, reads} <- [
            {:questions, "Waits for answers", "wait", "wait_other"},
            {:used_up, "Explore used its 3 runs", "wait", "wait_other"},
            {:no_result, "Explore ended without a result", "err", "err"},
            {:lost, "Explore's run was lost", "err", "err"},
            {:cancelled, "Explore's run was cancelled", "err", "err"}
          ] do
        w = work_item(%{status: status, run: used})

        for {can_act, mark} <- [{true, acts}, {false, reads}] do
          html = render_component(&C.work_item_status/1, work_item: w, can_act: can_act)
          assert text(html, ".q-wi-st") == words
          assert attr(html, ".q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{mark}"]
          assert count(html, ".q-wi-hot") == 0
        end
      end
    end

    test "a run limit of one says run, not runs" do
      w = work_item(%{status: :used_up, run: run(%{attempt: 1, of: 1})})
      assert C.status_words(w) == "Explore used its 1 run"
    end

    test "the header's status follows the reader's right to act" do
      w = work_item(%{status: :questions, run: run(%{outcome: :questions})})

      for {can_act, mark} <- [{true, "wait"}, {false, "wait_other"}] do
        html =
          render_component(&C.work_item_header/1,
            work_item: w,
            integration: "GitHub",
            link: "https://apiary.example.com/8wonders/main/work/88",
            can_act: can_act
          )

        assert text(html, ".q-wi-meta .q-wi-st") == "Waits for answers"
        assert attr(html, ".q-wi-meta .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{mark}"]
      end
    end

    test "the stages: Explore current and amber while it waits for a member" do
      for status <- [:questions, :used_up] do
        html = render_component(&C.stage_track/1, work_item: work_item(%{status: status}))
        assert attr(html, "[aria-current]", "id") == ["work-item-stages-explore"]
        assert count(html, ".q-wi-stage-wait") == 1
      end

      for status <- [:no_result, :lost, :cancelled, :queued, :running] do
        html = render_component(&C.stage_track/1, work_item: work_item(%{status: status}))
        assert attr(html, "[aria-current]", "id") == ["work-item-stages-explore"]
        assert count(html, ".q-wi-stage-wait") == 0
      end
    end

    test "declined at Explore: Explore crossed, nothing done" do
      w = work_item(%{status: :declined, stage: :explore, ended_by: @dana})
      html = render_component(&C.stage_track/1, work_item: w)
      assert count(html, "[aria-current]") == 0
      assert count(html, "#work-item-stages-explore.q-wi-stage-stop") == 1
      assert text(html, ".q-wi-end") == "Declined"
    end
  end

  ## The step card

  describe "step_card/1, a take in again's undo (V-652)" do
    defp again(by, extra) do
      w =
        work_item(%{
          number: 94,
          status: :queued,
          taken_in_by: by,
          taken_in_at: ago(5),
          run: %{attempt: 1, of: 3}
        })

      card(w, Keyword.merge([can_undo: true], extra))
    end

    test "after a decline or a close: it goes back to how it ended, and nothing is sent" do
      for {previous, by, line} <- [
            {:declined, @dana,
             "You took this in again just now. Until a run starts, you can undo this: the work item goes back to declined, and nothing is sent to the ticket, so its label stays as it was."},
            {:declined, @priya,
             "Priya took this in again just now. Until a run starts, you can undo this: the work item goes back to declined, and nothing is sent to the ticket, so its label stays as it was."},
            {:closed, @dana,
             "You took this in again just now. Until a run starts, you can undo this: the work item goes back to closed, and nothing is sent to the ticket, so its label stays as it was."},
            {:closed, @priya,
             "Priya took this in again just now. Until a run starts, you can undo this: the work item goes back to closed, and nothing is sent to the ticket, so its label stays as it was."}
          ] do
        html = again(by, previous: previous)
        assert text(html, "#work-item-step-undo-line") == line
        assert text(html, "#work-item-step-undo button") == "Undo"
        assert attr(html, "#work-item-step-undo button", "phx-click") == ["undo"]
        assert attr(html, "#work-item-step-undo button", "phx-value-number") == ["94"]
      end
    end

    test "after an undo: undoing again takes the label off, as a first undo does" do
      for {by, line} <- [
            {@dana,
             "You took this in just now. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays."},
            {@priya,
             "Priya took this in just now. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays."}
          ] do
        html = again(by, previous: :undone)
        assert text(html, "#work-item-step-undo-line") == line
        refute html =~ "nothing is sent"
      end
    end

    test "an undo restores the undone notice" do
      w = work_item(%{status: :undone, ended_by: @dana, ended_at: ago(5)})

      html =
        render_component(&C.end_notice/1,
          work_item: w,
          integration: "GitHub",
          again_path: "/8wonders/main/backlog?ticket=tk_01j9z7",
          now: @now
        )

      assert text(html, "#work-item-ended-line") ==
               "You undid this just now, before a run started."

      assert text(html, ".q-wi-grow > p:last-child") ==
               "Qory took its label off the ticket, and its comment stays there. In the Backlog, Take in again brings this work item back."
    end

    test "without the right to undo: who took it in again and when, and no Undo" do
      for {previous, by, line} <- [
            {:declined, @dana, "You took this in again just now."},
            {:closed, @priya, "Priya took this in again just now."}
          ] do
        html = again(by, previous: previous, can_undo: false)
        assert text(html, "#work-item-step-undo-line") == line
        assert count(html, "#work-item-step-undo button") == 0
      end
    end

    test "after the uninstall, a take in again reads the built uninstall line" do
      html = again(@dana, previous: :declined, uninstalled: true)

      assert text(html, "#work-item-step-undo-line") ==
               "You took this in just now. Until a run starts, you can undo this. GitHub is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment."
    end
  end

  describe "step_card/1, Explore queued and running, a later run" do
    test "queued with answers: whose answers it reads, which run, and no Undo" do
      for {people, line} <- [
            {[@dana],
             "Qory reads the ticket, the code and your answers when the run starts, and proposes how to build it."},
            {[@priya],
             "Qory reads the ticket, the code and Priya's answers when the run starts, and proposes how to build it."},
            {[@dana, @priya],
             "Qory reads the ticket, the code and the answers of this take in when the run starts, and proposes how to build it."},
            {[@priya, %{@priya | name: "Priya"}],
             "Qory reads the ticket, the code and Priya's answers when the run starts, and proposes how to build it."},
            {[],
             "Qory reads the ticket and the code when the run starts, and proposes how to build it."}
          ] do
        w = work_item(%{status: :queued, run: %{attempt: 2, of: 3, answers_by: people}})
        html = card(w, can_undo: true)

        assert text(html, ".q-wi-badge") == "Queued"
        assert text(html, ".q-wi-bee-line") == line
        assert text(html, "#work-item-step-run") == "Run 2 of 3 is queued."
        assert count(html, "#work-item-step-undo") == 0
        assert count(html, "button") == 0
      end
    end

    test "running n of 3: whose answers it reads, and its run by its rn_ id" do
      for {people, line} <- [
            {[@dana],
             "Qory is exploring again, with your answers. It reads the ticket and the code, and proposes how to build it."},
            {[@dana, @priya],
             "Qory is exploring again, with the answers of this take in. It reads the ticket and the code, and proposes how to build it."}
          ] do
        r =
          run(%{
            id: "rn_01aa47c9b05e3f18",
            path: "/8wonders/main/runs/rn_01aa47c9b05e3f18",
            attempt: 3,
            state: :running,
            started_at: ago(120),
            answers_by: people
          })

        html = card(work_item(%{status: :running, run: r}))
        assert text(html, ".q-wi-bee-line") == line
        assert text(html, "#work-item-step-run") == "Run rn_01aa47c9 started 2 minutes ago."

        assert attr(html, "#work-item-step-run a", "href") == [
                 "/8wonders/main/runs/rn_01aa47c9b05e3f18"
               ]
      end
    end
  end

  describe "step_card/1, Explore's questions" do
    defp asked(n, extra \\ []) do
      w =
        work_item(%{
          number: 94,
          status: :questions,
          run: run(%{outcome: :questions, questions: Enum.take(questions(), n)})
        })

      card(w, extra)
    end

    test "a member who may act: the badge, the line, the link to Explore, and Decline" do
      html = asked(3, explore_path: "/8wonders/main/work/94/explore")

      assert text(html, "h2") == "Explore"
      assert text(html, ".q-wi-badge") == "Waits for answers"
      assert count(html, ".q-wi-step-ask") == 1
      assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait"]

      assert text(html, ".q-wi-bee-line") ==
               "Qory asked 3 questions before it can propose how to build it. Answer them, and Qory explores again with your answers. Or decline the work item."

      assert text(html, "#work-item-step-explore") == "Answer the questions"
      assert attr(html, "#work-item-step-explore", "href") == ["/8wonders/main/work/94/explore"]
      assert text(html, "#work-item-step-decline") == "Decline"
      assert attr(html, "#work-item-step-decline", "phx-click") == ["ask_decline"]
      assert attr(html, "#work-item-step-decline", "phx-value-number") == ["94"]
    end

    test "one question; on Explore's tab, no link" do
      html = asked(1)

      assert text(html, ".q-wi-bee-line") ==
               "Qory asked 1 question before it can propose how to build it. Answer it, and Qory explores again with your answer. Or decline the work item."

      assert count(html, "#work-item-step-explore") == 0

      linked = asked(1, explore_path: "/8wonders/main/work/94/explore")
      assert text(linked, "#work-item-step-explore") == "Answer the question"
    end

    test "a reader who may not act: what Qory asked, that it waits for a member, no button" do
      for {n, line, waits} <- [
            {3, "Qory asked 3 questions before it can propose how to build it.",
             "Waits for a member to answer Qory's questions."},
            {1, "Qory asked 1 question before it can propose how to build it.",
             "Waits for a member to answer Qory's question."}
          ] do
        html = asked(n, can_act: false, explore_path: "/8wonders/main/work/94/explore")
        assert text(html, ".q-wi-bee-line") == line
        assert text(html, "#work-item-step-waits") == waits
        assert text(html, ".q-wi-badge") == "Waits for answers"
        assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait_other"]
        assert count(html, ".q-wi-step-ask") == 0
        assert count(html, "button") == 0
        assert count(html, "a") == 0
      end
    end

    test "Decline asks in place, as at Confirm" do
      html = asked(3, asking: :decline)
      assert text(html, "#work-item-step-decline-question") == "Decline work item #94?"

      assert text(html, "#work-item-step-decline-sub") ==
               "The ticket stays open on GitHub and keeps Qory's label, and nothing new is posted there. In the Backlog, Take in again brings this work item back."

      assert attr(html, "#work-item-step-decline-go", "phx-click") == ["decline"]
      assert attr(html, "#work-item-step-decline-go", "phx-value-number") == ["94"]
      refute html =~ "Qory asked"
    end
  end

  describe "step_card/1, a run without a result" do
    test "no result, lost, cancelled: the badge, what happened, Run Explore again and Decline" do
      for {status, overrides, badge, line} <- [
            {:no_result, %{state: :failed, outcome: :error}, "No result",
             "Run rn_01aa52d0 ended with an error, so Explore has no result."},
            {:no_result, %{outcome: :none}, "No result",
             "Run rn_01aa52d0 ended without a result."},
            {:no_result, %{outcome: :refused}, "No result",
             "Run rn_01aa52d0 returned a result that did not pass Qory's check, so Explore has no result."},
            {:lost, %{state: :lost, outcome: nil}, "Lost",
             "Run rn_01aa52d0 was lost before it ended, so Explore has no result."},
            {:cancelled, %{state: :cancelled, outcome: nil}, "Cancelled",
             "Run rn_01aa52d0 was cancelled before it ended, so Explore has no result."}
          ] do
        r =
          run(
            Map.merge(
              %{id: "rn_01aa52d07c4a91e6", path: "/8wonders/main/runs/rn_01aa52d07c4a91e6"},
              overrides
            )
          )

        html = card(work_item(%{number: 97, status: status, run: r}))

        assert text(html, ".q-wi-badge") == badge
        assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-err"]
        assert text(html, "#work-item-step-line") == line

        assert attr(html, "#work-item-step-line a", "href") == [
                 "/8wonders/main/runs/rn_01aa52d07c4a91e6"
               ]

        assert text(html, "#work-item-step-again") == "Run Explore again"
        assert attr(html, "#work-item-step-again", "phx-click") == ["explore_again"]
        assert attr(html, "#work-item-step-again", "phx-value-number") == ["97"]
        assert text(html, "#work-item-step-decline") == "Decline"
        assert text(html, "#work-item-step-next") == "It starts run 2 of 3 of this take in."

        reader = card(work_item(%{number: 97, status: status, run: r}), can_act: false)
        assert text(reader, "#work-item-step-line") == line
        assert count(reader, "button") == 0
        assert count(reader, "#work-item-step-next") == 0
      end
    end
  end

  describe "step_card/1, the run limit" do
    defp used(overrides, extra \\ []) do
      r =
        run(
          Map.merge(
            %{
              id: "rn_01aa47c9b05e3f18",
              path: "/8wonders/main/runs/rn_01aa47c9b05e3f18",
              attempt: 3,
              outcome: :questions,
              questions: [hd(questions())]
            },
            overrides
          )
        )

      card(work_item(%{number: 94, status: :used_up, run: r}), extra)
    end

    test "3 of 3 runs used: why Qory cannot explore again, the two ways on, Decline and Close" do
      html = used(%{}, can_close: true)

      assert text(html, ".q-wi-badge") == "3 of 3 runs used"
      assert count(html, ".q-wi-step-ask") == 1

      assert text(html, "#work-item-step-line") ==
               "Qory still has 1 question after run 3 of 3, the most one take in has, so it cannot explore again in this take in."

      assert text(html, "#work-item-step-ways") ==
               "Decline the work item if it is not wanted. To explore again, close it: Take in again from the Backlog then starts a fresh count, and answers from this take in are not carried over."

      assert text(html, "#work-item-step-decline") == "Decline"
      assert attr(html, "#work-item-step-decline", "phx-click") == ["ask_decline"]
      assert text(html, "#work-item-step-close") == "Close work item…"
      assert attr(html, "#work-item-step-close", "phx-click") == ["ask_close"]
      assert attr(html, "#work-item-step-close", "phx-value-number") == ["94"]
      refute html =~ "Take in again</"
      refute html =~ "Run Explore again"
    end

    test "while the repository keeps its tickets out of the Backlog, the ways on say no Take in again" do
      html = used(%{}, can_close: true, backlog_off: true)

      assert text(html, "#work-item-step-ways") ==
               "Decline the work item if it is not wanted, or close it."

      assert count(html, "#work-item-step-decline") == 1
      assert count(html, "#work-item-step-close") == 1
      refute html =~ "Take in again"
    end

    test "two questions left; the last run without a result" do
      two = used(%{questions: Enum.take(questions(), 2)})

      assert text(two, "#work-item-step-line") ==
               "Qory still has 2 questions after run 3 of 3, the most one take in has, so it cannot explore again in this take in."

      none = used(%{state: :failed, outcome: :error})

      assert text(none, "#work-item-step-line") ==
               "Run rn_01aa47c9 was run 3 of 3, the most one take in has, and it ended without a result, so Qory cannot explore again in this take in."
    end

    test "Close only with the right to close; a reader who may not act reads why, and nothing to do" do
      assert count(used(%{}, can_close: false), "#work-item-step-close") == 0

      reader = used(%{}, can_act: false, can_close: true)
      assert text(reader, "#work-item-step-line") =~ "Qory still has 1 question"
      assert count(reader, "#work-item-step-ways") == 0
      assert count(reader, "button") == 0
      assert attr(reader, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait_other"]
    end

    test "Decline asks in place" do
      html = used(%{}, asking: :decline)
      assert text(html, "#work-item-step-decline-question") == "Decline work item #94?"
      assert text(html, ".q-wi-badge") == "3 of 3 runs used"
    end
  end

  describe "step_card/1, Confirm" do
    test "the line, Read Qory's proposal, Confirm, Change and Decline" do
      html =
        card(work_item(%{}),
          explore_path: "/8wonders/main/work/88/explore",
          edit_path: "/8wonders/main/work/88/explore/edit"
        )

      assert text(html, ".q-wi-bee-line") ==
               "Qory proposed how to build it. Confirm it, change it first, or decline the work item."

      assert text(html, "#work-item-step-explore") == "Read Qory's proposal"
      assert attr(html, "#work-item-step-explore", "href") == ["/8wonders/main/work/88/explore"]

      assert texts(html, ".q-wi-acts > *") == ["Confirm", "Change", "Decline"]

      assert attr(html, "#work-item-step-change", "href") == [
               "/8wonders/main/work/88/explore/edit"
             ]

      assert count(html, ".btn-primary") == 1
    end

    test "on Explore's tab, no link; without the right to act, neither Change nor the link" do
      html = card(work_item(%{}), edit_path: "/8wonders/main/work/88/explore/edit")
      assert count(html, "#work-item-step-explore") == 0

      reader =
        card(work_item(%{owner: @priya}),
          can_act: false,
          explore_path: "/8wonders/main/work/88/explore",
          edit_path: "/8wonders/main/work/88/explore/edit"
        )

      assert count(reader, "a") == 0
      assert count(reader, "button") == 0
    end
  end

  ## The notice, the tabs

  describe "end_notice/1, declined at Explore" do
    test "who declined it and when, at Explore" do
      for {by, line} <- [
            {@dana, "You declined this work item just now, at Explore."},
            {@priya, "Priya declined this work item just now, at Explore."}
          ] do
        w = work_item(%{status: :declined, stage: :explore, ended_by: by, ended_at: ago(5)})

        html =
          render_component(&C.end_notice/1, work_item: w, integration: "GitHub", now: @now)

        assert text(html, "#work-item-ended-line") == line
      end
    end
  end

  test "work_item_tabs/1: Ticket, Explore and Thread, Explore current" do
    html =
      render_component(&C.work_item_tabs/1,
        number: 88,
        current: :explore,
        ticket_path: "/8wonders/main/work/88",
        explore_path: "/8wonders/main/work/88/explore",
        thread_path: "/8wonders/main/work/88/thread"
      )

    assert texts(html, "nav a") == ["Ticket", "Explore", "Thread"]
    assert attr(html, "#work-item-tabs-explore", "href") == ["/8wonders/main/work/88/explore"]
    assert attr(html, "#work-item-tabs-explore", "aria-current") == ["page"]
    assert attr(html, "#work-item-tabs-ticket", "aria-current") == []
  end

  ## Explore's tab

  defp items(html, id), do: texts(html, "##{id} > span")

  describe "step_card/1, in a general workspace" do
    # A general workspace reads the source texts, which name no code; the tests above read
    # the software catalogue's, the default locale's.
    test "Explore reads the ticket and the answers, and proposes what to do" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@general", fn ->
        for {people, line} <- [
              {[], "Qory reads the ticket when the run starts, and proposes what to do."},
              {[@dana],
               "Qory reads the ticket and your answers when the run starts, and proposes what to do."},
              {[@priya],
               "Qory reads the ticket and Priya's answers when the run starts, and proposes what to do."},
              {[@dana, @priya],
               "Qory reads the ticket and the answers of this take in when the run starts, and proposes what to do."}
            ] do
          w = work_item(%{status: :queued, run: %{attempt: 2, of: 3, answers_by: people}})
          assert text(card(w), ".q-wi-bee-line") == line
        end

        assert text(asked(3), ".q-wi-bee-line") ==
                 "Qory asked 3 questions before it can propose what to do. Answer them, and Qory explores again with your answers. Or decline the work item."

        assert text(asked(1, can_act: false), ".q-wi-bee-line") ==
                 "Qory asked 1 question before it can propose what to do."

        assert text(card(work_item(%{})), ".q-wi-bee-line") ==
                 "Qory proposed what to do. Confirm it, change it first, or decline the work item."
      end)
    end
  end

  describe "explore_tab/1, queued and running" do
    test "queued, the first run: Run 1 of 3, Queued, and what Qory does" do
      html = tab(work_item(%{number: 341, status: :queued, run: %{attempt: 1, of: 3}}))

      assert items(html, "work-item-explore-run") == ["Run 1 of 3", "Queued"]
      assert text(html, "#work-item-explore-wait-h") == "Explore is queued."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Qory starts run 1 of 3 when the workspace's node pool takes it. It reads the ticket and the code, and proposes how to build it, or asks what it needs to know."

      assert count(html, ".q-xp-frame") == 0
    end

    test "a pending run reads Queued too, with its id" do
      r = run(%{state: :pending, attempt: 1, ended_at: nil})
      html = tab(work_item(%{status: :queued, run: r}))
      assert items(html, "work-item-explore-run") == ["Run 1 of 3", "rn_01a97b20", "Queued"]
    end

    test "queued again with the reader's answers: the answers run 2 reads, grouped" do
      w = work_item(%{number: 94, status: :queued, run: %{attempt: 2, of: 3}})
      html = tab(w, earlier_runs: [run1_answered()])

      assert items(html, "work-item-explore-run") == ["Run 2 of 3", "Queued"]

      assert text(html, "#work-item-explore-wait-h") ==
               "Explore is queued again, with your answers."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Run 2 of 3 starts when the workspace's node pool takes it. It reads the ticket, the code and these answers, from the start."

      assert text(html, "#work-item-explore-read-h") == "The answers run 2 reads"

      assert text(html, "#work-item-explore-read .q-xp-cap") ==
               "Explore asked these in 1 earlier run of this take in, shown as plain text."

      group = "#work-item-explore-read-rn_01aa1f3e5c0d82a4"
      assert text(html, "#{group}-h") == "Run 1 of 3 rn_01aa1f3e"
      assert attr(html, "#{group}-h a", "href") == ["/8wonders/main/runs/rn_01aa1f3e5c0d82a4"]
      assert text(html, "#{group}-qa-who") == "You answered 1 hour ago"
      assert texts(html, "#{group} .q-xp-ans") == @answers
    end

    test "run 3 running, with two members' answers" do
      r =
        run(%{
          id: "rn_01aa47c9b05e3f18",
          path: "/8wonders/main/runs/rn_01aa47c9b05e3f18",
          attempt: 3,
          state: :running,
          started_at: ago(120),
          ended_at: nil
        })

      html =
        tab(work_item(%{status: :running, run: r}),
          earlier_runs: [run1_answered(), run2_answered()]
        )

      assert items(html, "work-item-explore-run") ==
               ["Run 3 of 3", "rn_01aa47c9", "Running", "started 2 minutes ago"]

      assert attr(html, "#work-item-explore-run span.q-xp-run-on", "class") == ["q-xp-run-on"]

      assert text(html, "#work-item-explore-wait-h") ==
               "Qory is exploring again, with the answers of this take in."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Run 3 of 3 reads the ticket, the code and these answers, from the start. It proposes how to build it, or asks what it still needs to know."

      assert text(html, "#work-item-explore-read-h") == "The answers run 3 reads"

      assert text(html, "#work-item-explore-read .q-xp-cap") ==
               "Explore asked these in 2 earlier runs of this take in, shown as plain text."

      assert texts(html, ".q-xp-grp .q-xp-who") ==
               ["You answered 1 hour ago", "Priya answered 20 minutes ago"]

      assert texts(html, "#work-item-explore-earlier summary") == [
               "Run 1 of 3 rn_01aa1f3e Asked 3 questions Yesterday, 15:31",
               "Run 2 of 3 rn_01aa40b2 Asked 1 question 50 minutes ago"
             ]
    end

    test "the first run running: no answers" do
      r = run(%{state: :running, started_at: ago(6 * 60), ended_at: nil})
      html = tab(work_item(%{status: :running, run: r}))

      assert text(html, "#work-item-explore-wait-h") == "Qory is exploring."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Run 1 of 3 reads the ticket and the code. It proposes how to build it, or asks what it needs to know."

      assert count(html, "#work-item-explore-read") == 0
    end
  end

  describe "explore_tab/1, Qory's proposal" do
    test "the run line, the frame that names the run, and every section in order" do
      html = tab(work_item(%{}))

      assert items(html, "work-item-explore-run") ==
               ["Run 1 of 3", "rn_01a97b20", "Completed", "ended 3 days ago, after 11 minutes"]

      p = "#work-item-explore-proposal"
      assert text(html, "#{p}-h") == "Qory's proposal"
      assert count(html, "#{p} .q-xp-frame-h .badge") == 0

      assert text(html, "#{p} .q-xp-cap") ==
               "Explore wrote this in run rn_01a97b20. Qory shows it as plain text, as the run wrote it."

      assert attr(html, "#{p} .q-xp-cap a", "href") == ["/8wonders/main/runs/rn_01a97b20c4e81f3d"]

      assert texts(html, "#{p} .q-xp-sec > h3") == [
               "Complexity",
               "Understanding",
               "In scope",
               "Out of scope",
               "Approach",
               "Not chosen",
               "What Qory learned, and where"
             ]

      assert text(html, "#{p}-complexity .badge") == "Standard"

      assert texts(html, "#{p}-scope-in li") == [
               "Compute the basket's total as the order service does.",
               "Move that rounding into one function."
             ]

      assert texts(html, "#{p}-alternatives li") == [
               "Round each line in the order service too.Why not: Invoices follow the order service's total."
             ]

      assert text(html, "#{p}-alternatives .q-xp-why bdi") ==
               "Invoices follow the order service's total."

      assert attr(html, "#{p}-knowledge .q-xp-src", "aria-label") == ["Sources"]
    end

    test "the run's words are plain text: escaped, their line breaks kept" do
      p = proposal(%{understanding: "Line one.\n<b>not bold</b>", approach: "**not markdown**"})
      html = tab(work_item(%{run: run(%{proposal: p})}))

      [value] =
        html |> query("#work-item-explore-proposal-understanding .q-xp-val") |> Enum.to_list()

      assert LazyHTML.text(value) == "Line one.\n<b>not bold</b>"
      assert html =~ "&lt;b&gt;not bold&lt;/b&gt;"
      assert count(html, "#work-item-explore-proposal-understanding b") == 0
      assert text(html, "#work-item-explore-proposal-approach .q-xp-val") == "**not markdown**"
    end

    test "an empty Out of scope, Not chosen and knowledge say None" do
      p = proposal(%{scope_out: [], alternatives: [], knowledge: []})
      html = tab(work_item(%{run: run(%{proposal: p})}))

      for section <- ["scope-out", "alternatives", "knowledge"] do
        assert text(html, "#work-item-explore-proposal-#{section} li") == "None", section
        assert count(html, "#work-item-explore-proposal-#{section} .q-xp-none") == 1, section
      end
    end

    test "each complexity level is Qory Apiary's word" do
      for {level, word} <- [simple: "Simple", standard: "Standard", complex: "Complex"] do
        p = proposal(%{complexity: %{level: level, reason: "Why."}})
        html = tab(work_item(%{run: run(%{proposal: p})}))
        assert text(html, "#work-item-explore-proposal-complexity .badge") == word
      end
    end

    test "confirmed with the reader's changes: Confirmed, who and when, Changed by you, Qory's words folded" do
      w = work_item(%{status: :shape, confirmed_by: @dana, confirmed_at: ago(30)})

      changes = %{
        approach: %{
          value: "Extract the rounding, half to even, into the pricing module.",
          by: @dana
        },
        scope_out: %{value: ["Totals of orders already placed.", "The mobile apps."], by: @dana}
      }

      html = tab(w, changes: changes)
      p = "#work-item-explore-proposal"

      assert text(html, "#{p} .q-xp-frame-h .badge") == "Confirmed"

      assert text(html, "#{p} .q-xp-cap") ==
               "You confirmed it just now, with your changes. Explore wrote the rest in run rn_01a97b20, shown as plain text."

      assert text(html, "#{p}-approach-by") == "Changed by you"

      assert text(html, "#{p}-approach .q-xp-mine") ==
               "Extract the rounding, half to even, into the pricing module."

      assert attr(html, "#{p}-approach-toggle", "aria-expanded") == ["false"]

      assert attr(html, "#{p}-approach-toggle", "aria-controls") == [
               "work-item-explore-proposal-approach-was"
             ]

      assert text(html, "#{p}-approach-toggle .q-xp-show") == "Show Qory's words"
      assert text(html, "#{p}-approach-toggle .q-xp-hide") == "Hide Qory's words"
      assert attr(html, "#{p}-approach-was", "hidden") == [""]

      assert text(html, "#{p}-approach-was") ==
               "Qory's words Extract the order service's rounding into a function in the pricing module."

      assert texts(html, "#{p}-scope-out .q-xp-mine li") ==
               ["Totals of orders already placed.", "The mobile apps."]

      assert texts(html, "#{p}-scope-out .q-xp-was li") == ["Totals of orders already placed."]
      assert count(html, "#{p}-understanding-toggle") == 0
    end

    test "confirmed by another member, with and without changes" do
      w = work_item(%{status: :shape, confirmed_by: @priya, confirmed_at: ago(3 * 3600)})

      changed = tab(w, changes: %{approach: %{value: "Another approach.", by: @priya}})

      assert text(changed, "#work-item-explore-proposal .q-xp-cap") ==
               "Priya confirmed it 3 hours ago, with their changes. Explore wrote the rest in run rn_01a97b20, shown as plain text."

      assert text(changed, "#work-item-explore-proposal-approach-by") == "Changed by Priya"

      unchanged = tab(w)

      assert text(unchanged, "#work-item-explore-proposal .q-xp-cap") ==
               "Priya confirmed it 3 hours ago. Explore wrote it in run rn_01a97b20, shown as plain text."

      mine = tab(%{w | confirmed_by: @dana})

      assert text(mine, "#work-item-explore-proposal .q-xp-cap") ==
               "You confirmed it 3 hours ago. Explore wrote it in run rn_01a97b20, shown as plain text."
    end

    test "declined at Confirm: the proposal, read" do
      w =
        work_item(%{status: :declined, stage: :confirm, ended_by: @priya, ended_at: ago(86_400)})

      html = tab(w)
      assert text(html, "#work-item-explore-proposal-h") == "Qory's proposal"
      assert count(html, ".q-xp-frame-h .badge") == 0
      assert count(html, "form") == 0
    end
  end

  describe "explore_tab/1, the sources" do
    defp sources(urls) do
      p = proposal(%{knowledge: [%{text: "A fact.", sources: urls}]})
      tab(work_item(%{run: run(%{proposal: p})}))
    end

    test "an https source is a link out: its host and path, each isolated, the address in its title" do
      url = "https://code.example.com/acme/shop/lib/pricing/order_total.ex"
      html = sources([url])

      assert attr(html, ".q-xp-src a", "href") == [url]
      assert attr(html, ".q-xp-src a", "title") == [url]
      assert attr(html, ".q-xp-src a", "target") == ["_blank"]
      assert attr(html, ".q-xp-src a", "rel") == ["noopener noreferrer nofollow"]
      assert text(html, ".q-xp-src a bdi.q-xp-host") == "code.example.com"
      assert text(html, ".q-xp-src a bdi.q-xp-path") == "/acme/shop/lib/pricing/order_total.ex"
      assert text(html, ".q-xp-src a .sr-only") == "(opens in a new tab)"
    end

    test "a source that is not an https url core allows is its address as text, never a link" do
      for {url, shown} <- [
            {"http://code.example.com/a", "http://code.example.com/a"},
            {"javascript:alert(1)", "javascript:alert(1)"},
            {"https://user:pw@code.example.com/a", "https://user:pw@code.example.com/a"},
            {"https://xn--exmple-cua.com/a", "https://xn--exmple-cua.com/a"},
            {"https://exämple.com/a", "https://ex%C3%A4mple.com/a"},
            {"data:text/html,<b>x</b>", "data:text/html,<b>x</b>"},
            {"//code.example.com/a", "//code.example.com/a"}
          ] do
        html = sources([url])
        assert count(html, ".q-xp-src a") == 0, url

        assert html |> attr("[href]", "href") |> Enum.uniq() == [
                 "/8wonders/main/runs/rn_01a97b20c4e81f3d"
               ],
               url

        assert text(html, ".q-xp-src .q-xp-src-t bdi") == shown, url
        refute html =~ ~s(href="#{url}"), url
        refute html =~ "<b>x", url
      end
    end
  end

  describe "explore_tab/1, the questions form" do
    defp questions_item(extra \\ %{}) do
      work_item(
        Map.merge(
          %{
            number: 94,
            status: :questions,
            run:
              run(%{
                id: "rn_01aa1f3e5c0d82a4",
                path: "/8wonders/main/runs/rn_01aa1f3e5c0d82a4",
                outcome: :questions,
                proposal: nil,
                understanding: "Today the basket holds one payment adjustment.",
                questions: questions()
              })
          },
          extra
        )
      )
    end

    test "Qory's questions, each with its field, and Answer and explore again" do
      html = tab(questions_item(), can_act: true)
      q = "#work-item-explore-questions"

      assert text(html, "#{q}-h") == "Qory's questions"

      assert text(html, "#{q} .q-xp-cap") ==
               "Explore wrote this in run rn_01aa1f3e. Qory shows it as plain text, as the run wrote it."

      assert texts(html, "#{q} .q-xp-sec > h3") ==
               ["What Qory understood so far", "What Qory needs to know"]

      assert attr(html, "#{q}-form", "phx-submit") == ["answer"]
      assert attr(html, "#{q}-form", "novalidate") == [""]
      assert attr(html, "#{q}-form input[type=hidden]", "name") == ["number"]
      assert attr(html, "#{q}-form input[type=hidden]", "value") == ["94"]

      assert texts(html, "#{q}-form label") ==
               ["Answer to question 1", "Answer to question 2", "Answer to question 3"]

      assert attr(html, "#{q}-form textarea", "name") ==
               ["answers[qq_01]", "answers[qq_02]", "answers[qq_03]"]

      assert attr(html, "#{q}-form textarea", "placeholder") ==
               ["Your answer", "Your answer", "Your answer"]

      assert attr(html, "#work-item-explore-questions-answer-qq_02", "aria-describedby") ==
               ["work-item-explore-questions-q-qq_02"]

      assert text(html, "#work-item-explore-questions-q-qq_02") ==
               "Can more than one discount code be used with a gift card?"

      assert text(html, "#{q}-next") ==
               "Qory runs Explore again from the start, with the ticket, its comments, the first instruction and the answers of this take in. It is run 2 of 3."

      assert text(html, "#{q}-go") == "Answer and explore again"
      assert attr(html, "#{q}-go", "type") == ["submit"]
      assert count(html, "[aria-invalid]") == 0
    end

    test "one question, and no understanding given" do
      w = questions_item()
      w = %{w | run: %{w.run | questions: [hd(questions())], understanding: nil}}
      html = tab(w, can_act: true)

      assert text(html, "#work-item-explore-questions-h") == "Qory's question"
      assert texts(html, ".q-xp-sec > h3") == ["What Qory needs to know"]
    end

    test "errors: under their field, describing it, and the focus on the first" do
      html =
        tab(questions_item(),
          can_act: true,
          answers: %{"qq_01" => @answers |> hd(), "qq_03" => String.duplicate("a", 2001)},
          errors: %{"qq_02" => :blank, "qq_03" => {:too_long, 2000}}
        )

      a2 = "#work-item-explore-questions-answer-qq_02"
      assert attr(html, a2, "aria-invalid") == ["true"]

      assert attr(html, a2, "aria-describedby") == [
               "work-item-explore-questions-q-qq_02 work-item-explore-questions-answer-qq_02-error"
             ]

      assert text(html, "#{a2}-error") ==
               "Answer this question. If nobody knows, say so: Qory reads that too."

      assert text(html, "#work-item-explore-questions-answer-qq_03-error") ==
               "Write at most 2,000 characters."

      assert text(html, "#work-item-explore-questions-answer-qq_01") == hd(@answers)
      assert attr(html, "#work-item-explore-questions-answer-qq_01", "aria-invalid") == []

      assert attr(html, "#work-item-explore-questions-focus-0-qq_02", "phx-mounted") |> hd() =~
               "#work-item-explore-questions-answer-qq_02"
    end

    test "a reader who may not act reads the questions, without fields" do
      html = tab(questions_item(), can_act: false)
      assert count(html, "form") == 0
      assert count(html, "textarea") == 0
      assert length(texts(html, ".q-xp-qs .q-xp-val")) == 3
    end

    test "a question's words are plain text" do
      w = questions_item()

      qs = [%{public_id: "qq_09", text: "Two lines\n<script>x</script>", answer: nil}]
      html = tab(%{w | run: %{w.run | questions: qs}}, can_act: true)
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "explore_tab/1, the run limit and the earlier runs" do
    defp used_item(status \\ :used_up, extra \\ %{}) do
      r =
        run(%{
          id: "rn_01aa47c9b05e3f18",
          path: "/8wonders/main/runs/rn_01aa47c9b05e3f18",
          attempt: 3,
          outcome: :questions,
          proposal: nil,
          understanding: nil,
          questions: [
            %{public_id: "qq_05", text: "Should a refund go to the gift card first?", answer: nil}
          ],
          ended_at: ago(8 * 60),
          duration: "9 minutes"
        })

      work_item(Map.merge(%{number: 94, status: status, run: r}, extra))
    end

    test "the note, the last questions read-only, and the earlier runs folded" do
      html = tab(used_item(), can_act: true, earlier_runs: [run1_answered(), run2_answered()])

      assert items(html, "work-item-explore-run") ==
               ["Run 3 of 3", "rn_01aa47c9", "Completed", "ended 8 minutes ago, after 9 minutes"]

      assert text(html, "#work-item-explore-limit") ==
               "This take in has used its 3 runs, so Qory runs no more for these questions here. After a decline or a close, Take in again from the Backlog starts the count again."

      assert count(html, "textarea") == 0
      assert text(html, "#work-item-explore-questions-h") == "Qory's question"
      assert text(html, "#work-item-explore-earlier-h") == "Earlier runs of this take in"

      body = "#work-item-explore-earlier-rn_01aa1f3e5c0d82a4-body"
      assert text(html, "#{body}-h") == "Qory's questions, and the answers"

      assert text(html, "#{body} .q-xp-cap") ==
               "Explore asked these in run rn_01aa1f3e, shown as plain text."

      assert text(html, "#{body}-qa-who") == "You answered 1 hour ago"

      assert text(html, "#work-item-explore-earlier-rn_01aa40b29e71c6d3-body-h") ==
               "Qory's question, and the answer"
    end

    test "the note, while the repository keeps its tickets out of the Backlog, without Take in again" do
      html = tab(used_item(), can_act: true, backlog_off: true)

      assert text(html, "#work-item-explore-limit") ==
               "This take in has used its 3 runs, so Qory runs no more for these questions here."

      one = used_item(:used_up, %{run: %{used_item().run | attempt: 1, of: 1}})

      assert text(tab(one, can_act: true, backlog_off: true), "#work-item-explore-limit") ==
               "This take in has used its 1 run, so Qory runs no more for these questions here."
    end

    test "declined at Explore: the last questions read-only, no note" do
      w = used_item(:declined, %{stage: :explore, ended_by: @dana, ended_at: ago(5)})
      html = tab(w, can_act: true)
      assert count(html, "#work-item-explore-limit") == 0
      assert count(html, "textarea") == 0
      assert text(html, "#work-item-explore-questions-h") == "Qory's question"
    end

    test "an earlier run that proposed, or gave no result, says so in its fold" do
      proposed = run(%{id: "rn_01a8d4f16b2e70c8", ended_at: ago(4 * 86_400)})
      lost = run(%{id: "rn_01aa5a71e3d06b29", state: :lost, outcome: nil, ended_at: ago(21 * 60)})
      html = tab(used_item(), earlier_runs: [proposed, lost])

      assert texts(html, "#work-item-explore-earlier summary .q-xp-it:nth-child(4)") ==
               ["Proposed how to build it", "Lost"]

      assert text(html, "#work-item-explore-earlier-rn_01a8d4f16b2e70c8-body-h") ==
               "Qory's proposal"

      assert text(html, "#work-item-explore-earlier-rn_01aa5a71e3d06b29-body-h") ==
               "The run was lost."
    end
  end

  describe "explore_tab/1, a run without a result" do
    test "what happened, and the run's page" do
      for {status, overrides, run_state, heading, body} <- [
            {:no_result, %{state: :failed, outcome: :error, end_cause: :run_ended}, "Failed",
             "The run ended with an error.",
             "Its last result was an error, so there is nothing for Qory to show or for a member to confirm."},
            {:no_result, %{outcome: :none}, "Completed", "The run ended without a result.",
             "It sent no result, so there is nothing for Qory to show or for a member to confirm."},
            {:no_result, %{outcome: :refused}, "Completed",
             "The run's result did not pass Qory's check.",
             "Qory reads a result only in the format Explore uses, and at most 128 KiB. This one was not, so Qory does not show it."},
            {:lost, %{state: :lost, outcome: nil}, "Lost", "The run was lost.",
             "No exit or outcome was recorded before it was marked lost. There is nothing for Qory to show or for a member to confirm."},
            {:cancelled, %{state: :cancelled, outcome: nil}, "Cancelled",
             "The run was cancelled.",
             "It was cancelled before it ended. There is nothing for Qory to show or for a member to confirm."}
          ] do
        r =
          run(Map.merge(%{proposal: nil, ended_at: ago(3600), duration: "4 minutes"}, overrides))

        html = tab(work_item(%{number: 97, status: status, run: r}))

        assert Enum.at(items(html, "work-item-explore-run"), 2) == run_state
        assert text(html, "#work-item-explore-none-h") == heading

        assert texts(html, "#work-item-explore-none p") == [
                 heading,
                 body,
                 "The run's page, rn_01a97b20, shows what it did."
               ]

        assert attr(html, "#work-item-explore-none a", "href") == [
                 "/8wonders/main/runs/rn_01a97b20c4e81f3d"
               ]
      end
    end

    test "a run that ended at its handover, before it started: what to fix and why, here and in the folds" do
      for {cause, body} <- [
            {:variables_invalid,
             "Fix the variables in the workspace's settings, then run Explore again. One of the run's variables breaks a variable rule."},
            {:ticket_gone,
             "Take the ticket in again from the Backlog, if it is still there. The work item's ticket is no longer in Qory Apiary."},
            {:inputs_invalid,
             "Shorten or correct the ticket, then run Explore again. A value in the ticket or the work item breaks a rule for the agent's input, such as the size limit."},
            # A software workspace's word for the target.
            {:build_failed,
             "Check why the build failed on the repository's page, then start the run again. The run did not start because Qory Apiary could not build its environment image."}
          ] do
        r =
          run(%{
            id: nil,
            path: nil,
            state: :failed,
            outcome: :error,
            end_cause: cause,
            proposal: nil,
            started_at: nil,
            ended_at: ago(3600),
            duration: nil
          })

        words = ["The run ended before it started.", body]

        html = tab(work_item(%{number: 97, status: :no_result, run: r}))
        assert text(html, "#work-item-explore-none-h") == "The run ended before it started."
        assert texts(html, "#work-item-explore-none p") == words
        assert count(html, "#work-item-explore-none a") == 0

        earlier =
          tab(work_item(%{number: 97, status: :queued, run: %{attempt: 2, of: 3}}),
            earlier_runs: [r]
          )

        assert texts(earlier, "#work-item-explore-earlier-run-1-body p") == words

        take_in = %{
          taken_in_by: @dana,
          taken_in_at: ~U[2026-10-16 15:20:00Z],
          ended: :declined,
          ended_by: @dana,
          ended_at: ago(4 * 60),
          runs: [r]
        }

        taken =
          tab(work_item(%{number: 97, status: :queued, run: %{attempt: 1, of: 3}}),
            earlier_take_ins: [take_in]
          )

        assert texts(taken, "#work-item-explore-take-ins-1-run-1-body p") == words

        for html <- [html, earlier, taken] do
          refute html =~ "ended with an error"
          refute html =~ "Its last result was an error"
        end
      end
    end

    test "a run whose last result was an error keeps its words, here and in the folds" do
      r =
        run(%{
          state: :failed,
          outcome: :error,
          end_cause: :run_ended,
          proposal: nil,
          ended_at: ago(3600)
        })

      words = [
        "The run ended with an error.",
        "Its last result was an error, so there is nothing for Qory to show or for a member to confirm."
      ]

      html = tab(work_item(%{number: 97, status: :no_result, run: r}))
      assert texts(html, "#work-item-explore-none p") |> Enum.take(2) == words

      earlier =
        tab(work_item(%{number: 97, status: :queued, run: %{attempt: 2, of: 3}}),
          earlier_runs: [r]
        )

      assert texts(earlier, "#work-item-explore-earlier-rn_01a97b20c4e81f3d-body p")
             |> Enum.take(2) == words

      for html <- [html, earlier] do
        refute html =~ "The run ended before it started."
      end
    end

    test "the run line's time: lost and cancelled" do
      lost = run(%{state: :lost, outcome: nil, ended_at: ago(21 * 60)})
      html = tab(work_item(%{status: :lost, run: lost}))
      assert List.last(items(html, "work-item-explore-run")) == "lost 21 minutes ago"

      cancelled = run(%{state: :cancelled, outcome: nil, ended_at: ago(30 * 60)})
      html = tab(work_item(%{status: :cancelled, run: cancelled}))
      assert List.last(items(html, "work-item-explore-run")) == "cancelled 30 minutes ago"
    end
  end

  describe "explore_tab/1, earlier take ins" do
    test "each folded: who took it in, how it ended, its runs, which counted apart" do
      take_in = %{
        taken_in_by: @dana,
        taken_in_at: ~U[2026-10-16 15:20:00Z],
        ended: :declined,
        ended_by: @dana,
        ended_at: ago(4 * 60),
        runs: [run1_answered(), run2_answered(), run(%{id: "rn_01aa47c9b05e3f18", attempt: 3})]
      }

      w = work_item(%{number: 94, status: :queued, run: %{attempt: 1, of: 3}})
      html = tab(w, earlier_take_ins: [take_in])

      assert text(html, "#work-item-explore-take-ins-h") == "Earlier take ins"

      assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
               ["Taken in 16 Oct by you", "Declined by you 4 minutes ago", "3 runs"]

      assert text(html, "#work-item-explore-take-ins-1 .q-xp-inner > p:first-child") ==
               "Its runs counted apart from this take in."

      assert texts(html, "#work-item-explore-take-ins-1 .q-xp-run > span:first-child") ==
               ["Run 1 of 3", "Run 2 of 3", "Run 3 of 3"]
    end

    test "every end, in both forms, and one run" do
      for {ended, by, words} <- [
            {:declined, @priya, "Declined by Priya 4 minutes ago"},
            {:closed, @dana, "Closed by you 4 minutes ago"},
            {:closed, @priya, "Closed by Priya 4 minutes ago"},
            {:undone, @dana, "Undone by you 4 minutes ago"},
            {:undone, @priya, "Undone by Priya 4 minutes ago"}
          ] do
        take_in = %{
          taken_in_by: @lea,
          taken_in_at: ~U[2026-10-13 10:11:00Z],
          ended: ended,
          ended_by: by,
          ended_at: ago(4 * 60),
          runs: [run(%{})]
        }

        html =
          tab(work_item(%{status: :queued, run: %{attempt: 1, of: 3}}),
            earlier_take_ins: [take_in]
          )

        assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
                 ["Taken in 13 Oct by Lea", words, "1 run"]
      end
    end
  end

  ## The edit page

  defp edit(extra \\ []) do
    render_component(
      &C.proposal_edit/1,
      Keyword.merge(
        [number: 88, proposal: proposal(), explore_path: "/8wonders/main/work/88/explore"],
        extra
      )
    )
  end

  describe "proposal_edit/1" do
    test "its heading, its line, the fields from the run's words, and its foot" do
      html = edit()

      assert C.edit_title(88) == "Change Qory's proposal · #88"
      assert text(html, "#work-item-edit-back") == "Explore"
      assert attr(html, "#work-item-edit-back", "href") == ["/8wonders/main/work/88/explore"]
      assert text(html, "h2") == "Change Qory's proposal"

      assert text(html, ".q-xp-lead") ==
               "Change what Qory got wrong, then confirm. Qory's words stay in the Explore tab beside yours."

      assert attr(html, "form", "phx-submit") == ["confirm_changes"]
      assert attr(html, "form", "phx-change") == ["change_proposal"]
      assert attr(html, "form", "novalidate") == [""]
      assert attr(html, "form input[type=hidden]", "value") == ["88"]

      assert attr(html, "#work-item-edit-complexity", "role") == ["group"]
      assert text(html, "#work-item-edit-complexity-l") == "Complexity"

      assert texts(html, "label") ==
               ["Level", "Why", "Understanding", "In scope", "Out of scope", "Approach"]

      assert texts(html, "#work-item-edit-level option") == ["Simple", "Standard", "Complex"]
      assert attr(html, "#work-item-edit-level option[selected]", "value") == ["standard"]

      assert attr(html, "textarea", "name") ==
               ["complexity[reason]", "understanding", "scope_in", "scope_out", "approach"]

      assert text(html, "#work-item-edit-scope-in-hint") == "One line for each."

      assert text(html, "#work-item-edit-scope-out-hint") ==
               "One line for each. Leave it empty when nothing is left out."

      assert attr(html, "#work-item-edit-scope-in", "aria-describedby") ==
               ["work-item-edit-scope-in-hint"]

      assert count(html, ".badge") == 0

      assert text(html, ".q-xp-kept") ==
               "The approaches Qory did not choose, and what it learned, stay as Qory wrote them."

      assert text(html, ".q-xp-foot > p") == "Confirming makes work item #88 ready for Shape."
      assert text(html, "#work-item-edit-go") == "Confirm with your changes"
      assert attr(html, "#work-item-edit-go", "type") == ["submit"]
      assert text(html, "#work-item-edit-cancel") == "Cancel"
      assert attr(html, "#work-item-edit-cancel", "href") == ["/8wonders/main/work/88/explore"]
    end

    test "a scope entry is one line: its line breaks show as spaces" do
      html = edit(proposal: proposal(%{scope_in: ["One entry\nover two lines.", "Another."]}))

      [area] = html |> query("#work-item-edit-scope-in") |> Enum.to_list()
      assert LazyHTML.text(area) == "One entry over two lines.\nAnother."
    end

    test "a field the member changed says Changed, in its description" do
      html =
        edit(
          values: %{
            approach: "Extract the rounding, half to even.",
            scope_out: "Totals of orders already placed.\nThe mobile apps.",
            scope_in:
              "  Compute the basket's total as the order service does.\n\nMove that rounding into one function.  "
          }
        )

      assert text(html, "#work-item-edit-approach-ch") == "Changed"

      assert attr(html, "#work-item-edit-approach", "aria-describedby") == [
               "work-item-edit-approach-ch"
             ]

      assert attr(html, "#work-item-edit-scope-out", "aria-describedby") ==
               ["work-item-edit-scope-out-hint work-item-edit-scope-out-ch"]

      assert count(html, "#work-item-edit-scope-in-ch") == 0
      assert count(html, "#work-item-edit-understanding-ch") == 0
      assert count(html, "#work-item-edit-complexity-ch") == 0

      level = edit(values: %{level: "complex"})
      assert text(level, "#work-item-edit-complexity-ch") == "Changed"

      assert attr(level, "#work-item-edit-level", "aria-describedby") == [
               "work-item-edit-complexity-ch"
             ]

      assert attr(level, "#work-item-edit-level option[selected]", "value") == ["complex"]
    end

    test "an error under its field, describing it, and the focus on the first field at fault" do
      html = edit(values: %{approach: ""}, errors: %{approach: :blank})

      assert text(html, "#work-item-edit-approach-err") == "Write the approach."
      assert attr(html, "#work-item-edit-approach", "aria-invalid") == ["true"]

      assert attr(html, "#work-item-edit-approach", "aria-describedby") ==
               ["work-item-edit-approach-ch work-item-edit-approach-err"]

      assert attr(html, "#work-item-edit-focus-0-approach", "phx-mounted") |> hd() =~
               "#work-item-edit-approach"

      first = edit(errors: %{approach: :blank, understanding: :blank})
      assert count(first, "#work-item-edit-focus-0-understanding") == 1
      assert count(first, "#work-item-edit-focus-0-approach") == 0
    end

    test "every error's words" do
      for {field, error, words} <- [
            {:understanding, :blank, "Write the understanding."},
            {:scope_in, :blank, "Write at least one line in scope."},
            {:reason, :blank, "Write why the work is at this level."},
            {:scope_in, {:line_too_long, 2000}, "Write each line in at most 2,000 characters."},
            {:understanding, {:too_long, 20_000},
             "Write the understanding in at most 20,000 characters."},
            {:approach, {:too_long, 2000}, "Write at most 2,000 characters."},
            {:scope_out, {:too_many_lines, 50}, "Write at most 50 lines."},
            {:scope_out, {:too_many_lines, 1}, "Write at most 1 line."}
          ] do
        html = edit(errors: %{field => error})
        assert text(html, ".q-xp-err") == words
      end
    end
  end

  ## The Thread

  defp event(extra) do
    render_component(
      &C.thread_event/1,
      Keyword.merge(
        [id: "ev-1", at: ~U[2026-10-14 11:25:00Z], integration: "GitHub", now: @now],
        extra
      )
    )
  end

  defp line(html), do: text(html, "li > div > p:first-child")

  describe "thread_event/1, Explore's lines" do
    test "a run starts: first, with the answers, again; its place beside it; Qory's bee" do
      r = run(%{attempt: 2})

      for {start, words} <- [
            {nil, "Qory started Explore in run rn_01a97b20"},
            {:answers, "Qory started Explore again, with the answers, in run rn_01a97b20"},
            {:again, "Qory started Explore again in run rn_01a97b20"}
          ] do
        html = event(kind: :started, run: r, start: start)
        assert line(html) == words <> " Run 2 of 3 14 Oct, 11:25"
        assert text(html, ".q-wi-tag") == "Run 2 of 3"
        assert attr(html, "p a", "href") == ["/8wonders/main/runs/rn_01a97b20c4e81f3d"]
        assert count(html, ".q-wi-ev-ic .q-bl-bee") == 1
      end
    end

    test "Qory asked: how many and after how long, the questions quoted under it" do
      html = event(kind: :asked, questions: questions(), duration: "9 minutes")
      assert line(html) == "Qory asked 3 questions, after 9 minutes 14 Oct, 11:25"
      assert texts(html, "#ev-1-questions li") == Enum.map(questions(), & &1.text)

      one = event(kind: :asked, questions: [hd(questions())], duration: "8 minutes")
      assert line(one) == "Qory asked 1 question, after 8 minutes 14 Oct, 11:25"
    end

    test "answered: who, each question and its answer quoted" do
      qs = questions(@answers)

      html = event(kind: :answered, actor: @priya, questions: qs)
      assert line(html) == "Priya answered Qory's questions 14 Oct, 11:25"
      assert texts(html, "#ev-1-answers .q-wi-qa-a") == @answers
      assert texts(html, "#ev-1-answers .q-wi-qa-q") == Enum.map(qs, & &1.text)

      mine = event(kind: :answered, actor: @dana, questions: [hd(qs)])
      assert line(mine) == "You answered Qory's question 14 Oct, 11:25"

      one = event(kind: :answered, actor: @priya, questions: [hd(qs)])
      assert line(one) == "Priya answered Qory's question 14 Oct, 11:25"
    end

    test "proposed: after how long, and whose turn; only how long without an owner" do
      assert line(event(kind: :proposed, owner: @dana, duration: "11 minutes")) ==
               "Qory proposed how to build it, after 11 minutes. It waits for you to confirm 14 Oct, 11:25"

      assert line(event(kind: :proposed, owner: @lea, duration: "7 minutes")) ==
               "Qory proposed how to build it, after 7 minutes. It waits for Lea to confirm 14 Oct, 11:25"

      assert line(event(kind: :proposed, owner: nil, duration: "7 minutes")) ==
               "Qory proposed how to build it, after 7 minutes. 14 Oct, 11:25"
    end

    test "a run without a result, lost or cancelled, with its mark" do
      r = run(%{})

      for {kind, outcome, words} <- [
            {:no_result, :error, "Run rn_01a97b20 ended with an error, so Explore has no result"},
            {:no_result, :none, "Run rn_01a97b20 ended without a result"},
            {:no_result, :refused,
             "Run rn_01a97b20 returned a result that did not pass Qory's check"},
            {:lost, :error, "Run rn_01a97b20 was lost before it ended, so Explore has no result"},
            {:cancelled, :error,
             "Run rn_01a97b20 was cancelled before it ended, so Explore has no result"}
          ] do
        html = event(kind: kind, run: r, outcome: outcome)
        assert line(html) == words <> " 14 Oct, 11:25"
        assert count(html, ".q-wi-ev-bad") == 1
      end
    end

    test "asked to explore again, confirmed, changed and confirmed" do
      for {extra, words} <- [
            {[kind: :explore_again, actor: @dana], "You asked Qory to explore again"},
            {[kind: :explore_again, actor: @priya], "Priya asked Qory to explore again"},
            {[kind: :confirmed, actor: @dana], "You confirmed Qory's proposal. Ready for Shape"},
            {[kind: :confirmed, actor: @priya],
             "Priya confirmed Qory's proposal. Ready for Shape"},
            {[kind: :confirmed, actor: @dana, changed: true],
             "You changed Qory's proposal and confirmed it. Ready for Shape"},
            {[kind: :confirmed, actor: @priya, changed: true],
             "Priya changed Qory's proposal and confirmed it. Ready for Shape"}
          ] do
        assert line(event(extra)) == words <> " 14 Oct, 11:25"
      end
    end

    test "taken in again: the five whole sentences, the key beside its mark" do
      for {actor, owner, words} <- [
            {@dana, @dana, "You took this in again from G #1240"},
            {@priya, @priya, "Priya took this in again from G #1240"},
            {@dana, @priya, "You took this in again from G #1240. Priya owns it"},
            {@priya, @dana, "Priya took this in again from G #1240. You own it"},
            {@priya, @lea, "Priya took this in again from G #1240. Lea owns it"}
          ] do
        html =
          event(
            kind: :taken_in,
            again: true,
            actor: actor,
            owner: owner,
            key: "#1240"
          )

        assert line(html) |> String.replace(~r/\s+\./, ".") == words <> " 14 Oct, 11:25"
        assert attr(html, ".q-wi-ev-ref .q-bl-tile", "aria-label") == ["GitHub"]
      end
    end

    test "declined at Explore" do
      assert line(event(kind: :declined, stage: :explore, actor: @dana)) ==
               "You declined this work item at Explore 14 Oct, 11:25"

      assert line(event(kind: :declined, stage: :explore, actor: @priya)) ==
               "Priya declined this work item at Explore 14 Oct, 11:25"
    end
  end

  ## Ids

  test "no DOM id, phx-value or path holds the ticket's ref or a source's; runs are rn_" do
    w94 =
      work_item(%{
        number: 94,
        status: :questions,
        external_ref: "123456#94",
        key: "#1240",
        run: run1_answered()
      })

    html =
      Enum.join([
        card(work_item(%{}),
          explore_path: "/8wonders/main/work/88/explore",
          edit_path: "/8wonders/main/work/88/explore/edit"
        ),
        card(work_item(%{status: :no_result, run: run(%{outcome: :error})})),
        card(
          work_item(%{
            status: :used_up,
            run: run(%{attempt: 3, outcome: :questions, questions: questions()})
          }),
          can_close: true
        ),
        card(w94, explore_path: "/8wonders/main/work/94/explore"),
        tab(work_item(%{})),
        tab(%{w94 | run: %{run1_answered() | answered_by: nil}},
          can_act: true,
          errors: %{"qq_01" => :blank}
        ),
        tab(work_item(%{status: :running, run: run(%{attempt: 3, state: :running})}),
          earlier_runs: [run1_answered(), run2_answered()],
          earlier_take_ins: [
            %{
              taken_in_by: @dana,
              taken_in_at: ago(86_400),
              ended: :declined,
              ended_by: @dana,
              ended_at: ago(60),
              runs: [run(%{})]
            }
          ]
        ),
        edit(errors: %{approach: :blank}),
        event(kind: :started, run: run(%{})),
        event(
          kind: :taken_in,
          again: true,
          actor: @dana,
          owner: @dana,
          key: "#1240",
          url: "https://example.com/acme/shop/issues/1240"
        ),
        event(kind: :answered, actor: @dana, questions: questions(@answers))
      ])

    values =
      for node <- query(html, "*"),
          {name, value} <- node |> LazyHTML.attributes() |> List.first([]),
          name in ["id", "href", "name", "for", "aria-controls", "aria-describedby"] or
            String.starts_with?(name, "phx-value-"),
          do: {name, value}

    # The ticket's ref at the source is drawn nowhere, as text or as a value.
    refute html =~ "123456"

    assert Enum.any?(values, &match?({"phx-value-number", "88"}, &1))
    assert Enum.any?(values, &match?({"phx-value-number", "94"}, &1))
    assert Enum.any?(values, &match?({"name", "answers[qq_01]"}, &1))
    assert Enum.any?(values, &match?({"id", "work-item-explore-earlier-rn_01aa1f3e5c0d82a4"}, &1))

    for {name, value} <- values do
      refute value =~ "acme/shop#", "#{name}=#{value}"
      refute value =~ "%23", "#{name}=#{value}"

      if value =~ ~r/1204|1240/,
        do:
          assert(
            {name, value} == {"href", "https://example.com/acme/shop/issues/1240"},
            "#{name}=#{value}"
          )

      if name == "href" and value =~ "/runs/",
        do: assert(value =~ ~r"/runs/rn_[0-9a-f]{16}\z", value)

      if name == "href" and not String.starts_with?(value, "/"),
        do: assert(value =~ ~r{\Ahttps://}, value)
    end
  end

  ## The last run of the take in

  describe "the take in's last run" do
    defp last(status, overrides) do
      r =
        run(
          Map.merge(
            %{
              id: "rn_01aa47c9b05e3f18",
              path: "/8wonders/main/runs/rn_01aa47c9b05e3f18",
              attempt: 3,
              proposal: nil,
              ended_at: ago(8 * 60)
            },
            overrides
          )
        )

      work_item(%{number: 94, status: status, run: r})
    end

    test "the run limit after a run without a result: no note over questions that are not there" do
      for overrides <- [
            %{state: :lost, outcome: nil},
            %{state: :cancelled, outcome: nil},
            %{state: :failed, outcome: :error},
            %{outcome: :none}
          ] do
        html = tab(last(:used_up, overrides), can_act: true)
        assert count(html, "#work-item-explore-limit") == 0, inspect(overrides)
        assert count(html, "#work-item-explore-none") == 1, inspect(overrides)
        assert count(html, "#work-item-explore-questions") == 0, inspect(overrides)
      end

      asked = last(:used_up, %{outcome: :questions, questions: [hd(questions())]})
      assert count(tab(asked, can_act: true), "#work-item-explore-limit") == 1
    end

    test "no result at run 3 of 3 is the run-limit card: no Run Explore again, no run 4 of 3" do
      for {status, overrides} <- [
            {:no_result, %{state: :failed, outcome: :error}},
            {:lost, %{state: :lost, outcome: nil}},
            {:cancelled, %{state: :cancelled, outcome: nil}}
          ] do
        html = card(last(status, overrides), can_close: true)

        assert text(html, ".q-wi-badge") == "3 of 3 runs used"
        assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait"]

        assert text(html, "#work-item-step-line") ==
                 "Run rn_01aa47c9 was run 3 of 3, the most one take in has, and it ended without a result, so Qory cannot explore again in this take in."

        assert count(html, "#work-item-step-again") == 0
        assert count(html, "#work-item-step-next") == 0
        refute html =~ "run 4 of 3"
        assert text(html, "#work-item-step-close") == "Close work item…"

        tab = tab(last(status, overrides), can_act: true)
        assert count(tab, "#work-item-explore-limit") == 0
        assert count(tab, "#work-item-explore-none") == 1
      end
    end

    test "questions at run 3 of 3 are read-only under the note: no form, no run 4 of 3" do
      w = last(:questions, %{outcome: :questions, questions: [hd(questions())]})

      html = tab(w, can_act: true)
      assert count(html, "#work-item-explore-limit") == 1
      assert count(html, "form") == 0
      assert count(html, "#work-item-explore-questions-next") == 0
      refute html =~ "run 4 of 3"

      assert text(card(w), ".q-wi-badge") == "3 of 3 runs used"
    end

    test "at run 3 of 3 the header, the row, the stages and the card read the run limit alike" do
      for {status, overrides} <- [
            {:questions, %{outcome: :questions, questions: [hd(questions())]}},
            {:lost, %{state: :lost, outcome: nil}}
          ] do
        w = last(status, overrides)

        for {can_act, mark} <- [{true, "wait"}, {false, "wait_other"}] do
          header =
            render_component(&C.work_item_header/1,
              work_item: w,
              integration: "GitHub",
              link: "https://apiary.example.com/8wonders/main/work/94",
              can_act: can_act
            )

          assert text(header, ".q-wi-meta .q-wi-st") == "Explore used its 3 runs"
          assert attr(header, ".q-wi-meta .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{mark}"]

          row =
            render_component(&ApiaryWeb.WorkItemListComponents.work_item_row/1,
              id: "work-item-94",
              work_item: w,
              integration: "GitHub",
              navigate: "/8wonders/main/work/94",
              can_act: can_act,
              now: @now
            )

          assert text(row, ".q-wl-nx") == "Explore used its 3 runs"
          assert attr(row, ".q-wl-row .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{mark}"]

          card = card(w, can_act: can_act)
          assert attr(card, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{mark}"]
        end

        assert C.status_words(w) == "Explore used its 3 runs"
        assert count(render_component(&C.stage_track/1, work_item: w), ".q-wi-stage-wait") == 1
      end
    end

    test "below the limit, the next run is named" do
      html = card(last(:lost, %{attempt: 2, state: :lost, outcome: nil}))
      assert text(html, "#work-item-step-next") == "It starts run 3 of 3 of this take in."
      assert text(html, "#work-item-step-again") == "Run Explore again"
    end
  end

  ## A field's first line, missing keys, the focus

  describe "the fields and the run's words, robustly" do
    test "a value that starts with a line break keeps it in its field" do
      [answer] =
        tab(questions_item(), can_act: true, answers: %{"qq_01" => "\nWeb only."})
        |> query("#work-item-explore-questions-answer-qq_01")
        |> Enum.to_list()

      assert LazyHTML.text(answer) == "\nWeb only."

      html = edit(proposal: proposal(%{approach: "\nStarts after a line."}))
      [approach] = html |> query("#work-item-edit-approach") |> Enum.to_list()
      assert LazyHTML.text(approach) == "\nStarts after a line."
      assert count(html, "#work-item-edit-approach-ch") == 0

      [plain] = edit() |> query("#work-item-edit-approach") |> Enum.to_list()

      assert LazyHTML.text(plain) ==
               "Extract the order service's rounding into a function in the pricing module."
    end

    test "a proposal without Not chosen or knowledge says None; a fact without sources lists none" do
      p = proposal() |> Map.delete(:alternatives) |> Map.delete(:knowledge)
      html = tab(work_item(%{run: run(%{proposal: p})}))

      assert text(html, "#work-item-explore-proposal-alternatives li") == "None"
      assert text(html, "#work-item-explore-proposal-knowledge li") == "None"

      bare = proposal(%{knowledge: [%{text: "A fact."}]})
      html = tab(work_item(%{run: run(%{proposal: bare})}))
      assert text(html, "#work-item-explore-proposal-knowledge .q-xp-know > li") == "A fact."
      assert count(html, ".q-xp-src") == 0
    end

    test "an unknown complexity level shows no level word" do
      p = proposal(%{complexity: %{level: :huge, reason: "Why."}})
      html = tab(work_item(%{run: run(%{proposal: p})}))
      assert count(html, "#work-item-explore-proposal-complexity .badge") == 0
      assert text(html, "#work-item-explore-proposal-complexity .q-xp-val") == "Why."

      edit = edit(proposal: p)
      assert attr(edit, "#work-item-edit-level option[selected]", "value") == []
    end

    test "an error a field has no words for marks nothing" do
      for errors <- [%{scope_out: :blank}, %{approach: :unknown}] do
        html = edit(errors: errors)
        assert count(html, ".q-xp-err") == 0
        assert count(html, "[aria-invalid]") == 0
        assert count(html, "[phx-mounted]") == 0
      end
    end

    test "an answer error without words marks nothing" do
      html =
        tab(questions_item(), can_act: true, errors: %{"qq_01" => :unknown, "qq_02" => {:odd}})

      assert count(html, ".q-xp-err") == 0
      assert count(html, "[aria-invalid]") == 0
      assert count(html, "[phx-mounted]") == 0
    end

    test "the focus span is new after each send, so the focus moves again" do
      errors = %{"qq_02" => :blank}

      for submits <- [1, 2] do
        html = tab(questions_item(), can_act: true, errors: errors, submits: submits)
        assert count(html, "#work-item-explore-questions-focus-#{submits}-qq_02") == 1

        edited = edit(errors: %{approach: :blank}, submits: submits)
        assert count(edited, "#work-item-edit-focus-#{submits}-approach") == 1
      end
    end
  end

  describe "a source's words for its items" do
    @bug %{one: "bug", other: "bugs"}

    test "Explore reads the item by its source's word, or the ticket where it names none" do
      queued = work_item(%{number: 341, status: :queued, run: %{attempt: 1, of: 3}})

      assert text(tab(queued, item_noun: @bug), "#work-item-explore-wait p:last-child") ==
               "Qory starts run 1 of 3 when the workspace's node pool takes it. It reads the bug and the code, and proposes how to build it, or asks what it needs to know."

      asked =
        work_item(%{
          number: 94,
          status: :questions,
          run: run(%{outcome: :questions, questions: questions()})
        })

      assert tab(asked, can_act: true, item_noun: @bug) =~
               "Qory runs Explore again from the start, with the bug, its comments, the first instruction and the answers of this take in. It is run 2 of 3."

      assert tab(asked, can_act: true) =~
               "Qory runs Explore again from the start, with the ticket, its comments, the first instruction and the answers of this take in. It is run 2 of 3."

      running = run(%{state: :running, outcome: nil, ended_at: nil, answers_by: []})

      assert text(
               card(work_item(%{status: :running, run: running}), item_noun: @bug),
               ".q-wi-bee-line"
             ) ==
               "Qory is exploring. It reads the bug and the code, and proposes how to build it."
    end
  end

  describe "a run that ended before its handover, with no id" do
    defp unhanded(overrides),
      do: run(Map.merge(%{id: nil, path: nil, proposal: nil, ended_at: ago(3600)}, overrides))

    test "the step card and the tab name no run, and keep what to do" do
      for {status, overrides} <- [
            {:no_result, %{state: :failed, outcome: :error}},
            {:lost, %{state: :lost, outcome: nil}},
            {:cancelled, %{state: :cancelled, outcome: nil}}
          ] do
        w = work_item(%{number: 97, status: status, run: unhanded(overrides)})

        html = card(w)
        assert count(html, "#work-item-step-line") == 0
        assert text(html, "#work-item-step-again") == "Run Explore again"
        refute html =~ "n/a"

        tab = tab(w)
        assert count(tab, "#work-item-explore-none a") == 0
        refute tab =~ "The run's page"
        refute tab =~ "n/a"
      end

      used =
        card(
          work_item(%{
            number: 94,
            status: :used_up,
            run: unhanded(%{attempt: 3, state: :failed, outcome: :error})
          }),
          can_close: true
        )

      assert count(used, "#work-item-step-line") == 0
      assert count(used, "#work-item-step-close") == 1
    end

    test "an earlier run without an id is named by its place, with no id" do
      lost = unhanded(%{attempt: 1, state: :lost, outcome: nil})
      w = work_item(%{number: 94, status: :queued, run: %{attempt: 2, of: 3}})
      html = tab(w, earlier_runs: [lost])

      assert count(html, "#work-item-explore-earlier-run-1") == 1
      assert count(html, "#work-item-explore-earlier-run-1 summary .q-mono") == 0
      refute html =~ "n/a"
    end

    test "the Thread draws no line for it" do
      for kind <- [:started, :no_result, :lost, :cancelled] do
        assert event(kind: kind, run: unhanded(%{})) == ""
      end
    end
  end

  describe "an earlier take in closed by the instance" do
    defp closed_take_in(reason) do
      %{
        taken_in_by: @lea,
        taken_in_at: ~U[2026-10-13 10:11:00Z],
        ended: :closed,
        ended_by: nil,
        ended_reason: reason,
        ended_at: ago(4 * 60),
        runs: [run(%{})]
      }
    end

    test "says its integration was removed, or nothing for a reason without words" do
      w = work_item(%{status: :queued, run: %{attempt: 1, of: 3}})

      html = tab(w, earlier_take_ins: [closed_take_in(:adapter_removed)])

      assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
               [
                 "Taken in 13 Oct by Lea",
                 "Closed 4 minutes ago, when its integration was removed",
                 "1 run"
               ]

      for reason <- [nil, :unknown] do
        html = tab(w, earlier_take_ins: [closed_take_in(reason)])

        assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
                 ["Taken in 13 Oct by Lea", "1 run"]
      end
    end
  end

  describe "the fields' length in the browser" do
    test "each takes twice what the server takes" do
      asked =
        work_item(%{
          number: 94,
          status: :questions,
          run: run(%{outcome: :questions, proposal: nil, questions: questions()})
        })

      html = tab(asked, can_act: true)
      assert attr(html, "textarea", "maxlength") == ["4000", "4000", "4000"]

      edited = edit()

      lengths =
        edited
        |> query("textarea")
        |> Enum.map(
          &{hd(LazyHTML.attribute(&1, "name")), hd(LazyHTML.attribute(&1, "maxlength"))}
        )

      assert lengths == [
               {"complexity[reason]", "4000"},
               {"understanding", "40000"},
               {"scope_in", "200100"},
               {"scope_out", "200100"},
               {"approach", "4000"}
             ]
    end
  end
end
