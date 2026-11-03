defmodule ApiaryWeb.WorkItemExploreTest do
  @moduledoc """
  Explore's parts of a work item's page (`ApiaryWeb.WorkItemComponents`): the statuses and
  marks Explore adds, the step card in each Explore state, a take in again's undo, the
  tabs, Explore's tab in each state, the questions form with its options, the proposal
  with its comments, its field and its one button, and Explore's lines in the Thread. Every
  DOM id, `phx-value-*` and path is Qory Apiary's: runs by their number, questions by
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

  @message """
  ## What this is

  Checkout totals are a cent off when a discount applies.

  ## How Qory would do it

  - Extract the order service's rounding into one function.
  - Use it in the basket.

  Source: [the pricing notes](https://docs.example.org/pricing)
  """

  defp proposal(overrides \\ %{}), do: Map.merge(%{message: @message}, overrides)

  defp run(overrides) do
    Map.merge(
      %{
        id: "rn_01a97b20c4e81f3d",
        number: 12,
        path: "/8wonders/main/runs/12",
        attempt: 1,
        of: 3,
        state: :completed,
        started_at: ago(3 * 86_400 - 60),
        ended_at: ~U[2026-10-14 11:36:00Z],
        duration: "11 minutes",
        outcome: :proposal,
        proposal: proposal(),
        version: 1,
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
      %{public_id: "qq_0#{i}", text: text, options: [], answer: answer, custom: answer && true}
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
      number: 13,
      path: "/8wonders/main/runs/13",
      attempt: 1,
      outcome: :questions,
      proposal: nil,
      questions: questions(@answers),
      ended_at: ago(18 * 3600 + 29 * 60),
      answered_by: @dana,
      answered_at: ago(62 * 60)
    })
  end

  defp run2_answered do
    run(%{
      id: "rn_01aa40b29e71c6d3",
      number: 14,
      path: "/8wonders/main/runs/14",
      attempt: 2,
      outcome: :questions,
      proposal: nil,
      questions: [
        %{
          public_id: "qq_04",
          text: "Should the receipt change to the new order?",
          options: [],
          answer: "Change it: the discount first, then the gift card.",
          custom: true
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
            {:questions, "Needs answers", "wait", "wait_other"},
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

        assert text(html, ".q-wi-meta .q-wi-st") == "Needs answers"
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

    test "closed at Explore: no current step, nothing done" do
      w = work_item(%{status: :closed, stage: :explore, ended_by: @dana})
      html = render_component(&C.stage_track/1, work_item: w)
      assert count(html, "[aria-current]") == 0
      assert count(html, ".q-wi-stage-done") == 0
      assert text(html, ".q-wi-end") == "Closed"
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

    test "after a close: it goes back to how it ended, and nothing is sent" do
      for {previous, by, line} <- [
            {:closed, @dana,
             "You took this in again just now. Until a run starts, you can undo the take in: the work item goes back to closed, and Qory changes nothing on the ticket."},
            {:closed, @priya,
             "Priya took this in again just now. Until a run starts, you can undo the take in: the work item goes back to closed, and Qory changes nothing on the ticket."}
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
             "You took this in just now. Until a run starts, you can undo the take in: Qory removes its label from the ticket and leaves its comment."},
            {@priya,
             "Priya took this in just now. Until a run starts, you can undo the take in: Qory removes its label from the ticket and leaves its comment."}
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
               "You undid the take in just now, before a run started."

      assert text(html, ".q-wi-grow > p:last-child") ==
               "Qory removed its label from the ticket and left its comment. To bring the work item back, use Take in again."
    end

    test "without the right to undo: who took it in again and when, and no Undo" do
      for {previous, by, line} <- [
            {:closed, @dana, "You took this in again just now."},
            {:closed, @priya, "Priya took this in again just now."}
          ] do
        html = again(by, previous: previous, can_undo: false)
        assert text(html, "#work-item-step-undo-line") == line
        assert count(html, "#work-item-step-undo button") == 0
      end
    end

    test "after the uninstall, a take in again reads the built uninstall line" do
      html = again(@dana, previous: :closed, uninstalled: true)

      assert text(html, "#work-item-step-undo-line") ==
               "You took this in just now. Until a run starts, you can undo the take in. GitHub is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment."
    end
  end

  describe "step_card/1, Explore queued and running, a later run" do
    test "queued with answers: whose answers it reads, which run, and no Undo" do
      for {people, line} <- [
            {[@dana],
             "When the run starts, Qory explores the ticket and your answers, and writes a proposal for the work."},
            {[@priya],
             "When the run starts, Qory explores the ticket and the answers of Priya, and writes a proposal for the work."},
            {[@dana, @priya],
             "When the run starts, Qory explores the ticket and the answers of this take in, and writes a proposal for the work."},
            {[@priya, %{@priya | name: "Priya"}],
             "When the run starts, Qory explores the ticket and the answers of Priya, and writes a proposal for the work."},
            {[],
             "When the run starts, Qory explores the ticket and writes a proposal for the work."}
          ] do
        w = work_item(%{status: :queued, run: %{attempt: 2, of: 3, answers_by: people}})
        html = card(w, can_undo: true)

        assert text(html, ".q-wi-badge") == "Queued"
        assert text(html, ".q-wi-bee-line") == line
        assert text(html, "#work-item-step-run") == "Attempt 2 of 3 is queued."
        assert count(html, "#work-item-step-undo") == 0
        assert count(html, "button") == 0
      end
    end

    test "running n of 3: whose answers it reads, and its run by its number" do
      for {people, line} <- [
            {[@dana], "Qory reads the ticket and your answers, and writes a proposal."},
            {[@dana, @priya],
             "Qory reads the ticket and the answers of this take in, and writes a proposal."}
          ] do
        r =
          run(%{
            id: "rn_01aa47c9b05e3f18",
            number: 15,
            path: "/8wonders/main/runs/15",
            attempt: 3,
            state: :running,
            started_at: ago(120),
            answers_by: people
          })

        html = card(work_item(%{status: :running, run: r}))
        assert text(html, ".q-wi-bee-line") == line
        assert text(html, "#work-item-step-run") == "Attempt 3 started 2 minutes ago."

        assert attr(html, "#work-item-step-run a", "href") == [
                 "/8wonders/main/runs/15"
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

    test "a member who may act: the badge, the line, and the link to Explore" do
      html = asked(3, explore_path: "/8wonders/main/work/94/explore")

      assert text(html, "h2") == "Explore"
      assert text(html, ".q-wi-badge") == "Needs answers"
      assert count(html, ".q-wi-step-ask") == 1
      assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait"]

      assert text(html, ".q-wi-bee-line") ==
               "Answer Qory's 3 questions, and Explore runs again with your answers."

      assert text(html, "#work-item-step-explore") == "Answer the questions"
      assert attr(html, "#work-item-step-explore", "href") == ["/8wonders/main/work/94/explore"]
      assert count(html, "button") == 0
    end

    test "one question; on Explore's tab, no link" do
      html = asked(1)

      assert text(html, ".q-wi-bee-line") ==
               "Answer Qory's question, and Explore runs again with your answer."

      assert count(html, "#work-item-step-explore") == 0

      linked = asked(1, explore_path: "/8wonders/main/work/94/explore")
      assert text(linked, "#work-item-step-explore") == "Answer the question"
    end

    test "a reader who may not act: what Qory asked, that it waits for a member, no button" do
      for {n, line, waits} <- [
            {3, "Qory returned 3 questions instead of a proposal.",
             "Next, a member answers Qory's questions."},
            {1, "Qory returned 1 question instead of a proposal.",
             "Next, a member answers Qory's question."}
          ] do
        html = asked(n, can_act: false, explore_path: "/8wonders/main/work/94/explore")
        assert text(html, ".q-wi-bee-line") == line
        assert text(html, "#work-item-step-waits") == waits
        assert text(html, ".q-wi-badge") == "Needs answers"
        assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait_other"]
        assert count(html, ".q-wi-step-ask") == 0
        assert count(html, "button") == 0
        assert count(html, "a") == 0
      end
    end
  end

  describe "step_card/1, a run without a result" do
    test "no result, lost, cancelled: the badge, what happened, Run Explore again" do
      for {status, overrides, badge, line} <- [
            {:no_result, %{state: :failed, outcome: :error}, "No result",
             "Attempt 1 ended with an error, so Explore has no result."},
            {:no_result, %{outcome: :none}, "No result", "Attempt 1 ended without a result."},
            {:no_result, %{outcome: :refused}, "No result",
             "Attempt 1 returned a result that did not pass Qory's check, so Explore has no result."},
            {:lost, %{state: :lost, outcome: nil}, "Lost",
             "Attempt 1 was lost before it ended, so Explore has no result."},
            {:cancelled, %{state: :cancelled, outcome: nil}, "Cancelled",
             "Attempt 1 was cancelled before it ended, so Explore has no result."}
          ] do
        r =
          run(
            Map.merge(
              %{id: "rn_01aa52d07c4a91e6", number: 16, path: "/8wonders/main/runs/16"},
              overrides
            )
          )

        html = card(work_item(%{number: 97, status: status, run: r}))

        assert text(html, ".q-wi-badge") == badge
        assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-err"]
        assert text(html, "#work-item-step-line") == line

        assert attr(html, "#work-item-step-line a", "href") == [
                 "/8wonders/main/runs/16"
               ]

        assert text(html, "#work-item-step-again") == "Run Explore again"
        assert attr(html, "#work-item-step-again", "phx-click") == ["explore_again"]
        assert attr(html, "#work-item-step-again", "phx-value-number") == ["97"]
        assert text(html, "#work-item-step-next") == "Run Explore again starts attempt 2 of 3."

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
              number: 15,
              path: "/8wonders/main/runs/15",
              attempt: 3,
              outcome: :questions,
              questions: [hd(questions())]
            },
            overrides
          )
        )

      card(work_item(%{number: 94, status: :used_up, run: r}), extra)
    end

    test "3 of 3 attempts used: why Qory cannot explore again, the way on, and Close" do
      html = used(%{}, can_close: true)

      assert text(html, ".q-wi-badge") == "3 of 3 attempts used"
      assert count(html, ".q-wi-step-ask") == 1

      assert text(html, "#work-item-step-line") ==
               "Qory still has 1 question after attempt 3 of 3, the last attempt of this take in."

      assert text(html, "#work-item-step-ways") ==
               "To explore again, close the work item and use Take in again in the Backlog: the run count starts again, without this take in's answers."

      assert text(html, "#work-item-step-close") == "Close work item…"
      assert attr(html, "#work-item-step-close", "phx-click") == ["ask_close"]
      assert attr(html, "#work-item-step-close", "phx-value-number") == ["94"]
      refute html =~ "Take in again</"
      refute html =~ "Run Explore again"
    end

    test "while the repository keeps its tickets out of the Backlog, the ways on say no Take in again" do
      html = used(%{}, can_close: true, backlog_off: true)

      assert text(html, "#work-item-step-ways") ==
               "Close the work item if it is not wanted."

      assert count(html, "#work-item-step-close") == 1
      refute html =~ "Take in again"
    end

    test "two questions left; the last run without a result" do
      two = used(%{questions: Enum.take(questions(), 2)})

      assert text(two, "#work-item-step-line") ==
               "Qory still has 2 questions after attempt 3 of 3, the last attempt of this take in."

      none = used(%{state: :failed, outcome: :error})

      assert text(none, "#work-item-step-line") ==
               "Attempt 3 ended without a result. That was attempt 3 of 3, the last attempt of this take in."
    end

    test "Close only with the right to close; a reader who may not act reads why, and nothing to do" do
      assert count(used(%{}, can_close: false), "#work-item-step-close") == 0

      reader = used(%{}, can_act: false, can_close: true)
      assert text(reader, "#work-item-step-line") =~ "Qory still has 1 question"
      assert count(reader, "#work-item-step-ways") == 0
      assert count(reader, "button") == 0
      assert attr(reader, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait_other"]
    end
  end

  describe "step_card/1, Confirm" do
    test "the line and Read Qory's proposal; no Confirm and no Change" do
      html = card(work_item(%{}), explore_path: "/8wonders/main/work/88/explore")

      assert text(html, ".q-wi-bee-line") ==
               "Confirm Qory's proposal, or write what to change."

      assert text(html, "#work-item-step-explore") == "Read Qory's proposal"
      assert attr(html, "#work-item-step-explore", "href") == ["/8wonders/main/work/88/explore"]
      assert count(html, "button") == 0
      assert count(html, ".q-wi-acts") == 0
      assert count(html, "#work-item-step-confirm, #work-item-step-change") == 0
      refute html =~ "/explore/edit"
    end

    test "on Explore's tab, no link; without the right to act, no link" do
      html = card(work_item(%{}))
      assert count(html, "#work-item-step-explore") == 0

      reader =
        card(work_item(%{owner: @priya}),
          can_act: false,
          explore_path: "/8wonders/main/work/88/explore"
        )

      assert count(reader, "a") == 0
      assert count(reader, "button") == 0
    end
  end

  ## The notice, the tabs

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

  describe "step_card/1, in an example workspace" do
    # An example workspace reads the source texts, as a software workspace does on these
    # lines.
    test "Explore reads the ticket and the answers, and proposes what to do" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@example", fn ->
        for {people, line} <- [
              {[],
               "When the run starts, Qory explores the ticket and writes a proposal for the work."},
              {[@dana],
               "When the run starts, Qory explores the ticket and your answers, and writes a proposal for the work."},
              {[@priya],
               "When the run starts, Qory explores the ticket and the answers of Priya, and writes a proposal for the work."},
              {[@dana, @priya],
               "When the run starts, Qory explores the ticket and the answers of this take in, and writes a proposal for the work."}
            ] do
          w = work_item(%{status: :queued, run: %{attempt: 2, of: 3, answers_by: people}})
          assert text(card(w), ".q-wi-bee-line") == line
        end

        assert text(asked(3), ".q-wi-bee-line") ==
                 "Answer Qory's 3 questions, and Explore runs again with your answers."

        assert text(asked(1, can_act: false), ".q-wi-bee-line") ==
                 "Qory returned 1 question instead of a proposal."

        assert text(card(work_item(%{})), ".q-wi-bee-line") ==
                 "Confirm Qory's proposal, or write what to change."
      end)
    end
  end

  describe "explore_tab/1, queued and running" do
    test "queued, the first run: Attempt 1 of 3, Queued, and what Qory does" do
      html = tab(work_item(%{number: 341, status: :queued, run: %{attempt: 1, of: 3}}))

      assert items(html, "work-item-explore-run") == ["Attempt 1 of 3", "Queued"]
      assert text(html, "#work-item-explore-wait-h") == "Explore is queued."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Qory starts attempt 1 of 3 when the workspace's pool takes it. It reads the ticket and proposes what to do, or asks what it needs to know."

      assert count(html, ".q-xp-frame") == 0
    end

    test "a pending run reads Queued too, with its id" do
      r = run(%{state: :pending, attempt: 1, ended_at: nil})
      html = tab(work_item(%{status: :queued, run: r}))
      assert items(html, "work-item-explore-run") == ["Attempt 1 of 3", "Queued"]
    end

    test "queued again with the reader's answers: the answers run 2 reads, grouped" do
      w = work_item(%{number: 94, status: :queued, run: %{attempt: 2, of: 3}})
      html = tab(w, earlier_runs: [run1_answered()])

      assert items(html, "work-item-explore-run") == ["Attempt 2 of 3", "Queued"]

      assert text(html, "#work-item-explore-wait-h") ==
               "Explore is queued again, with your answers."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Attempt 2 of 3 starts when the workspace's pool takes it. It reads the ticket and these answers, from the start."

      assert text(html, "#work-item-explore-read-h") == "Answers for attempt 2"

      assert text(html, "#work-item-explore-read .q-xp-cap") ==
               "These questions come from 1 earlier run of this take in."

      group = "#work-item-explore-read-13"
      assert text(html, "#{group}-h") == "Attempt 1 of 3"
      assert attr(html, "#{group}-h a", "href") == ["/8wonders/main/runs/13"]
      assert text(html, "#{group}-qa-who") == "You answered 1 hour ago"
      assert texts(html, "#{group} .q-xp-ans") == @answers
    end

    test "run 3 running, with two members' answers" do
      r =
        run(%{
          id: "rn_01aa47c9b05e3f18",
          number: 15,
          path: "/8wonders/main/runs/15",
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
               ["Attempt 3 of 3", "Running", "started 2 minutes ago"]

      assert attr(html, "#work-item-explore-run span.q-xp-run-on", "class") == ["q-xp-run-on"]

      assert text(html, "#work-item-explore-wait-h") ==
               "Explore is running again, with the answers of this take in."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Attempt 3 of 3 reads the ticket and these answers from the start, then returns a proposal or more questions."

      assert text(html, "#work-item-explore-read-h") == "Answers for attempt 3"

      assert text(html, "#work-item-explore-read .q-xp-cap") ==
               "These questions come from 2 earlier runs of this take in."

      assert texts(html, ".q-xp-grp .q-xp-who") ==
               ["You answered 1 hour ago", "Priya answered 20 minutes ago"]

      assert texts(html, "#work-item-explore-earlier summary") == [
               "Attempt 1 of 3 Wrote 3 questions Yesterday, 15:31",
               "Attempt 2 of 3 Wrote 1 question 50 minutes ago"
             ]
    end

    test "the first run running: no answers" do
      r = run(%{state: :running, started_at: ago(6 * 60), ended_at: nil})
      html = tab(work_item(%{status: :running, run: r}))

      assert text(html, "#work-item-explore-wait-h") == "Explore is running."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Attempt 1 of 3 reads the ticket, then returns a proposal or questions."

      assert count(html, "#work-item-explore-read") == 0
    end
  end

  describe "explore_tab/1, Qory's proposal" do
    test "the run line, the frame with its version, the Markdown, then the field and Confirm" do
      html = tab(work_item(%{}), can_act: true)

      assert items(html, "work-item-explore-run") ==
               ["Attempt 1 of 3", "Completed", "ended 3 days ago, after 11 minutes"]

      p = "#work-item-explore-proposal"
      assert text(html, "#{p}-h") == "Qory's proposal"
      assert count(html, "#{p} .q-xp-frame-h .badge") == 0
      assert text(html, "#{p} .q-xp-cap") == "Version 1. Attempt 1 wrote this."
      assert attr(html, "#{p} .q-xp-cap a", "href") == ["/8wonders/main/runs/12"]

      # The Markdown, its headings two levels down.
      assert texts(html, "#{p}-text h4") == ["What this is", "How Qory would do it"]

      assert texts(html, "#{p}-text li") == [
               "Extract the order service's rounding into one function.",
               "Use it in the basket."
             ]

      assert attr(html, "#{p}-text a", "href") == ["https://docs.example.org/pricing"]
      assert attr(html, "#{p}-text a", "target") == ["_blank"]
      assert attr(html, "#{p}-text a", "rel") == ["nofollow noopener noreferrer"]
      refute html =~ "plain text"
      refute html =~ "Show Qory's words"

      # In this order: the proposal, then the field and the one button.
      assert attr(html, "#work-item-explore > *", "id") == [
               "work-item-explore-run",
               "work-item-explore-proposal",
               "work-item-explore-reply"
             ]

      r = "#work-item-explore-reply"
      assert attr(html, r, "phx-change") == ["change_draft"]
      assert attr(html, r, "phx-submit") == ["send_change"]
      assert attr(html, "#{r} input[type=hidden]", "name") == ["number"]
      assert attr(html, "#{r} input[type=hidden]", "value") == ["88"]
      assert attr(html, "#{r} textarea", "name") == ["change"]
      assert attr(html, "#{r} textarea", "placeholder") == ["What should change?"]
      assert attr(html, "#{r} textarea", "aria-label") == ["What should change?"]
      assert text(html, "#{r} textarea") == ""
      assert count(html, "button") == 1
      assert text(html, "#{r}-go") == "Confirm"
      assert attr(html, "#{r}-go", "type") == ["submit"]
      assert count(html, "#work-item-explore-comments") == 0
    end

    test "with text in the field, the one button is Send change" do
      html = tab(work_item(%{}), can_act: true, change: "Also check the basket.")

      assert text(html, "#work-item-explore-reply textarea") == "Also check the basket."
      assert count(html, "button") == 1
      assert text(html, "#work-item-explore-reply-go") == "Send change"
    end

    test "a reader who may not act: the proposal, with no field and no button" do
      html = tab(work_item(%{}), can_act: false)

      assert text(html, "#work-item-explore-proposal-h") == "Qory's proposal"
      assert count(html, "form") == 0
      assert count(html, "textarea") == 0
      assert count(html, "button") == 0
    end

    test "comments: an open one, and done ones muted with a tick, then the field" do
      comments = [
        %{text: "Also check the basket.", by: @dana, version: 1, done_version: 2},
        %{text: "And the <b>sign-in</b>.", by: @priya, version: 2, done_version: 3},
        %{text: "Show it on the order\nconfirmation.", by: @dana, version: 3, done_version: nil}
      ]

      w = work_item(%{run: run(%{attempt: 3, version: 3})})
      html = tab(w, can_act: true, comments: comments)

      assert attr(html, "#work-item-explore > *", "id") == [
               "work-item-explore-run",
               "work-item-explore-proposal",
               "work-item-explore-comments",
               "work-item-explore-reply"
             ]

      c = "#work-item-explore-comments"
      assert text(html, "#{c}-h") == "Comments"

      assert text(html, "#work-item-explore-proposal .q-xp-cap") ==
               "Version 3. Attempt 3 wrote this."

      assert texts(html, "#{c} .q-xp-cm-t") ==
               [
                 "Also check the basket.",
                 "And the <b>sign-in</b>.",
                 "Show it on the order confirmation."
               ]

      assert texts(html, "#{c} .q-xp-cm-m") == [
               "You, on version 1 Done in version 2",
               "Priya, on version 2 Done in version 3",
               "You, on version 3"
             ]

      assert attr(html, "#{c} > ol > li", "class") ==
               ["q-xp-cm q-xp-cm-done", "q-xp-cm q-xp-cm-done", "q-xp-cm"]

      assert count(html, "#{c} .q-xp-cm-done .q-xp-cm-i") == 2
      assert count(html, "#{c} b") == 0
      assert count(html, "#{c} button, #{c} input, #{c} textarea, #{c} a") == 0

      [open] = html |> query("#{c}-3 .q-xp-cm-t span") |> Enum.to_list()
      assert LazyHTML.text(open) == "Show it on the order\nconfirmation."
      assert text(html, "#work-item-explore-reply-go") == "Confirm"
    end

    test "while the run a comment started works: the version it is on, the comment open, no field and no button" do
      running =
        run(%{
          id: "rn_01aa40b29e71c6d3",
          number: 14,
          path: "/8wonders/main/runs/14",
          attempt: 2,
          state: :running,
          started_at: ago(60),
          ended_at: nil,
          outcome: nil,
          proposal: nil,
          version: nil
        })

      comments = [%{text: "Also check the basket.", by: @dana, version: 1, done_version: nil}]

      for status <- [:queued, :running] do
        html =
          tab(work_item(%{status: status, run: running}),
            can_act: true,
            earlier_runs: [run(%{})],
            comments: comments
          )

        assert count(html, "#work-item-explore-wait") == 0, "#{status}"

        assert text(html, "#work-item-explore-proposal .q-xp-cap") ==
                 "Version 1. Attempt 1 wrote this."

        assert texts(html, "#work-item-explore-proposal-text h4") == [
                 "What this is",
                 "How Qory would do it"
               ]

        assert text(html, "#work-item-explore-comments .q-xp-cm-m") ==
                 "You, on version 1 Qory is updating the proposal"

        assert count(html, "form") == 0
        assert count(html, "textarea") == 0
        assert count(html, "button") == 0

        # The fold of the run that wrote the proposal says so, with no text in it.
        assert texts(html, "#work-item-explore-earlier summary") ==
                 ["Attempt 1 of 3 Wrote a proposal 14 Oct, 11:36"]

        assert count(html, "#work-item-explore-earlier .q-xp-inner") == 0
      end
    end

    test "a run after answers, not after a comment, waits as before; done comments mark nothing" do
      running =
        run(%{attempt: 3, state: :running, started_at: ago(60), ended_at: nil, proposal: nil})

      done = [%{text: "Also check the basket.", by: @dana, version: 1, done_version: 2}]

      after_questions =
        tab(work_item(%{status: :running, run: running}),
          earlier_runs: [run(%{}), run2_answered()],
          comments: [%{hd(done) | done_version: nil}]
        )

      assert text(after_questions, "#work-item-explore-wait-h") =~ "Explore is running again"
      assert count(after_questions, "#work-item-explore-proposal") == 0

      all_done =
        tab(work_item(%{status: :running, run: running}),
          earlier_runs: [run(%{})],
          comments: done
        )

      assert count(all_done, "#work-item-explore-wait") == 1
      assert count(all_done, "#work-item-explore-proposal") == 0
    end

    test "a refused comment: its words under the field, describing it, and the focus on it" do
      for {error, words} <- [
            {:blank, "Write what to change."},
            {{:too_long, 2000}, "Shorten the comment to 2,000 characters or fewer."},
            {:characters, "Remove the invisible or control characters from the comment."},
            {:not_approver,
             "Ask one of this stage's approvers to comment. Only they can comment on its proposal."}
          ] do
        html =
          tab(work_item(%{}),
            can_act: true,
            change: "  ",
            change_error: error,
            change_submits: 2
          )

        r = "#work-item-explore-reply"
        assert text(html, "#{r}-error") == words, inspect(error)
        assert attr(html, "#{r} textarea", "aria-invalid") == ["true"]

        assert attr(html, "#{r} textarea", "aria-describedby") == [
                 "work-item-explore-reply-error"
               ]

        assert attr(html, "#{r}-focus-2", "phx-mounted") |> hd() =~
                 "#work-item-explore-reply-text"

        assert text(html, "#{r}-go") == "Send change"
      end

      html = tab(work_item(%{}), can_act: true, change_error: :other)
      assert count(html, "#work-item-explore-reply-error") == 0
      assert count(html, "[aria-invalid]") == 0
    end

    test "a result stored before the proposal was Markdown shows no text, and does not fail" do
      html = tab(work_item(%{run: run(%{proposal: %{message: nil}})}), can_act: true)

      assert text(html, "#work-item-explore-proposal-h") == "Qory's proposal"
      assert count(html, "#work-item-explore-proposal-text") == 0
      assert count(html, "#work-item-explore-proposal .q-xp-body") == 0
      assert text(html, "#work-item-explore-reply-go") == "Confirm"
    end

    test "a hostile proposal: no script, no javascript: link, no image loaded" do
      message = """
      # Plan <script>alert(1)</script>

      <img src="https://img.example.com/x.png" onerror="alert(2)">

      [run this](javascript:alert(3)) and [mail](mailto:team@example.com)

      ![a cat](https://img.example.com/cat.png)

      <a href="https://evil.example.com">raw link</a>
      """

      html = tab(work_item(%{run: run(%{proposal: %{message: message}})}))
      p = "#work-item-explore-proposal-text"

      refute html =~ "<script"
      refute html =~ "<img"
      refute html =~ "onerror"
      refute html =~ "javascript:"
      refute html =~ "evil.example.com"
      # The tag goes; its words stay, as plain text.
      assert text(html, "#{p} h3") == "Plan alert(1)"
      assert text(html, p) =~ "run this and mail"

      assert attr(html, "#{p} a", "href") == [
               "mailto:team@example.com",
               "https://img.example.com/cat.png"
             ]

      assert text(html, ~s(#{p} a[href="https://img.example.com/cat.png"])) =~ "Image: a cat"
    end

    test "a text the renderer does not format shows as written, escaped" do
      p = %{message: "x", rendered: {:as_written, "Line one\n<b>not bold</b>"}}
      html = tab(work_item(%{run: run(%{proposal: p})}))

      assert text(html, "#work-item-explore-proposal-text .q-xp-md-note") == "Shown as written."

      [written] =
        html |> query("#work-item-explore-proposal-text .q-ticket-written") |> Enum.to_list()

      assert LazyHTML.text(written) == "Line one\n<b>not bold</b>"
      assert count(html, "#work-item-explore-proposal-text b") == 0
    end

    test "markdown/1 gives the render, as written past the renderer's bounds, nil for none" do
      assert {:html, _safe} = C.markdown("**bold**")
      assert C.markdown(nil) == nil
      big = String.duplicate("a", ApiaryWeb.ArtifactLive.Markdown.max_bytes() + 1)
      assert C.markdown(big) == {:as_written, big}
    end

    test "confirmed: Confirmed, who and when; no field and no button" do
      w = work_item(%{status: :shape, confirmed_by: @dana, confirmed_at: ago(30)})
      html = tab(w, can_act: true)
      p = "#work-item-explore-proposal"

      assert text(html, "#{p} .q-xp-frame-h .badge") == "Confirmed"

      assert text(html, "#{p} .q-xp-cap") ==
               "You confirmed this proposal just now. Attempt 1 wrote it."

      assert count(html, "form") == 0

      other = tab(%{w | confirmed_by: @priya, confirmed_at: ago(3 * 3600)})

      assert text(other, "#{p} .q-xp-cap") ==
               "Priya confirmed this proposal 3 hours ago. Attempt 1 wrote it."
    end

    test "closed at Confirm: the proposal, read" do
      w =
        work_item(%{status: :closed, stage: :confirm, ended_by: @priya, ended_at: ago(86_400)})

      html = tab(w, can_act: true)
      assert text(html, "#work-item-explore-proposal-h") == "Qory's proposal"
      assert count(html, ".q-xp-frame-h .badge") == 0
      assert count(html, "form") == 0
    end
  end

  describe "explore_tab/1, the questions form" do
    @lazy """
    The category listing requests each product image twice:

    - once in the page the server sends
    - once in the lazy loader

    ```
    <img src="/img/42.jpg">
    ```

    Which load should stay?
    """

    defp option_questions(answers \\ [nil, nil]) do
      [
        %{
          public_id: "qq_01",
          text: @lazy,
          options: [
            %{
              title: "Keep the lazy loader",
              explanation: "The first page opens faster. Cost: images appear a moment later."
            },
            %{
              title: "Keep the server's images",
              explanation: "Every image shows at once. Cost: a slower first page on phones."
            }
          ]
        },
        %{public_id: "qq_02", text: "Which is the oldest phone the shop supports?", options: []}
      ]
      |> Enum.zip(answers)
      |> Enum.map(fn {q, answer} -> Map.merge(q, %{answer: answer, custom: nil}) end)
    end

    defp questions_item(qs \\ option_questions()) do
      work_item(%{
        number: 94,
        status: :questions,
        run:
          run(%{
            id: "rn_01aa1f3e5c0d82a4",
            number: 13,
            path: "/8wonders/main/runs/13",
            attempt: 2,
            outcome: :questions,
            proposal: nil,
            questions: qs
          })
      })
    end

    test "each question as Markdown, its options as radio cards, one field each, one Send answers" do
      html = tab(questions_item(), can_act: true)
      q = "#work-item-explore-questions"

      assert text(html, "#{q}-h") == "Qory's questions"
      assert text(html, "#{q} .q-xp-cap") == "Attempt 2 wrote this."
      assert texts(html, "#{q} .q-xp-sec > h3") == ["Questions"]
      assert attr(html, "#{q}-form", "phx-change") == ["answer_draft"]
      assert attr(html, "#{q}-form", "phx-submit") == ["answer"]
      assert attr(html, "#{q}-form input[type=hidden]", "value") == ["94"]

      # Question 1: its Markdown, a list and a code block, then its two options.
      q1 = "#work-item-explore-questions-q-qq_01"

      assert texts(html, "#{q1} li") == [
               "once in the page the server sends",
               "once in the lazy loader"
             ]

      assert text(html, "#{q1} pre code") == ~s(<img src="/img/42.jpg">)
      assert count(html, "#{q1} img") == 0

      g = "#work-item-explore-questions-answer-qq_01-options"
      assert attr(html, g, "role") == ["radiogroup"]
      assert attr(html, g, "aria-labelledby") == ["work-item-explore-questions-q-qq_01"]
      assert attr(html, "#{g} input", "type") == ["radio", "radio"]

      assert attr(html, "#{g} input", "name") == [
               "answers[qq_01][option]",
               "answers[qq_01][option]"
             ]

      assert attr(html, "#{g} input", "value") == [
               "Keep the lazy loader",
               "Keep the server's images"
             ]

      assert attr(html, "#{g} input", "checked") == []

      assert attr(html, "#{g} label", "for") == [
               "work-item-explore-questions-answer-qq_01-1",
               "work-item-explore-questions-answer-qq_01-2"
             ]

      assert texts(html, "#{g} .q-xp-opt-t") == [
               "Keep the lazy loader",
               "Keep the server's images"
             ]

      assert texts(html, "#{g} .q-xp-opt-e") == [
               "The first page opens faster. Cost: images appear a moment later.",
               "Every image shows at once. Cost: a slower first page on phones."
             ]

      # One field each; question 2 offers no options, so only its field.
      assert attr(html, "#{q}-form textarea", "name") ==
               ["answers[qq_01][custom]", "answers[qq_02][custom]"]

      assert attr(html, "#{q}-form textarea", "placeholder") ==
               ["Give your own option", "Give your own option"]

      assert count(html, "#work-item-explore-questions-answer-qq_02-options") == 0
      assert count(html, "[role=radiogroup]") == 1

      assert text(html, "#{q}-next") ==
               "Sending starts attempt 3 of 3, which reads the ticket, its comments, the first instruction and every answer of this take in."

      assert count(html, "button") == 1
      assert text(html, "#{q}-go") == "Send answers"
      assert count(html, "[aria-invalid]") == 0
    end

    test "a selected option is checked; a written option fills its field" do
      html =
        tab(questions_item(),
          can_act: true,
          answers: %{
            "qq_01" => %{"option" => "Keep the lazy loader", "custom" => ""},
            "qq_02" => %{"custom" => "The two oldest phones the shop supports."}
          }
        )

      assert attr(html, "#work-item-explore-questions-answer-qq_01-1", "checked") == [""]
      assert attr(html, "#work-item-explore-questions-answer-qq_01-2", "checked") == []
      assert text(html, "#work-item-explore-questions-answer-qq_01") == ""

      assert text(html, "#work-item-explore-questions-answer-qq_02") ==
               "The two oldest phones the shop supports."
    end

    test "one question with no options: only its field" do
      [_q1, q2] = option_questions()
      html = tab(questions_item([q2]), can_act: true)

      assert text(html, "#work-item-explore-questions-h") == "Qory's question"
      assert count(html, "input[type=radio]") == 0
      assert attr(html, "textarea", "placeholder") == ["Give your own option"]
    end

    test "errors: under their question, describing it, and the focus on the first" do
      html =
        tab(questions_item(),
          can_act: true,
          answers: %{"qq_02" => %{"custom" => String.duplicate("a", 2001)}},
          errors: %{"qq_01" => :blank, "qq_02" => {:too_long, 2000}}
        )

      a1 = "#work-item-explore-questions-answer-qq_01"
      assert attr(html, a1, "aria-invalid") == ["true"]

      assert attr(html, a1, "aria-describedby") == [
               "work-item-explore-questions-q-qq_01 work-item-explore-questions-answer-qq_01-error"
             ]

      assert attr(html, "#{a1}-options", "aria-describedby") == [
               "work-item-explore-questions-answer-qq_01-error"
             ]

      assert text(html, "#{a1}-error") ==
               "Choose an option or write an answer. If nobody knows, say so: Qory reads that too."

      assert text(html, "#work-item-explore-questions-answer-qq_02-error") ==
               "Write at most 2,000 characters."

      assert attr(html, "#work-item-explore-questions-focus-0-qq_01", "phx-mounted") |> hd() =~
               "#work-item-explore-questions-answer-qq_01"
    end

    test "a reader who may not act reads the questions and their options, with no input" do
      html = tab(questions_item(), can_act: false)

      assert count(html, "form") == 0
      assert count(html, "input") == 0
      assert count(html, "textarea") == 0

      assert texts(html, ".q-xp-opt-t") == ["Keep the lazy loader", "Keep the server's images"]
      assert count(html, "#work-item-explore-questions-q-qq_01 .q-xp-opts > li") == 2
    end

    test "a hostile question: no script, no javascript: link, no image; mermaid is code text" do
      text = """
      Which <script>alert(1)</script> one?

      [click](javascript:alert(2))

      ![chart](https://img.example.com/chart.png)

      ```mermaid
      graph TD; A-->B
      ```
      """

      qs = [
        %{
          public_id: "qq_09",
          text: text,
          options: [%{title: "<b>Bold</b>", explanation: "<script>x</script>"}],
          answer: nil,
          custom: nil
        }
      ]

      for can_act <- [true, false] do
        html = tab(questions_item(qs), can_act: can_act)

        refute html =~ "<script"
        # The tag goes; its words stay, as plain text.
        assert text(html, "#work-item-explore-questions-q-qq_09 p") =~ "Which alert(1) one?"
        refute html =~ "javascript:"
        refute html =~ "<img"
        refute html =~ "phx-hook"
        assert text(html, "pre.q-mermaid-source code") == "graph TD; A-->B"
        assert attr(html, "a[href='https://img.example.com/chart.png']", "target") == ["_blank"]
        assert text(html, ".q-xp-opt-t") == "<b>Bold</b>"
        assert text(html, ".q-xp-opt-e") == "<script>x</script>"
        assert html =~ "&lt;b&gt;Bold&lt;/b&gt;"
      end
    end
  end

  describe "explore_tab/1, the run limit and the earlier runs" do
    defp used_item(status \\ :used_up, extra \\ %{}) do
      r =
        run(%{
          id: "rn_01aa47c9b05e3f18",
          number: 15,
          path: "/8wonders/main/runs/15",
          attempt: 3,
          outcome: :questions,
          proposal: nil,
          questions: [
            %{
              public_id: "qq_05",
              text: "Should a refund go to the gift card first?",
              options: [],
              answer: nil,
              custom: nil
            }
          ],
          ended_at: ago(8 * 60),
          duration: "9 minutes"
        })

      work_item(Map.merge(%{number: 94, status: status, run: r}, extra))
    end

    test "the note, the last questions read-only, and the earlier runs folded" do
      html = tab(used_item(), can_act: true, earlier_runs: [run1_answered(), run2_answered()])

      assert items(html, "work-item-explore-run") ==
               ["Attempt 3 of 3", "Completed", "ended 8 minutes ago, after 9 minutes"]

      assert text(html, "#work-item-explore-limit") ==
               "This take in used all 3 runs, so Explore cannot run again for these questions. To start a new count, close the work item, then use Take in again in the Backlog."

      assert count(html, "textarea") == 0
      assert text(html, "#work-item-explore-questions-h") == "Qory's question"
      assert text(html, "#work-item-explore-earlier-h") == "Earlier runs of this take in"

      body = "#work-item-explore-earlier-13-body"
      assert text(html, "#{body}-h") == "Qory's questions, and the answers"

      assert text(html, "#{body} .q-xp-cap") ==
               "Attempt 1 wrote these questions."

      assert text(html, "#{body}-qa-who") == "You answered 1 hour ago"

      assert text(html, "#work-item-explore-earlier-14-body-h") ==
               "Qory's question, and the answer"
    end

    test "the note, while the repository keeps its tickets out of the Backlog, without Take in again" do
      html = tab(used_item(), can_act: true, backlog_off: true)

      assert text(html, "#work-item-explore-limit") ==
               "This take in used all 3 runs, so Explore cannot run again for these questions."

      one = used_item(:used_up, %{run: %{used_item().run | attempt: 1, of: 1}})

      assert text(tab(one, can_act: true, backlog_off: true), "#work-item-explore-limit") ==
               "This take in used its 1 run, so Explore cannot run again for these questions."
    end

    test "closed at Explore: the last questions read-only, no note" do
      w = used_item(:closed, %{stage: :explore, ended_by: @dana, ended_at: ago(5)})
      html = tab(w, can_act: true)
      assert count(html, "#work-item-explore-limit") == 0
      assert count(html, "textarea") == 0
      assert text(html, "#work-item-explore-questions-h") == "Qory's question"
    end

    test "an earlier run that proposed, or gave no result, says so in its fold; a proposal's text is not in it" do
      proposed = run(%{id: "rn_01a8d4f16b2e70c8", number: 17, ended_at: ago(4 * 86_400)})

      lost =
        run(%{
          id: "rn_01aa5a71e3d06b29",
          number: 18,
          state: :lost,
          outcome: nil,
          ended_at: ago(21 * 60)
        })

      html = tab(used_item(), earlier_runs: [proposed, lost])

      assert texts(html, "#work-item-explore-earlier summary .q-xp-it:nth-child(3)") ==
               ["Wrote a proposal", "Lost"]

      assert count(html, "#work-item-explore-earlier-17 .q-xp-inner") == 0
      assert count(html, "#work-item-explore-earlier-17-body-h") == 0
      refute html =~ "What this is"

      assert text(html, "#work-item-explore-earlier-18-body-h") ==
               "The run was lost."
    end
  end

  describe "explore_tab/1, a run without a result" do
    # Contact support reads the support address.
    setup do: Ecto.Adapters.SQL.Sandbox.checkout(Apiary.Repo)

    # The Explore tab of a run qory closed with `code`, on the instance's pool or another.
    defp read_needs_body(code, installed) do
      r =
        run(%{
          proposal: nil,
          ended_at: ago(3600),
          duration: "4 minutes",
          outcome: :none,
          read_needs: %{code: code, installed: installed}
        })

      html = tab(work_item(%{number: 97, status: :no_result, run: r}))

      assert text(html, "#work-item-explore-none-h") == "The run ended without a result."
      Enum.at(texts(html, "#work-item-explore-none p"), 1)
    end

    test "a read-only run qory closed: the fix, then the cause" do
      wall = "A read-only run needs a wall, and this machine has none."
      inside = "A read-only run cannot run its setup inside the agent's container."

      docker =
        "Choose an image without nested Docker in the workspace's policy or the repository's environment, then start the run again. A read-only run cannot use an image with nested Docker."

      removed =
        "Start the run again. The setup container was not removed, so a process in it could still write the files."

      assert read_needs_body("read_needs_wall", false) ==
               "Set a wall in the machine's forager.yaml, then start the run again. " <> wall

      assert read_needs_body("read_needs_setup_outside", false) ==
               "Set wall.setup to outside in the machine's forager.yaml, or remove it, then start the run again. " <>
                 inside

      assert read_needs_body("read_needs_wall", true) == "Contact support. " <> wall
      assert read_needs_body("read_needs_setup_outside", true) == "Contact support. " <> inside

      for installed <- [false, true] do
        assert read_needs_body("read_needs_no_nested_docker", installed) == docker
        assert read_needs_body("read_needs_setup_removed", installed) == removed
      end
    end

    test "a read-only run's target is a repository only in a software workspace" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@example", fn ->
        assert read_needs_body("read_needs_no_nested_docker", false) ==
                 "Choose an image without nested Docker in the workspace's policy or the target's environment, then start the run again. A read-only run cannot use an image with nested Docker."
      end)
    end

    test "what happened, and the run's page" do
      for {status, overrides, run_state, heading, body} <- [
            {:no_result, %{state: :failed, outcome: :error, end_cause: :run_ended}, "Failed",
             "The run ended with an error.",
             "The run's last result was an error. There is nothing to show or confirm."},
            {:no_result, %{outcome: :none}, "Completed", "The run ended without a result.",
             "There is nothing to show or confirm."},
            {:no_result, %{outcome: :refused}, "Completed",
             "The run's result did not pass Qory's check.",
             "Qory accepts a result only in Explore's format and up to 128 KiB. This result is outside those limits, so Qory does not show it."},
            {:lost, %{state: :lost, outcome: nil}, "Lost", "The run was lost.",
             "Qory Apiary has no result from the run. There is nothing to show or confirm."},
            {:cancelled, %{state: :cancelled, outcome: nil}, "Cancelled",
             "The run was cancelled.", "There is nothing to show or confirm."}
          ] do
        r =
          run(Map.merge(%{proposal: nil, ended_at: ago(3600), duration: "4 minutes"}, overrides))

        html = tab(work_item(%{number: 97, status: status, run: r}))

        assert Enum.at(items(html, "work-item-explore-run"), 1) == run_state
        assert text(html, "#work-item-explore-none-h") == heading

        assert texts(html, "#work-item-explore-none p") == [
                 heading,
                 body,
                 "The page of attempt 1 shows what it did."
               ]

        assert attr(html, "#work-item-explore-none a", "href") == [
                 "/8wonders/main/runs/12"
               ]
      end
    end

    test "a run that ended at its handover, before it started: what to fix and why, here and in the folds" do
      for {cause, body} <- [
            {:variables_invalid,
             "Fix the variables in the workspace's settings, then run Explore again. One of the run's variables breaks a variable rule."},
            {:ticket_gone,
             "If the ticket is still in the Backlog, take it in again from there. Qory Apiary no longer has this work item's ticket."},
            {:inputs_invalid,
             "Shorten or correct the ticket, then run Explore again. A value in the ticket or the work item breaks a rule for the agent's input, such as the size limit."},
            # A software workspace's word for the target.
            {:target_access_gone,
             "Check the integration that brings in this repository on the organisation's Integrations page, then run Explore again. The run had no access to its repository: the integration no longer reaches it, or the repository's path has a character that access rules do not allow."},
            {:build_failed,
             "Check why the build failed on the repository's page, then run Explore again. The run did not start because Qory Apiary could not build its environment image."}
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

        words = ["The run did not start.", body]

        html = tab(work_item(%{number: 97, status: :no_result, run: r}))
        assert text(html, "#work-item-explore-none-h") == "The run did not start."
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
          ended: :closed,
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
          refute html =~ "The run&#39;s last result was an error"
        end
      end
    end

    test "a run that stopped at a call to an adapter says which, what for and what to do, beside its end words" do
      for {failure, line} <- [
            {%{cause: :timeout, call: "run-credential", code: nil},
             "Contact support. The run did not start: the call to code-host for the run's credentials timed out."},
            {%{cause: :unreachable, call: "resolve", code: nil},
             "Contact support. The run did not start: the call to code-host for the harness sources did not reach it."},
            {%{cause: :refused, call: "read", code: "grant_unknown"},
             "Contact support. The run did not start: the call to code-host for the harness files returned the error grant_unknown."},
            {%{cause: :refused, call: "read", code: nil},
             "Contact support. The run did not start: the call to code-host for the harness files returned the error unauthorized."},
            {%{cause: :invalid_answer, call: "resolve", code: nil},
             "Contact support. The run did not start: the response of code-host failed its signature check or format check, or was over 1 MiB."},
            {%{cause: :no_address, call: "resolve", code: nil},
             "Contact support. The run did not start: code-host has no call address."},
            {%{cause: :not_allowed, call: "resolve", code: nil},
             "Contact support. The run did not start: Qory Apiary does not call the call address of code-host."},
            {%{cause: :too_large, call: "resolve", code: nil},
             "Remove harness sources or files, then run Explore again. The run did not start: the call to code-host for the harness sources was over 256 KiB."}
          ] do
        r =
          run(%{
            id: nil,
            path: nil,
            state: :failed,
            outcome: :error,
            end_cause: :inputs_invalid,
            adapter_failure: Map.put(failure, :adapter, "code-host"),
            proposal: nil,
            started_at: nil,
            ended_at: ago(3600),
            duration: nil
          })

        html = tab(work_item(%{number: 97, status: :no_result, run: r}))
        assert text(html, "#work-item-explore-none-h") == "The run did not start."
        assert text(html, "#work-item-explore-none-adapter") == line
        assert length(texts(html, "#work-item-explore-none p")) == 3
      end

      # A run with none has no such line.
      r =
        run(%{state: :failed, outcome: :error, end_cause: :inputs_invalid, adapter_failure: nil})

      html = tab(work_item(%{number: 97, status: :no_result, run: r}))
      assert count(html, "#work-item-explore-none-adapter") == 0
    end

    test "a run whose harness walk failed: what to fix, with the source, beside its end words" do
      harness = "https://code.example.com/acme/harness"
      setting = "the workspace's harness setting"

      for {failure, line} <- [
            # A software workspace's word for the target.
            {%{code: "no_harness"},
             "Add a harness file to the repository, or set a harness in the workspace's settings, then run Explore again. The run has neither."},
            {%{
               code: "invalid",
               source: harness,
               rule: %{"rule" => "path", "values" => %{"path" => "../x"}}
             },
             "Correct #{harness}, then run Explore again. The source breaks the harness format: the path ../x leads out of its source."},
            # A hidden harness: no source, and no path, ref or stack name in the rule.
            {%{code: "invalid", rule: %{"rule" => "path", "values" => %{}}},
             "Correct #{setting}, then run Explore again. The source breaks the harness format: a path leads out of its source."},
            {%{code: "invalid", rule: %{"rule" => "path_form", "values" => %{}}},
             "Correct #{setting}, then run Explore again. The source breaks the harness format: a path has a backslash or a percent sign: write it with / and no percent-encoding."},
            {%{code: "invalid", rule: %{"rule" => "ref", "values" => %{}}},
             "Correct #{setting}, then run Explore again. The source breaks the harness format: its ref is not a version: 1 to 255 letters, digits, dots, underscores, slashes and hyphens."},
            {%{code: "invalid", rule: %{"rule" => "no_export", "values" => %{}}},
             "Correct #{setting}, then run Explore again. The source breaks the harness format: it exports no stack of that name."},
            {%{
               code: "invalid",
               rule: %{
                 "message" => "has a value the harness format does not take",
                 "values" => %{}
               }
             },
             "Correct #{setting}, then run Explore again. The source breaks the harness format: has a value the harness format does not take."},
            {%{code: "invalid", rule: %{"rule" => "no_stack_file", "values" => %{}}},
             "Correct #{setting}, then run Explore again. The source breaks the harness format: it has no qory-stack.yaml at the stack's path."},
            {%{
               code: "invalid",
               source: "https://code.example.com/acme/app",
               rule: %{"rule" => "both_files", "values" => %{}}
             },
             "Correct https://code.example.com/acme/app, then run Explore again. The source breaks the harness format: it has both harness.yaml and qory.yaml: keep one."},
            {%{code: "invalid", rule: %{"rule" => "size", "values" => %{"n" => 65_536}}},
             "Correct #{setting}, then run Explore again. The source breaks the harness format: it is larger than 65536 bytes as JSON."},
            {%{code: "walk_error"},
             "Run Explore again. If the run ends the same way, contact support. The harness walk stopped on an error in Qory Apiary."},
            {%{
               code: "invalid",
               rule: %{
                 "message" =>
                   "give the base %{name} as a git source and an export: extends: {git: <https address>, ref: <ref>, stack: %{name}}",
                 "values" => %{"name" => "web"}
               }
             },
             "Correct #{setting}, then run Explore again. The source breaks the harness format: give the base web as a git source and an export: extends: {git: <https address>, ref: <ref>, stack: web}."},
            # A save check's message that is a sentence: one "." at the end of the line.
            {%{
               code: "invalid",
               source: harness,
               rule: %{
                 "message" =>
                   "Write bind by kind, then by role, such as bind: {agents: {developer: web-developer}}: %{key} is a flat key.",
                 "values" => %{"key" => "agents/developer"}
               }
             },
             "Correct #{harness}, then run Explore again. The source breaks the harness format: Write bind by kind, then by role, such as bind: {agents: {developer: web-developer}}: agents/developer is a flat key."},
            {%{
               code: "invalid",
               source: harness,
               rule: %{
                 "rule" => "yaml",
                 "values" => %{"file" => "qory.yaml"},
                 "message" => "is not valid YAML",
                 "message_values" => %{}
               }
             },
             "Correct #{harness}, then run Explore again. The source breaks the harness format: qory.yaml is not valid YAML."},
            {%{code: "not_covered", source: harness, organisation: "Acme"},
             "Owners and admins of Acme connect an integration that covers #{harness} in Organisation settings › Integrations. #{harness} is not public, or does not exist, and no connection of Acme reaches it."},
            {%{code: "not_covered", source: harness},
             "Owners and admins of this organisation connect an integration that covers #{harness} in Organisation settings › Integrations. #{harness} is not public, or does not exist, and no connection of this organisation reaches it."},
            {%{
               code: "too_large",
               source: harness,
               workspace: "Main",
               rule: %{
                 "rule" => "fetch",
                 "values" => %{"host" => "code.example.com", "port" => 443}
               }
             },
             "Whoever maintains #{harness} makes it smaller, or owners and admins of Main choose another harness on the set-up step Harness. #{harness} is larger than Qory Apiary reads."},
            {%{
               code: "source_unreachable",
               source: harness,
               rule: %{
                 "rule" => "fetch",
                 "values" => %{"host" => "code.example.com", "port" => 8443, "seconds" => 10}
               }
             },
             "Contact support: Qory Apiary did not receive #{harness} from code.example.com on port 8443 within 10 s."},
            {%{
               code: "rate_limited",
               source: harness,
               rule: %{
                 "rule" => "fetch",
                 "values" => %{"host" => "code.example.com", "port" => 443}
               }
             },
             "Try again later: code.example.com limits how often Qory Apiary reads from it, and that limit is reached."},
            {%{
               code: "host_not_allowed",
               source: harness,
               organisation: "Acme",
               rule: %{
                 "rule" => "fetch",
                 "values" => %{"host" => "code.example.com", "port" => 443}
               }
             },
             "If an integration serves code.example.com, owners and admins of Acme link the repository through its connection in Organisation settings › Integrations; otherwise, contact support. code.example.com resolves to a private, loopback or link-local address, and Qory Apiary reads public repositories from public addresses only."},
            {%{
               code: "fetch_failed",
               source: harness,
               organisation: "Acme",
               rule: %{
                 "rule" => "fetch",
                 "values" => %{"host" => "code.example.com", "port" => 443}
               }
             },
             "Owners and admins of Acme check the address on the set-up step Harness, or link the repository through a connection. code.example.com did not serve #{harness} as a git repository over HTTPS."},
            {%{code: "not_allowed"},
             "Ask the owner of #{setting} to assign it to this organisation, then run Explore again. That harness source belongs to another owner, who has not assigned it here."},
            {%{code: "scp_form", source: "code.example.com:acme/harness"},
             "Write code.example.com:acme/harness as an https address, then run Explore again. Qory Apiary fetches harness sources over https only, and code.example.com:acme/harness has the form user@host:path."},
            {%{code: "credential_in_address", source: harness},
             "Remove the user name and password from #{harness}, then run Explore again. A harness source address may not contain a credential."},
            {%{code: "too_many"},
             "Take the harness sources from at most 5 accounts, then run Explore again. A run takes 5 harness credentials at most."},
            {%{code: "adapter_unavailable", adapter: "code-host"},
             "Run Explore again. If the run ends the same way, contact support. Three calls to the adapter code-host failed."}
          ] do
        r =
          run(%{
            id: nil,
            path: nil,
            state: :failed,
            outcome: :error,
            end_cause: :harness_unresolved,
            harness_failure: Map.merge(%{source: nil, rule: nil, adapter: nil}, failure),
            proposal: nil,
            started_at: nil,
            ended_at: ago(3600),
            duration: nil
          })

        html = tab(work_item(%{number: 97, status: :no_result, run: r}))
        assert text(html, "#work-item-explore-none-h") == "The run did not start."

        assert texts(html, "#work-item-explore-none p") == [
                 "The run did not start.",
                 line
               ]
      end

      # A call that failed otherwise: the adapter's line alone says what happened.
      r =
        run(%{
          id: nil,
          path: nil,
          state: :failed,
          outcome: :error,
          end_cause: :harness_unresolved,
          harness_failure: %{code: "adapter_failed", source: nil, rule: nil, adapter: nil},
          adapter_failure: %{adapter: "code-host", cause: :refused, call: "resolve", code: "bad"},
          proposal: nil,
          started_at: nil,
          ended_at: ago(3600),
          duration: nil
        })

      html = tab(work_item(%{number: 97, status: :no_result, run: r}))

      assert texts(html, "#work-item-explore-none p") == [
               "The run did not start.",
               "Contact support. The run did not start: the call to code-host for the harness sources returned the error bad."
             ]
    end

    test "a run whose harness has no skill for its workflow: the workflow and where the harness comes from" do
      for {source, line} <- [
            {{:target, "acme/web-shop"},
             "The run's harness has no skill named explore-a-ticket. The harness comes from the harness file at the root of repository acme/web-shop."},
            {:qory,
             "The run's harness has no skill named explore-a-ticket. The harness is the Qory harness."},
            {nil, "The run's harness has no skill named explore-a-ticket."}
          ] do
        r =
          run(%{
            state: :failed,
            outcome: :error,
            end_cause: :run_ended,
            workflow_gap: %{workflow: "explore-a-ticket", source: source},
            proposal: nil,
            started_at: nil,
            ended_at: ago(3600),
            duration: nil
          })

        html = tab(work_item(%{number: 97, status: :no_result, run: r}))
        assert text(html, "#work-item-explore-none-h") == "The run did not start."

        assert Enum.take(texts(html, "#work-item-explore-none p"), 2) ==
                 ["The run did not start.", line]
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
        "The run's last result was an error. There is nothing to show or confirm."
      ]

      html = tab(work_item(%{number: 97, status: :no_result, run: r}))
      assert texts(html, "#work-item-explore-none p") |> Enum.take(2) == words

      earlier =
        tab(work_item(%{number: 97, status: :queued, run: %{attempt: 2, of: 3}}),
          earlier_runs: [r]
        )

      assert texts(earlier, "#work-item-explore-earlier-12-body p")
             |> Enum.take(2) == words

      for html <- [html, earlier] do
        refute html =~ "The run did not start."
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
        ended: :closed,
        ended_by: @dana,
        ended_at: ago(4 * 60),
        runs: [
          run1_answered(),
          run2_answered(),
          run(%{id: "rn_01aa47c9b05e3f18", number: 15, attempt: 3})
        ]
      }

      w = work_item(%{number: 94, status: :queued, run: %{attempt: 1, of: 3}})
      html = tab(w, earlier_take_ins: [take_in])

      assert text(html, "#work-item-explore-take-ins-h") == "Earlier take ins"

      assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
               ["Taken in 16 Oct by you", "Closed by you 4 minutes ago", "3 runs"]

      assert text(html, "#work-item-explore-take-ins-1 .q-xp-inner > p:first-child") ==
               "These runs do not count toward the run limit of this take in."

      assert texts(html, "#work-item-explore-take-ins-1 .q-xp-run > span:first-child") ==
               ["Attempt 1 of 3", "Attempt 2 of 3", "Attempt 3 of 3"]
    end

    test "every end, in both forms, and one run" do
      for {ended, by, words} <- [
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

  defp line(html), do: text(html, "li.q-wi-ev > div > p:first-child")

  describe "thread_event/1, Explore's lines" do
    test "a run starts: first, with the answers, again; its place beside it; Qory's bee" do
      r = run(%{attempt: 2})

      for {start, words} <- [
            {nil, "Qory started Explore in attempt 2"},
            {:answers, "Qory started Explore again, with the answers, in attempt 2"},
            {:again, "Qory started Explore again in attempt 2"}
          ] do
        html = event(kind: :started, run: r, start: start)
        assert line(html) == words <> " Attempt 2 of 3 14 Oct, 11:25"
        assert text(html, ".q-wi-tag") == "Attempt 2 of 3"
        assert attr(html, "p a", "href") == ["/8wonders/main/runs/12"]
        assert count(html, ".q-wi-ev-ic .q-bl-bee") == 1
      end
    end

    test "Qory asked: how many and after how long, the questions quoted under it" do
      html = event(kind: :asked, questions: questions(), duration: "9 minutes")
      assert line(html) == "Qory wrote 3 questions, after 9 minutes 14 Oct, 11:25"
      assert texts(html, "#ev-1-questions li") == Enum.map(questions(), & &1.text)

      one = event(kind: :asked, questions: [hd(questions())], duration: "8 minutes")
      assert line(one) == "Qory wrote 1 question, after 8 minutes 14 Oct, 11:25"
    end

    test "Qory asked: each question's Markdown, its HTML dropped and no image loaded" do
      qs = [
        %{
          public_id: "qq_01",
          text:
            "Which **load** stays? <script>alert(1)</script> ![x](https://img.example.com/x.png)",
          options: [],
          answer: nil
        }
      ]

      html = event(kind: :asked, questions: qs, duration: "9 minutes")
      assert text(html, "#ev-1-questions li strong") == "load"
      refute html =~ "<script"
      refute html =~ "<img"
      assert attr(html, "#ev-1-questions a", "href") == ["https://img.example.com/x.png"]

      answered =
        event(kind: :answered, actor: @dana, questions: [%{hd(qs) | answer: "The lazy one"}])

      assert text(answered, "#ev-1-answers .q-wi-qa-q strong") == "load"
      refute answered =~ "<script"
      assert text(answered, "#ev-1-answers .q-wi-qa-a") == "The lazy one"
    end

    test "a comment on Qory's proposal: who, and the comment quoted as plain text" do
      comment = "Also check the basket.\n<b>not bold</b>"

      html = event(kind: :answered, actor: @dana, questions: [], comment: comment)
      assert line(html) == "You commented on Qory's proposal 14 Oct, 11:25"
      [quoted] = html |> query("#ev-1-answers .q-wi-qa-a") |> Enum.to_list()
      assert LazyHTML.text(quoted) == comment
      assert count(html, "#ev-1-answers b") == 0
      assert count(html, "#ev-1-answers .q-wi-qa-q") == 0

      other = event(kind: :answered, actor: @priya, questions: [], comment: "Ship it.")
      assert line(other) == "Priya commented on Qory's proposal 14 Oct, 11:25"
      assert text(other, "#ev-1-answers b") == ""
      assert text(other, "li > div > p:first-child b") == "Priya"
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
               "Qory wrote a proposal, after 11 minutes. You confirm next 14 Oct, 11:25"

      assert line(event(kind: :proposed, owner: @lea, duration: "7 minutes")) ==
               "Qory wrote a proposal, after 7 minutes. Lea confirms next 14 Oct, 11:25"

      assert line(event(kind: :proposed, owner: nil, duration: "7 minutes")) ==
               "Qory wrote a proposal, after 7 minutes. 14 Oct, 11:25"
    end

    test "a run without a result, lost or cancelled, with its mark" do
      r = run(%{})

      for {kind, outcome, words} <- [
            {:no_result, :error, "Attempt 1 ended with an error, so Explore has no result"},
            {:no_result, :none, "Attempt 1 ended without a result"},
            {:no_result, :refused, "Attempt 1 returned a result that did not pass Qory's check"},
            {:lost, :error, "Attempt 1 was lost before it ended, so Explore has no result"},
            {:cancelled, :error,
             "Attempt 1 was cancelled before it ended, so Explore has no result"}
          ] do
        html = event(kind: kind, run: r, outcome: outcome)
        assert line(html) == words <> " 14 Oct, 11:25"
        assert count(html, ".q-wi-ev-bad") == 1
      end
    end

    test "asked to explore again, confirmed, changed and confirmed" do
      for {extra, words} <- [
            {[kind: :explore_again, actor: @dana], "You ran Explore again"},
            {[kind: :explore_again, actor: @priya], "Priya ran Explore again"},
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
  end

  ## Ids

  test "no DOM id, phx-value or path holds the ticket's ref or a source's; runs are numbers" do
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
        card(work_item(%{}), explore_path: "/8wonders/main/work/88/explore"),
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
              ended: :closed,
              ended_by: @dana,
              ended_at: ago(60),
              runs: [run(%{})]
            }
          ]
        ),
        tab(work_item(%{}), can_act: true, change_error: :blank),
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
    assert Enum.any?(values, &match?({"phx-value-number", "88"}, &1))
    assert Enum.any?(values, &match?({"name", "answers[qq_01][custom]"}, &1))
    assert Enum.any?(values, &match?({"id", "work-item-explore-earlier-13"}, &1))

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
        do: assert(value =~ ~r"/runs/[1-9][0-9]*\z", value)

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
              number: 15,
              path: "/8wonders/main/runs/15",
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

    test "no result at attempt 3 of 3 is the run-limit card: no Run Explore again, no attempt 4 of 3" do
      for {status, overrides} <- [
            {:no_result, %{state: :failed, outcome: :error}},
            {:lost, %{state: :lost, outcome: nil}},
            {:cancelled, %{state: :cancelled, outcome: nil}}
          ] do
        html = card(last(status, overrides), can_close: true)

        assert text(html, ".q-wi-badge") == "3 of 3 attempts used"
        assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait"]

        assert text(html, "#work-item-step-line") ==
                 "Attempt 3 ended without a result. That was attempt 3 of 3, the last attempt of this take in."

        assert count(html, "#work-item-step-again") == 0
        assert count(html, "#work-item-step-next") == 0
        refute html =~ "attempt 4 of 3"
        assert text(html, "#work-item-step-close") == "Close work item…"

        tab = tab(last(status, overrides), can_act: true)
        assert count(tab, "#work-item-explore-limit") == 0
        assert count(tab, "#work-item-explore-none") == 1
      end
    end

    test "questions at attempt 3 of 3 are read-only under the note: no form, no attempt 4 of 3" do
      w = last(:questions, %{outcome: :questions, questions: [hd(questions())]})

      html = tab(w, can_act: true)
      assert count(html, "#work-item-explore-limit") == 1
      assert count(html, "form") == 0
      assert count(html, "#work-item-explore-questions-next") == 0
      refute html =~ "attempt 4 of 3"

      assert text(card(w), ".q-wi-badge") == "3 of 3 attempts used"
    end

    test "at attempt 3 of 3 the header, the row, the stages and the card read the run limit alike" do
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
      assert text(html, "#work-item-step-next") == "Run Explore again starts attempt 3 of 3."
      assert text(html, "#work-item-step-again") == "Run Explore again"
    end
  end

  ## A field's first line, missing keys, the focus

  describe "the fields and the run's words, robustly" do
    test "a value that starts with a line break keeps it in its field" do
      [answer] =
        tab(questions_item(),
          can_act: true,
          answers: %{"qq_02" => %{"custom" => "\nWeb only."}}
        )
        |> query("#work-item-explore-questions-answer-qq_02")
        |> Enum.to_list()

      assert LazyHTML.text(answer) == "\nWeb only."

      [change] =
        tab(work_item(%{}), can_act: true, change: "\nStarts after a line.")
        |> query("#work-item-explore-reply-text")
        |> Enum.to_list()

      assert LazyHTML.text(change) == "\nStarts after a line."
    end

    test "a question stored before questions had options, and a draft that is no map" do
      qs = [%{public_id: "qq_01", text: "Which listing?", answer: nil}]
      html = tab(questions_item(qs), can_act: true, answers: %{"qq_01" => "old"})

      assert count(html, "input[type=radio]") == 0
      assert text(html, "#work-item-explore-questions-answer-qq_01") == ""
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

        changed =
          tab(work_item(%{}), can_act: true, change_error: :blank, change_submits: submits)

        assert count(changed, "#work-item-explore-reply-focus-#{submits}") == 1
      end
    end
  end

  describe "a source's words for its items" do
    @bug %{one: "bug", other: "bugs"}

    test "Explore reads the item by its source's word, or the ticket where it names none" do
      queued = work_item(%{number: 341, status: :queued, run: %{attempt: 1, of: 3}})

      assert text(tab(queued, item_noun: @bug), "#work-item-explore-wait p:last-child") ==
               "Qory starts attempt 1 of 3 when the workspace's pool takes it. It reads the bug and proposes what to do, or asks what it needs to know."

      asked =
        work_item(%{
          number: 94,
          status: :questions,
          run: run(%{outcome: :questions, questions: questions()})
        })

      assert tab(asked, can_act: true, item_noun: @bug) =~
               "Sending starts attempt 2 of 3, which reads the bug, its comments, the first instruction and every answer of this take in."

      assert tab(asked, can_act: true) =~
               "Sending starts attempt 2 of 3, which reads the ticket, its comments, the first instruction and every answer of this take in."

      running = run(%{state: :running, outcome: nil, ended_at: nil, answers_by: []})

      assert text(
               card(work_item(%{status: :running, run: running}), item_noun: @bug),
               ".q-wi-bee-line"
             ) ==
               "Qory reads the bug and writes a proposal."
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

    test "says why it closed, or nothing for a reason without words" do
      w = work_item(%{status: :queued, run: %{attempt: 1, of: 3}})

      html = tab(w, earlier_take_ins: [closed_take_in(:adapter_removed)])

      assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
               [
                 "Taken in 13 Oct by Lea",
                 "Closed 4 minutes ago, when its integration was removed",
                 "1 run"
               ]

      for {reason, words} <- [
            last_stage_done: "Every stage done",
            ticket_closed: "Closed when its ticket closed"
          ] do
        html = tab(w, earlier_take_ins: [closed_take_in(reason)])

        assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
                 ["Taken in 13 Oct by Lea", words, "1 run"]
      end

      for reason <- [nil, :unknown] do
        html = tab(w, earlier_take_ins: [closed_take_in(reason)])

        assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
                 ["Taken in 13 Oct by Lea", "1 run"]
      end
    end
  end

  describe "the fields' length in the browser" do
    test "each takes twice what the server takes" do
      html = tab(questions_item(), can_act: true)
      assert attr(html, "textarea", "maxlength") == ["4000", "4000"]

      html = tab(work_item(%{}), can_act: true)
      assert attr(html, "textarea", "maxlength") == ["4000"]
    end
  end

  describe "a run the gateway refused for want of a model key" do
    @key_fix "Add a model key in Organisation settings › Model providers."

    defp refused(detail) do
      run(%{
        id: "rn_01aa52d07c4a91e6",
        number: 16,
        path: "/8wonders/main/runs/16",
        state: :failed,
        outcome: :error,
        end_cause: :run_refused,
        end_detail: detail,
        proposal: nil,
        ended_at: ago(3600),
        duration: "4 minutes"
      })
    end

    test "the step card puts the fix first and keeps the run's link" do
      html = card(work_item(%{number: 97, status: :no_result, run: refused("model_key_missing")}))

      assert text(html, "#work-item-step-line") ==
               @key_fix <> " The gateway had no model key for attempt 1."

      assert attr(html, "#work-item-step-line a", "href") == [
               "/8wonders/main/runs/16"
             ]

      refute html =~ "ended with an error"
    end

    test "Explore's tab says the run ended before it started, then the fix and why" do
      html = tab(work_item(%{number: 97, status: :no_result, run: refused("model_key_missing")}))

      assert text(html, "#work-item-explore-none-h") == "The run did not start."

      assert texts(html, "#work-item-explore-none p") == [
               "The run did not start.",
               @key_fix <> " The gateway had no model key for the run.",
               "The page of attempt 1 shows what it did."
             ]

      refute html =~ "ended with an error"
    end

    test "the Thread's line puts the fix first and names the run" do
      html =
        event(
          kind: :no_result,
          run: run(%{}),
          outcome: :error,
          end_cause: :run_refused,
          end_detail: "model_key_missing"
        )

      assert line(html) ==
               @key_fix <> " The gateway had no model key for attempt 1 14 Oct, 11:25"

      assert attr(html, "p a", "href") == ["/8wonders/main/runs/12"]
      assert count(html, ".q-wi-ev-bad") == 1
    end

    test "another refusal code, or another end cause, keeps the words for an error" do
      for r <- [refused("image_user_root"), %{refused(nil) | end_cause: :run_ended}] do
        item = work_item(%{number: 97, status: :no_result, run: r})

        assert text(card(item), "#work-item-step-line") ==
                 "Attempt 1 ended with an error, so Explore has no result."

        assert text(tab(item), "#work-item-explore-none-h") == "The run ended with an error."

        thread =
          event(
            kind: :no_result,
            run: r,
            outcome: :error,
            end_cause: r.end_cause,
            end_detail: r.end_detail
          )

        assert line(thread) ==
                 "Attempt 1 ended with an error, so Explore has no result 14 Oct, 11:25"

        refute thread =~ "model key"
      end
    end

    test "at attempt 3 of 3, the step card puts the fix first and keeps that no run is left" do
      r = %{refused("model_key_missing") | attempt: 3}
      html = card(work_item(%{number: 97, status: :no_result, run: r}), can_close: true)

      assert text(html, ".q-wi-badge") == "3 of 3 attempts used"

      assert text(html, "#work-item-step-line") ==
               @key_fix <>
                 " The gateway had no model key for attempt 3. That was attempt 3 of 3, the last attempt of this take in."

      assert attr(html, "#work-item-step-line a", "href") == [
               "/8wonders/main/runs/16"
             ]

      assert count(html, "#work-item-step-ways") == 1
      refute html =~ "ended without a result"
    end

    test "at attempt 3 of 3, Explore's tab and the Thread keep the fix" do
      r = %{refused("model_key_missing") | attempt: 3}
      html = tab(work_item(%{number: 97, status: :no_result, run: r}), can_act: true)

      assert texts(html, "#work-item-explore-none p") == [
               "The run did not start.",
               @key_fix <> " The gateway had no model key for the run.",
               "The page of attempt 3 shows what it did."
             ]

      thread =
        event(
          kind: :no_result,
          run: r,
          outcome: :error,
          end_cause: :run_refused,
          end_detail: "model_key_missing"
        )

      assert line(thread) ==
               @key_fix <> " The gateway had no model key for attempt 3 14 Oct, 11:25"
    end

    test "at attempt 3 of 3, another refusal code keeps the words for the run limit" do
      r = %{refused("image_user_root") | attempt: 3}
      html = card(work_item(%{number: 97, status: :no_result, run: r}))

      assert text(html, "#work-item-step-line") ==
               "Attempt 3 ended without a result. That was attempt 3 of 3, the last attempt of this take in."

      refute html =~ "model key"
    end
  end
end
