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
  import Phoenix.Component, only: [sigil_H: 2]

  alias ApiaryWeb.RichText
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

  ## How to do it

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

  # app.css without its comments.
  defp app_css do
    File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    |> String.replace(~r{/\*.*?\*/}s, "")
  end

  defp card(w, extra \\ []) do
    render_component(
      &C.step_card/1,
      Keyword.merge([work_item: w, integration: "GitHub", can_act: true, now: @now], extra)
    )
  end

  defp tab(w, extra \\ []) do
    render_component(&C.explore_tab/1, Keyword.merge([work_item: w, now: @now], extra))
  end

  ## Links to a run

  describe "the texts about one run" do
    @run_page "/acme/main/runs/43"
    # Before its run row exists, a queued run has no page.
    @no_row %{id: nil, number: nil, path: nil, attempt: 3, of: 3, state: nil}

    defp pending_run(attempt), do: %{running_run(attempt) | state: :pending, started_at: nil}

    defp links(html, selector),
      do:
        for(
          a <- html |> query(selector <> " a"),
          do: {LazyHTML.text(a) |> squish(), LazyHTML.attribute(a, "href")}
        )

    test "the wait block has one link: its heading, with the number; its sentence is plain" do
      for {status, run, words, line} <- [
            {:running, running_run(3), "Explore is running (Run 43).",
             "Attempt 3 reads the ticket, then writes a proposal and questions."},
            {:running, Map.merge(running_run(3), %{sent: true, sent_by: nil}),
             "Explore is running again, with the comments (Run 43).",
             "Attempt 3 reads the ticket, the newest proposal and the comments, then writes the next proposal and questions."},
            {:queued, pending_run(3), "Explore is queued (Run 43).",
             "Attempt 3 starts when the workspace's pool takes it. It reads the ticket, then writes a proposal and questions."},
            {:queued, Map.merge(pending_run(3), %{sent: true, sent_by: nil}),
             "Explore is queued again, with the comments (Run 43).",
             "Attempt 3 starts when the workspace's pool takes it. It reads the ticket, the newest proposal and the comments."}
          ] do
        html = tab(invoice_item(%{status: status, run: run}))

        assert links(html, "#work-item-explore-wait") == [{words, [@run_page]}]
        assert attr(html, "#work-item-explore-wait-h a", "class") == ["text-accent"]
        assert text(html, "#work-item-explore-wait p + p") == line

        # The line above the block and Details stay.
        assert links(html, "#work-item-explore-run") == [{"Attempt 3 (Run 43)", [@run_page]}]
      end
    end

    test "a test work item's lines link too" do
      w = work_item(%{test: true, status: :running, run: running_run(3)})
      html = tab(w, test: true)

      assert links(html, "#work-item-explore-wait-h") ==
               [{"Explore is running (Run 43).", [@run_page]}]

      assert links(html, "#work-item-explore-wait p + p") == []
      assert text(html, "#work-item-explore-wait p + p") =~ "In attempt 3, the agent writes"
    end

    test "the head's status and the step card, running and queued" do
      for {status, run, words} <- [
            {:running, running_run(3), "Explore is running"},
            {:queued, pending_run(3), "Explore is queued"}
          ] do
        w = invoice_item(%{status: status, run: run})
        html = render_component(&C.work_item_status/1, work_item: w, can_act: false)
        assert links(html, ".q-wi-st") == [{words, [@run_page]}]
      end

      running = card(invoice_item(%{status: :running, run: running_run(3)}))
      assert text(running, ".q-wi-step-h") == "Explore Running Run 43"
      assert links(running, ".q-wi-step-h") == [{"Run 43", [@run_page]}]
      assert attr(running, "#work-item-step-run-link", "class") |> hd() =~ "text-accent"
      assert links(running, "#work-item-step-line") == []
      assert text(running, "#work-item-step-line") =~ "Explore reads the ticket"

      queued = card(invoice_item(%{status: :queued, run: pending_run(3)}))
      assert text(queued, ".q-wi-step-h") == "Explore Queued Run 43"
      assert links(queued, ".q-wi-step-h") == [{"Run 43", [@run_page]}]
      assert links(queued, ".q-wi-icon-line") == []
      assert text(queued, ".q-wi-icon-line") =~ "When the run starts, Explore reads"
      assert links(queued, "#work-item-step-run") == []
      assert text(queued, "#work-item-step-run") == "Attempt 3 is queued."
    end

    test "an older run's link has that run's number, not the newest's" do
      older = %{running_run(1) | state: :completed, outcome: :none, ended_at: ago(600)}
      older = Map.merge(older, %{id: "rn_older", number: 40, path: "/acme/main/runs/40"})

      html =
        tab(invoice_item(%{status: :running, run: running_run(2)}), earlier_runs: [older])

      assert links(html, "#work-item-explore-run") == [{"Attempt 2 (Run 43)", [@run_page]}]

      assert links(html, "#work-item-record-40") ==
               [{"Attempt 1 (Run 40)", ["/acme/main/runs/40"]}]
    end

    test "with no path, a run's number and link are both left out" do
      run = %{running_run(3) | path: nil}
      html = tab(invoice_item(%{status: :running, run: run}))
      refute html =~ "(Run 43)"
      assert count(html, "a[href*='/runs/']") == 0

      card = card(invoice_item(%{status: :running, run: run}))
      assert text(card, ".q-wi-step-h") == "Explore Running"
      assert count(card, "a[href*='/runs/']") == 0

      details =
        render_component(&C.work_item_status/1,
          work_item: invoice_item(%{status: :running, run: run}),
          can_act: false
        )

      assert text(details, ".q-wi-st") == "Explore is running"
      assert links(details, ".q-wi-st") == []
    end

    test "the head's status has no run number" do
      w = invoice_item(%{status: :running, run: running_run(3)})
      html = render_component(&C.work_item_status/1, work_item: w, can_act: false)
      assert text(html, ".q-wi-st") == "Explore is running"
      refute html =~ "(Run"
    end

    test "a run's dot: alive pulses in blue, quiet is amber and still, queued and no state stay" do
      item = fn status, liveness ->
        run = Map.merge(running_run(3), %{liveness: liveness, other_stage: false})
        invoice_item(%{status: status, run: run})
      end

      head = fn w -> render_component(&C.work_item_status/1, work_item: w, can_act: false) end

      for html <- [card(item.(:running, :alive)), head.(item.(:running, :alive))] do
        assert count(html, ".q-sdot.q-sdot-running > i.q-ripple") == 1
        assert count(html, ".q-alive-amber") == 0
        assert count(html, ".q-wi-mk-run") == 0
        assert count(html, ".text-success") == 0
      end

      for html <- [card(item.(:running, :quiet)), head.(item.(:running, :quiet))] do
        assert count(html, ".q-sdot.q-sdot-running > .q-dot.q-alive-amber") == 1
        assert count(html, ".q-ripple") == 0
        assert count(html, ".q-wi-mk-run") == 0
        assert count(html, ".text-success") == 0
      end

      # A run with no state to read has the blue dot, with no ring.
      for html <- [card(item.(:running, nil)), head.(item.(:running, nil))] do
        assert count(html, ".q-sdot.q-sdot-running > i[class~='after:hidden']") == 1
        assert count(html, ".q-ripple") == 0
        assert count(html, ".q-dot") == 0
        assert count(html, ".q-wi-mk-run") == 0
      end

      for html <- [card(item.(:queued, nil)), head.(item.(:queued, nil))] do
        assert count(html, ".q-wi-mk-todo") == 1
        assert count(html, ".q-dot") == 0
        assert count(html, ".q-sdot-running") == 0
      end
    end

    test "a running run's badge and word have the Runs page's colours" do
      item = fn liveness ->
        run = Map.merge(running_run(3), %{liveness: liveness, other_stage: false})
        invoice_item(%{status: :running, run: run})
      end

      earlier = %{running_run(1) | state: :completed, outcome: :none, ended_at: ago(600)}
      earlier = Map.merge(earlier, %{id: "rn_older", number: 40, path: "/acme/main/runs/40"})

      for {liveness, soft, word} <- [
            {:alive, "bg-info-soft", "text-info-soft-content"},
            {nil, "bg-info-soft", "text-info-soft-content"},
            {:quiet, "bg-primary-soft", "text-primary-soft-content"}
          ] do
        badge = card(item.(liveness))
        assert count(badge, ".q-wi-badge.#{soft}") == 1
        assert text(badge, ".q-wi-badge") == "Running"
        assert count(badge, ".bg-success-soft") == 0

        html = tab(item.(liveness), earlier_runs: [earlier])
        assert texts(html, "#work-item-explore-run .#{word}") == ["Running"]
        assert texts(html, "#work-item-record-43 .#{word}") == ["Running"]
        assert count(html, "#work-item-record-40 .#{word}") == 0

        assert items(html, "work-item-explore-run") ==
                 ["Attempt 3 (Run 43)", "Running", "started 2 minutes ago"]
      end
    end

    test "a queued run's badge and word are unchanged, and an ended run has no running colour" do
      queued = invoice_item(%{status: :queued, run: pending_run(3)})
      assert text(card(queued), ".q-wi-badge") == "Queued"
      assert count(card(queued), ".bg-info-soft") == 0
      assert count(card(queued), ".bg-success-soft") == 0
      assert count(tab(queued), "#work-item-explore-run .text-info-soft-content") == 0

      earlier = %{running_run(1) | state: :completed, outcome: :none, ended_at: ago(600)}
      earlier = Map.merge(earlier, %{id: "rn_older", number: 40, path: "/acme/main/runs/40"})
      html = tab(invoice_item(%{status: :running, run: running_run(2)}), earlier_runs: [earlier])
      assert count(html, "#work-item-record-40 .text-info-soft-content") == 0
    end

    test "before its run row exists, a queued run's texts are words, unchanged" do
      for {status, run, line} <- [
            {:queued, @no_row, "Attempt 3 is queued."},
            {:queued, %{@no_row | attempt: 2}, "Attempt 2 is queued."}
          ] do
        w = invoice_item(%{status: status, run: run})

        assert count(tab(w), "a[href*='/runs/']") == 0
        assert count(card(w), "a[href*='/runs/']") == 0
        assert text(card(w), "#work-item-step-run") == line
        assert text(tab(w), "#work-item-explore-wait-h") == "Explore is queued."

        html = render_component(&C.work_item_status/1, work_item: w, can_act: false)
        assert count(html, "a") == 0
        assert text(html, ".q-wi-st") == "Explore is queued"
      end
    end

    test "attempt 1 before its run row exists: the step card's line is words, with Undo" do
      w = invoice_item(%{status: :queued, run: %{@no_row | attempt: 1}})
      html = card(w, can_undo: true)

      assert count(html, "a[href*='/runs/']") == 0
      assert text(html, ".q-wi-icon-line") =~ "When the run starts, Explore reads"
      assert count(html, "#work-item-step-undo") == 1
      assert count(html, "#work-item-step-run") == 0
    end

    test "an earlier attempt's fold has the link with its number; other folds have none" do
      take_in = %{
        taken_in_by: @dana,
        taken_in_at: ~U[2026-10-16 15:20:00Z],
        ended: :closed,
        ended_by: @dana,
        ended_at: ago(4 * 60),
        runs: [run1_answered(), run(%{id: "rn_01aa47c9b05e3f18", number: 15, attempt: 2})]
      }

      wrote = %{running_run(1) | state: :completed, outcome: :proposal}

      wrote =
        Map.merge(wrote, %{
          id: "rn_0000000000000041",
          number: 41,
          path: "/acme/main/runs/41",
          wrote: 1,
          wrote_proposal: proposal_v(1)
        })

      html =
        tab(invoice_item(%{status: :running, run: running_run(2)}),
          earlier_runs: [wrote],
          earlier_take_ins: [take_in]
        )

      assert count(html, "summary") > 1

      assert links(html, "#work-item-record-41 > summary") ==
               [{"Attempt 1 (Run 41)", ["/acme/main/runs/41"]}]

      assert attr(html, "#work-item-record-41 > summary a", "class") == ["text-accent"]

      # The run with no page: the same line, with no link and no number.
      plain = %{wrote | path: nil}
      html = tab(invoice_item(%{status: :running, run: running_run(2)}), earlier_runs: [plain])

      assert links(html, "#work-item-record-41 > summary") == []
      assert text(html, "#work-item-record-41 > summary") =~ "Attempt 1"
      refute text(html, "#work-item-record-41 > summary") =~ "(Run"

      # The fold of the runs is about no one run.
      assert links(html, "#work-item-record-fold > summary") == []
    end

    test "the form line links the words Attempt 3, and is words where the run has no page" do
      linked = C.send_error({:running, running_run(3)})

      assert RichText.plain_text(linked) ==
               "Send it again when attempt 3 ends. Attempt 3 (Run 43) started first, so nothing was sent."

      assert [{:link, @run_page, numbered, "text-accent"}] = Enum.filter(linked, &is_tuple/1)
      assert RichText.plain_text(numbered) == "Attempt 3 (Run 43)"
      assert C.comment_error({:running, running_run(3)}, :comment) == linked

      refute Enum.any?(C.send_error({:running, @no_row}), &is_tuple/1)
    end

    test "a run that ended: the card's line links the words Attempt 3" do
      ended = %{running_run(3) | started_at: ago(600), ended_at: ago(60)}

      for {status, overrides, line} <- [
            {:lost, %{state: :lost}, "Attempt 3 (Run 43) was lost before it ended"},
            {:cancelled, %{state: :cancelled},
             "Attempt 3 (Run 43) was cancelled before it ended"},
            {:no_result, %{state: :completed, outcome: :none},
             "Attempt 3 (Run 43) ended without a result."},
            {:no_result, %{state: :failed, outcome: :error},
             "Attempt 3 (Run 43) ended with an error"}
          ] do
        run = ended |> Map.merge(overrides) |> Map.put(:of, 5)
        html = card(invoice_item(%{status: status, run: run}))

        assert links(html, "#work-item-step-line") == [{"Attempt 3 (Run 43)", [@run_page]}]
        assert text(html, "#work-item-step-line") =~ line

        assert attr(
                 tab(invoice_item(%{status: status, run: run})),
                 "#work-item-explore-none-h a",
                 "href"
               ) ==
                 [@run_page]
      end

      failed = Map.merge(ended, %{state: :failed, wrote: 2, of: 5})
      html = card(invoice_item(%{status: :no_result, run: failed}))

      assert links(html, "#work-item-step-line") ==
               [{"The run failed after it wrote proposal version 2 (Run 43).", [@run_page]}]
    end
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

    test "a failed run that wrote a proposal: Explore's run failed, at the header too" do
      failed = run(%{attempt: 2, state: :failed, outcome: :error, wrote: 2})
      w = work_item(%{status: :no_result, run: failed})
      assert C.status_words(w) == "Explore's run failed"
      assert C.mark(w) == :err

      html =
        render_component(&C.work_item_header/1,
          work_item: w,
          integration: "GitHub",
          link: "https://apiary.example.com/8wonders/main/work/88"
        )

      assert text(html, ".q-wi-meta .q-wi-st") == "Explore's run failed"

      # A failed run that wrote nothing, and a run that wrote a proposal and was lost.
      assert C.status_words(%{w | run: %{failed | wrote: nil}}) ==
               "Explore ended without a result"

      assert C.status_words(%{w | status: :lost, run: %{failed | state: :lost}}) ==
               "Explore's run was lost"

      # At the take in's last run, the run limit's words.
      assert C.status_words(%{w | run: %{failed | attempt: 3}}) == "Explore used its 3 runs"
    end

    test "a proposal that waits after its work item left Explore waits for no one" do
      # The reader (`@dana`) owns the work item, or may confirm.
      for w <- [work_item(%{}), work_item(%{confirmers: :you})] do
        assert C.hot?(w)
        assert C.mark(w) == :wait

        left = Map.put(w, :at_explore, false)
        refute C.hot?(left)
        assert C.mark(left) == :wait_other
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
             "You took this in again just now. Until a run starts, you can undo the take in: the work item goes back to closed, and Qory Apiary changes nothing on the ticket."},
            {:closed, @priya,
             "Priya took this in again just now. Until a run starts, you can undo the take in: the work item goes back to closed, and Qory Apiary changes nothing on the ticket."}
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
             "You took this in just now. Until a run starts, you can undo the take in: Qory Apiary removes its label from the ticket."},
            {@priya,
             "Priya took this in just now. Until a run starts, you can undo the take in: Qory Apiary removes its label from the ticket."}
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
               "Qory Apiary removed its label from the ticket and left its comment. To bring the work item back, use Take in again."
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
               "You took this in just now. Until a run starts, you can undo the take in. GitHub is no longer connected, so the label and the comment that Qory Apiary added stay on the ticket."
    end
  end

  describe "step_card/1, Explore queued and running, a later run" do
    test "queued with answers: whose answers it reads, which run, and no Undo" do
      for {people, line} <- [
            {[@dana],
             "When the run starts, Explore reads the ticket and your answers, and writes a proposal."},
            {[@priya],
             "When the run starts, Explore reads the ticket and the answers of Priya, and writes a proposal."},
            {[@dana, @priya],
             "When the run starts, Explore reads the ticket and the answers of this take in, and writes a proposal."},
            {[@priya, %{@priya | name: "Priya"}],
             "When the run starts, Explore reads the ticket and the answers of Priya, and writes a proposal."},
            {[], "When the run starts, Explore reads the ticket and writes a proposal."}
          ] do
        w = work_item(%{status: :queued, run: %{attempt: 2, of: 3, answers_by: people}})
        html = card(w, can_undo: true)

        assert text(html, ".q-wi-badge") == "Queued"
        assert text(html, ".q-wi-icon-line") == line
        assert text(html, "#work-item-step-run") == "Attempt 2 is queued."
        assert count(html, "#work-item-step-undo") == 0
        assert count(html, "button") == 0
      end
    end

    test "running n of 3: whose answers Explore reads, in one line" do
      for {people, line} <- [
            {[], "Explore reads the ticket and writes a proposal."},
            {[@dana], "Explore reads the ticket and your answers, and writes a proposal."},
            {[@priya],
             "Explore reads the ticket and the answers of Priya, and writes a proposal."},
            {[@dana, @priya],
             "Explore reads the ticket and the answers of this take in, and writes a proposal."}
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
        assert text(html, "#work-item-step-line") == line
        assert count(html, "#work-item-step p") == 1
        assert count(html, "#work-item-step-run") == 0
        assert count(html, ".q-wi-play") == 0
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
      html = asked(3, explore_path: "/8wonders/main/work/94/explore", commenting: true)

      assert text(html, "h2") == "Explore"
      assert text(html, ".q-wi-badge") == "Needs answers"
      assert count(html, ".q-wi-step-ask") == 1
      assert attr(html, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait"]

      assert text(html, "#work-item-step-line") ==
               "Answer the 3 questions or add a comment, then run another round."

      assert count(html, ".q-wi-play") == 0

      assert text(html, "#work-item-step-explore") == "Answer the questions"
      assert attr(html, "#work-item-step-explore", "href") == ["/8wonders/main/work/94/explore"]
      assert count(html, "button") == 0
    end

    test "one question; on Explore's tab, no link" do
      html = asked(1, commenting: true)

      assert text(html, "#work-item-step-line") ==
               "Answer the question or add a comment, then run another round."

      assert count(html, "#work-item-step-explore") == 0

      linked = asked(1, explore_path: "/8wonders/main/work/94/explore")
      assert text(linked, "#work-item-step-explore") == "Answer the question"
    end

    test "where Explore's tab has no comment field, the line names only the answers" do
      assert text(asked(1), "#work-item-step-line") ==
               "Answer the question, then run another round."

      assert text(asked(3), "#work-item-step-line") ==
               "Answer the 3 questions, then run another round."
    end

    test "a reader who may not act: that a member answers next, no button" do
      for {n, waits} <- [
            {3, "Next, a member answers the questions."},
            {1, "Next, a member answers the question."}
          ] do
        html = asked(n, can_act: false, explore_path: "/8wonders/main/work/94/explore")
        assert count(html, "#work-item-step-line") == 0
        refute html =~ "instead of a proposal"
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
             "Attempt 1 (Run 16) ended with an error, so Explore has no result."},
            {:no_result, %{outcome: :none}, "No result",
             "Attempt 1 (Run 16) ended without a result."},
            {:no_result, %{outcome: :refused}, "No result",
             "Attempt 1 (Run 16) returned a result that did not pass Qory Apiary's check, so Explore has no result."},
            {:lost, %{state: :lost, outcome: nil}, "Lost",
             "Attempt 1 (Run 16) was lost before it ended, so Explore has no result."},
            {:cancelled, %{state: :cancelled, outcome: nil}, "Cancelled",
             "Attempt 1 (Run 16) was cancelled before it ended, so Explore has no result."}
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
        assert text(html, "#work-item-step-next") == "Run Explore again starts attempt 2."

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
               "1 question is still open after attempt 3 of 3 (Run 15), the last attempt of this take in."

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
               "2 questions are still open after attempt 3 of 3 (Run 15), the last attempt of this take in."

      none = used(%{state: :failed, outcome: :error})

      assert text(none, "#work-item-step-line") ==
               "Attempt 3 (Run 15) ended without a result. That was attempt 3 of 3, the last attempt of this take in."
    end

    test "Close only with the right to close; a reader who may not act reads why, and nothing to do" do
      assert count(used(%{}, can_close: false), "#work-item-step-close") == 0

      reader = used(%{}, can_act: false, can_close: true)
      assert text(reader, "#work-item-step-line") =~ "1 question is still open"
      assert count(reader, "#work-item-step-ways") == 0
      assert count(reader, "button") == 0
      assert attr(reader, ".q-wi-step-h .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-wait_other"]
    end
  end

  describe "step_card/1, Confirm" do
    test "the line and Read the proposal; no Confirm and no Change" do
      html = card(work_item(%{}), explore_path: "/8wonders/main/work/88/explore")

      assert text(html, "#work-item-step-line") ==
               "Approve the proposal, or add a comment and run another round."

      assert count(html, ".q-wi-play") == 0
      assert text(html, "#work-item-step-explore") == "Read the proposal"
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
              {[], "When the run starts, Explore reads the ticket and writes a proposal."},
              {[@dana],
               "When the run starts, Explore reads the ticket and your answers, and writes a proposal."},
              {[@priya],
               "When the run starts, Explore reads the ticket and the answers of Priya, and writes a proposal."},
              {[@dana, @priya],
               "When the run starts, Explore reads the ticket and the answers of this take in, and writes a proposal."}
            ] do
          w = work_item(%{status: :queued, run: %{attempt: 2, of: 3, answers_by: people}})
          assert text(card(w), ".q-wi-icon-line") == line
        end

        assert text(asked(3), "#work-item-step-line") ==
                 "Answer the 3 questions, then run another round."

        assert text(card(work_item(%{})), "#work-item-step-line") ==
                 "Approve the proposal, or add a comment and run another round."
      end)
    end
  end

  ## Explore's tab as concept A: neutral example data, Acme / Main, ticket #41

  @invoice """
  ## Facts

  The invoice PDF prints the shop's currency, not the order's.

  ## Proposed solution

  - Read the currency from the order.
  - Print it in the PDF header.
  """

  @sourced @invoice <>
             """

             ## Sources

             - [Invoice template](https://docs.example.org/invoice)
               - [Its header](https://docs.example.org/invoice#header)
             - [Currency notes](https://docs.example.org/currency)
             """

  defp proposal_v(version, message \\ @invoice),
    do: %{version: version, message: message}

  defp q(number, overrides \\ %{}) do
    Map.merge(
      %{
        id: "q#{number}",
        number: number,
        text: "Question #{number}?",
        context: nil,
        options: [],
        state: :open,
        asked_run: 41,
        answer: nil,
        history: [],
        follows: []
      },
      overrides
    )
  end

  defp currency_options do
    [
      %{title: "The order's currency", explanation: "Each invoice shows what the customer paid."},
      %{title: "The shop's currency", explanation: "Every invoice shows one currency."}
    ]
  end

  defp given(by, option, note, seconds),
    do: %{option: option, note: note, by: by, at: ago(seconds)}

  defp invoice_questions do
    [
      q(1, %{
        text: "Which currency should the PDF show?",
        context: "The order keeps its **currency**.",
        options: currency_options(),
        state: :answered,
        answer: given(@dana, "The order's currency", nil, 3600)
      }),
      q(2, %{
        text: "Should the credit note PDF change too?",
        context: "The template change affects only the credit notes of bank refunds.",
        options: [%{title: "Yes", explanation: nil}, %{title: "No", explanation: nil}],
        history: [given(@priya, "No", "Only invoices.", 7200)],
        follows: [1]
      }),
      q(3, %{text: "Should customers get corrected PDFs for invoices already sent?"}),
      q(4, %{text: "Is the old template still used?", state: :withdrawn})
    ]
  end

  defp acme_run(overrides) do
    run(
      Map.merge(
        %{
          id: "rn_0000000000000041",
          number: 41,
          path: "/acme/main/runs/41",
          workspace_id: "ws_main"
        },
        overrides
      )
    )
  end

  defp invoice_item(overrides \\ %{}) do
    work_item(
      Map.merge(
        %{
          number: 41,
          title: "Invoice PDF shows the wrong currency",
          key: "#41",
          url: "https://example.com/acme/main/issues/41",
          repository: "acme/main",
          run: acme_run(%{attempt: 2, version: 2, wrote: 2})
        },
        overrides
      )
    )
  end

  defp running_run(attempt),
    do:
      acme_run(%{
        id: "rn_0000000000000043",
        number: 43,
        path: "/acme/main/runs/43",
        attempt: attempt,
        state: :running,
        started_at: ago(120),
        ended_at: nil,
        outcome: nil,
        proposal: nil,
        version: nil
      })

  defp comment(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        text: "Show the currency code beside the total.",
        by: @dana,
        version: 1,
        state: :open,
        reopened: false,
        replies: []
      },
      overrides
    )
  end

  defp run_reply(outcome, version, overrides \\ %{}) do
    Map.merge(
      %{
        run: 42,
        by: nil,
        text: "The header shows the code now.",
        outcome: outcome,
        question_number: nil,
        version: version
      },
      overrides
    )
  end

  describe "explore_tab/1, queued and running" do
    test "queued, the first run: Attempt 1, Queued, and what the attempt reads" do
      html = tab(work_item(%{number: 341, status: :queued, run: %{attempt: 1, of: 3}}))

      assert items(html, "work-item-explore-run") == ["Attempt 1", "Queued"]
      assert text(html, "#work-item-explore-wait-h") == "Explore is queued."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Attempt 1 starts when the workspace's pool takes it. It reads the ticket, then writes a proposal and questions."

      assert attr(html, "#work-item-explore-wait .q-xp-wait-i", "class") |> hd() =~
               "hero-arrow-path"

      assert count(html, ".q-xp-frame") == 0
      assert count(html, ".q-wi-play") == 0
    end

    test "a run that a send of review comments started: the review comments, yours for the member who sent them" do
      queued = invoice_item(%{status: :queued, run: %{attempt: 3, of: 3, sent: true}})
      wait = "#work-item-explore-wait p:last-child"

      assert text(tab(queued, earlier_runs: [run1_answered(), run2_answered()]), wait) ==
               "Attempt 3 starts when the workspace's pool takes it. It reads the ticket, the newest proposal and the comments."

      for {sent_by, words} <- [
            {%{id: "u1", name: "Dana", email: "dana@example.com", you: true}, "your comments"},
            {%{id: "u2", name: "Lee", email: "lee@example.com", you: false}, "the comments"},
            {nil, "the comments"}
          ] do
        running = Map.merge(running_run(3), %{sent: true, sent_by: sent_by})

        html =
          tab(invoice_item(%{status: :running, run: running}),
            earlier_runs: [run1_answered(), run2_answered()]
          )

        assert text(html, wait) ==
                 "Attempt 3 reads the ticket, the newest proposal and #{words}, then writes the next proposal and questions."
      end

      # A run that answers started keeps the words of the answers.
      answered = Map.merge(running_run(3), %{sent: false, sent_by: nil})

      html =
        tab(invoice_item(%{status: :running, run: answered}),
          earlier_runs: [run1_answered(), run2_answered()]
        )

      assert text(html, wait) ==
               "Attempt 3 reads the ticket, the newest proposal and the questions with their answers, then writes the next proposal and questions."
    end

    test "a run that a send of review comments started, after answers in the take in: the heading of the review comments" do
      earlier = [run1_answered(), run2_answered()]
      heading = "#work-item-explore-wait-h"
      dana = %{id: "u1", name: "Dana", email: "dana@example.com", you: true}
      lee = %{id: "u2", name: "Lee", email: "lee@example.com", you: false}

      for {sent_by, queued, running} <- [
            {dana, "Explore is queued again, with your comments.",
             "Explore is running again, with your comments (Run 43)."},
            {lee, "Explore is queued again, with the comments.",
             "Explore is running again, with the comments (Run 43)."}
          ] do
        run = %{attempt: 3, of: 3, sent: true, sent_by: sent_by}
        html = tab(invoice_item(%{status: :queued, run: run}), earlier_runs: earlier)
        assert text(html, heading) == queued

        run = Map.merge(running_run(3), %{sent: true, sent_by: sent_by})
        html = tab(invoice_item(%{status: :running, run: run}), earlier_runs: earlier)
        assert text(html, heading) == running
      end

      # A run that answers started keeps the heading of the answers.
      for {status, run, words} <- [
            {:queued, %{attempt: 3, of: 3, sent: false, sent_by: nil},
             "Explore is queued again, with the answers of this take in."},
            {:running, Map.merge(running_run(3), %{sent: false, sent_by: nil}),
             "Explore is running again, with the answers of this take in (Run 43)."}
          ] do
        html = tab(invoice_item(%{status: status, run: run}), earlier_runs: earlier)
        assert text(html, heading) == words
      end
    end

    test "a pending run reads Queued too" do
      r = run(%{state: :pending, attempt: 1, ended_at: nil})
      html = tab(work_item(%{status: :queued, run: r}))
      assert items(html, "work-item-explore-run") == ["Attempt 1 (Run 12)", "Queued"]
    end

    test "running with answers: the wait block, then the proposal and the questions as text" do
      w = invoice_item(%{status: :running, run: running_run(3)})

      html =
        tab(w,
          can_act: true,
          earlier_runs: [run1_answered(), run2_answered()],
          proposal: proposal_v(2),
          questions: invoice_questions(),
          questions_version: 2,
          review_comments: [comment("rc1")],
          reply_path: &"/acme/main/work/41/explore?reply=#{&1}"
        )

      assert items(html, "work-item-explore-run") ==
               ["Attempt 3 (Run 43)", "Running", "started 2 minutes ago"]

      assert text(html, "#work-item-explore-wait-h") ==
               "Explore is running again, with the answers of this take in (Run 43)."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Attempt 3 reads the ticket, the newest proposal and the questions with their answers, then writes the next proposal and questions."

      assert attr(html, "#work-item-explore > *", "id") == [
               "work-item-explore-run",
               "work-item-explore-wait",
               "work-item-explore-proposal",
               "work-item-explore-questions",
               "work-item-record"
             ]

      # While a run runs: no Add review comment, no gate, no form, no Reply.
      assert count(html, "#work-item-explore-proposal-review-add") == 0
      assert count(html, "#work-item-explore-gate") == 0
      assert count(html, "form") == 0
      assert count(html, "textarea, input") == 0
      assert count(html, "button[type=submit]") == 0
      assert count(html, "[id$='-reply']") == 0

      # The open questions as text, with their options; the card shows that the run reads it.
      assert count(html, "#work-item-explore-questions-cap") == 0
      assert texts(html, "#work-item-explore-questions-question-2 .q-xp-opt-t") == ["Yes", "No"]

      assert text(html, "#work-item-explore-proposal-review-rc1-reading") ==
               "Attempt 3 (Run 43) reads this comment."
    end

    test "the first run running: no answers, no frames" do
      r = run(%{state: :running, started_at: ago(6 * 60), ended_at: nil})
      html = tab(work_item(%{status: :running, run: r}))

      assert text(html, "#work-item-explore-wait-h") == "Explore is running (Run 12)."

      assert text(html, "#work-item-explore-wait p:last-child") ==
               "Attempt 1 reads the ticket, then writes a proposal and questions."

      assert count(html, ".q-xp-frame") == 0
    end
  end

  describe "explore_tab/1, the proposal" do
    test "the frame starts under the tabs: Proposal, its version, its Markdown; no run line" do
      html = tab(invoice_item(), proposal: proposal_v(2))
      p = "#work-item-explore-proposal"

      assert count(html, "#work-item-explore-run") == 0
      assert text(html, "#{p}-h") == "Proposal"
      assert attr(html, "#{p} .q-xp-frame-i", "class") |> hd() =~ "hero-document-text"
      assert count(html, "#{p} .q-xp-frame-h .badge") == 0
      assert text(html, "#{p} .q-xp-cap") == "Version 2"
      refute html =~ "wrote this"
      assert texts(html, "#{p}-text h4") == ["Facts", "Proposed solution"]

      assert texts(html, "#{p}-text li") == [
               "Read the currency from the order.",
               "Print it in the PDF header."
             ]

      assert count(html, "#{p}-sources") == 0
      assert count(html, ".q-wi-play") == 0
    end

    test "the header has no Add review comment, also for a reader who may write one" do
      html = tab(invoice_item(), proposal: proposal_v(2), can_send: true)

      assert count(html, "#work-item-explore-proposal-review-add") == 0
      assert count(html, "#work-item-explore-proposal .q-xp-frame-h a") == 0
      refute html =~ "Add review comment"
    end

    test "Background: its first paragraph, the rest in a closed fold behind Read more, with Read less for the open fold" do
      message = """
      ## Summary

      Customers choose a delivery date.

      ## Background

      Customers cannot choose when an order arrives.

      The checkout ships every order on the next working day.

      - Support writes to the carrier.

      ### The carrier

      The carrier offers delivery on a chosen day.

      ## Proposed solution

      Add a delivery date step.
      """

      html = tab(invoice_item(), proposal: proposal_v(2, message))
      t = "#work-item-explore-proposal-text"

      assert count(html, "#{t} details.q-xp-more") == 1
      assert attr(html, "#{t} details.q-xp-more", "open") == []
      # The fold's summary toggles it: Read more opens it, Read less closes it again.
      assert text(html, "#{t} details.q-xp-more > summary > .q-xp-read-more") == "Read more"
      assert text(html, "#{t} details.q-xp-more > summary > .q-xp-read-less") == "Read less"

      assert attr(html, "#{t} details.q-xp-more > summary > span", "class") == [
               "hero-chevron-down-micro size-3.5",
               "q-xp-read-more",
               "q-xp-read-less"
             ]

      # The first paragraph shows, under the heading; the rest of the Background folds,
      # its lower heading too, up to the next heading of its level.
      assert texts(html, "#{t} > p") == [
               "Customers choose a delivery date.",
               "Customers cannot choose when an order arrives.",
               "Add a delivery date step."
             ]

      assert texts(html, "#{t} details.q-xp-more > p") == [
               "The checkout ships every order on the next working day.",
               "The carrier offers delivery on a chosen day."
             ]

      assert texts(html, "#{t} details.q-xp-more li") == ["Support writes to the carrier."]
      assert texts(html, "#{t} details.q-xp-more h5") == ["The carrier"]
      assert texts(html, "#{t} > h4") == ["Summary", "Background", "Proposed solution"]
    end

    test "Background with one paragraph, or none: no fold" do
      one = """
      ## Background

      Customers cannot choose when an order arrives.

      ## Proposed solution

      Add a delivery date step.

      More words after it.
      """

      for message <- [one, @invoice] do
        html = tab(invoice_item(), proposal: proposal_v(2, message))
        assert count(html, "details.q-xp-more") == 0
        refute html =~ "Read more"
        refute html =~ "Read less"
      end
    end

    test "fold_background/1: the CSS shows Read more closed and Read less open; other renders stay" do
      css = app_css()
      refute css =~ ~r/\.q-xp-more\[open\] > summary \{/

      assert css =~
               ~r/\.q-xp-more\[open\] > summary > \.q-xp-read-more,\s*\.q-xp-more:not\(\[open\]\) > summary > \.q-xp-read-less \{\s*display: none;/

      assert css =~
               ~r/\.q-xp-more\[open\] > summary > \.hero-chevron-down-micro \{\s*transform: rotate\(180deg\);/

      assert C.fold_background({:as_written, "## Background"}) == {:as_written, "## Background"}
      assert C.fold_background(nil) == nil
    end

    test "Sources: a fold at the foot, closed, with the count of its items and no heading" do
      html = tab(invoice_item(), proposal: proposal_v(2, @sourced))
      s = "#work-item-explore-proposal-sources"

      assert count(html, s) == 1
      assert attr(html, s, "open") == []
      assert text(html, "#{s} > summary") == "Sources (2)"

      assert attr(html, "#{s} a", "href") == [
               "https://docs.example.org/invoice",
               "https://docs.example.org/invoice#header",
               "https://docs.example.org/currency"
             ]

      # The heading goes; the rest of the section shows in the body, before the fold.
      assert texts(html, "#work-item-explore-proposal-text h4") == ["Facts", "Proposed solution"]
      refute text(html, "#work-item-explore-proposal-text") =~ "Currency notes"

      assert attr(html, "#work-item-explore-proposal > *", "class") |> List.last() ==
               "q-xp-sources"
    end

    test "a table in the Markdown has the frame's rules" do
      table = "| A | B |\n|---|---|\n| one | two |\n"
      html = tab(invoice_item(), proposal: proposal_v(2, table))
      assert count(html, "#work-item-explore-proposal .q-xp-md table") == 1

      css = app_css()

      assert css =~
               ~r/\.q-xp-md table,\s*\.q-art-cols \.q-ticket-formatted table \{\s*display: block;\s*overflow-x: auto;\s*scrollbar-color: auto;\s*\}/

      assert css =~
               ~r/\.q-xp-md table::-webkit-scrollbar,\s*\.q-art-cols \.q-ticket-formatted table::-webkit-scrollbar \{\s*height: 8px;\s*\}/

      assert css =~
               ~r/\.q-xp-md table::-webkit-scrollbar-thumb,\s*\.q-art-cols \.q-ticket-formatted table::-webkit-scrollbar-thumb \{\s*border-radius: 4px;/

      assert css =~
               ~r/\.q-xp-md table::-webkit-scrollbar-track,\s*\.q-art-cols \.q-ticket-formatted table::-webkit-scrollbar-track \{\s*background-color:/

      # A cell breaks at spaces only; a long word outside a table still wraps anywhere.
      assert css =~ ~r/\.q-xp-md table \{\s*contain: inline-size;\s*overflow-wrap: normal;\s*\}/
      assert css =~ ~r/\.q-xp-md \{[^}]*overflow-wrap: anywhere;/

      # A table elsewhere in `.q-ticket-formatted`, such as on the Ticket tab, has no frame.
      assert css =~ ~r/\.q-ticket-formatted table \{\s*border-collapse: collapse;\s*\}/

      framed =
        ~r/([^{}]*\.q-ticket-formatted table)\s*\{[^}]*\bdisplay:/
        |> Regex.scan(css, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&squish/1)

      assert framed == [".q-xp-md table, .q-art-cols .q-ticket-formatted table"]
    end

    test "Sources after a Mermaid block and an image: the body shows both, the fold neither" do
      message =
        @invoice <>
          """

          ```mermaid
          flowchart LR
            Order --> Invoice
          ```

          ![Invoice header](header.svg)

          ## Sources

          - [Invoice template](https://docs.example.org/invoice)
          """

      html =
        render_component(&C.proposal_frame/1,
          id: "work-item-explore-proposal",
          run: %{proposal: %{message: message}, version: 2},
          now: @now,
          images: [{"header.svg", "/acme/main/work/41/artifacts/av_2/files/header.svg"}]
        )

      p = "#work-item-explore-proposal"
      assert text(html, "#{p}-v2 pre.q-mermaid-source code") =~ "Order --> Invoice"

      assert attr(html, "#{p}-v2 img", "src") == [
               "/acme/main/work/41/artifacts/av_2/files/header.svg"
             ]

      assert text(html, "#{p}-sources > summary") == "Sources (1)"
      assert count(html, "#{p}-sources img, #{p}-sources pre") == 0
    end

    test "split_sources/1 splits at the last Sources heading, and counts first-level items" do
      {:html, _} =
        rendered = C.markdown("## Sources\n\nIn the text.\n\n## Sources\n\n1. One\n2. Two\n")

      {{:html, body}, sources, 2} = C.split_sources(rendered)
      assert Phoenix.HTML.safe_to_string(body) =~ "In the text."
      assert Phoenix.HTML.safe_to_string(sources) =~ "Two"

      assert {{:as_written, "x"}, nil, 0} = C.split_sources({:as_written, "x"})
      assert {nil, nil, 0} = C.split_sources(nil)

      code = C.markdown("```\n## Sources\n- a\n```\n")
      assert {^code, nil, 0} = C.split_sources(code)
    end

    test "split_sources/1 leaves a Sources heading in a quote or a list in the text" do
      quoted = C.markdown("Intro\n\n> ## Sources\n> - a\n\nAfter the quote.\n\n## Next\n\ntext")
      assert {^quoted, nil, 0} = C.split_sources(quoted)

      listed = C.markdown("- ## Sources\n\n  - a\n\nAfter the list.\n")
      assert {^listed, nil, 0} = C.split_sources(listed)

      {{:html, body}, sources, 1} =
        "Intro\n\n> ## Sources\n> - a\n\nAfter the quote.\n\n## Sources\n\n- b\n"
        |> C.markdown()
        |> C.split_sources()

      body = Phoenix.HTML.safe_to_string(body)

      assert body =~
               ~r{<blockquote>\s*<h4>Sources</h4>\s*<ul>\s*<li>a</li>\s*</ul>\s*</blockquote>}

      assert body =~ "After the quote."
      assert Phoenix.HTML.safe_to_string(sources) =~ "<li>b</li>"
    end

    test "the proposal's text is in the Mermaid hook, its id of the version" do
      mermaid = "Steps:\n\n```mermaid\nflowchart LR\n  Cart --> Invoice\n```\n"
      html = tab(invoice_item(), proposal: proposal_v(2, mermaid))

      p = "#work-item-explore-proposal"
      assert count(html, "#{p} [phx-hook=Mermaid]") == 1
      hook = "#{p}-v2[phx-hook=Mermaid][phx-update=ignore]"
      assert attr(html, hook, "data-script") == ["/assets/js/mermaid.js"]
      assert attr(html, hook, "data-alt") == ["Diagram"]
      assert attr(html, hook, "data-source") == ["Diagram source"]

      assert attr(html, hook, "data-failed") == [
               "This diagram has an error, so it is shown as written."
             ]

      assert attr(html, hook, "data-not-drawn") == [
               "Qory Apiary does not draw this diagram, so it is shown as written."
             ]

      assert text(html, "#{hook} #{p}-text pre.q-mermaid-source code") =~ "Cart --> Invoice"

      # A new version is another block, so the hook draws it again.
      html3 = tab(invoice_item(), proposal: proposal_v(3, mermaid))
      assert count(html3, "#{p}-v3[phx-hook=Mermaid]") == 1
      assert count(html3, "#{p}-v2") == 0
    end

    test "the proposal frame shows the version's images, and no other" do
      message =
        "![Invoice header](checkout.svg)\n\n![x](sources.json) ![Logo](https://example.com/l.png)"

      src = "/acme/main/work/7/artifacts/av_1/files/checkout.svg"

      frame = fn extra ->
        render_component(
          &C.proposal_frame/1,
          [
            id: "work-item-explore-proposal",
            run: run(%{version: 2, proposal: proposal(%{message: message})}),
            now: @now
          ] ++ extra
        )
      end

      html = frame.(images: [{"checkout.svg", src}])
      p = "#work-item-explore-proposal"
      assert attr(html, "#{p}-v2 #{p}-text img", "src") == [src]
      assert attr(html, "#{p}-v2 #{p}-text img", "alt") == ["Invoice header"]
      assert text(html, "#{p}-text") =~ "Image not in this version: x"
      assert text(html, "#{p}-text") =~ "Image: Logo"

      # A version with no images: each file it refers to is not in this version.
      html = frame.(images: [])
      assert count(html, "img") == 0
      assert text(html, "#{p}-text") =~ "Image not in this version: Invoice header"
      assert text(html, "#{p}-text") =~ "Image not in this version: x"

      # Images not given: no image is loaded, and an image is its words.
      html = frame.([])
      assert count(html, "img") == 0
      assert text(html, "#{p}-text") =~ "Image: Invoice header"
      refute text(html, "#{p}-text") =~ "not in this version"
    end

    test "the proposal frame shows no file of the version but an image as an image" do
      message =
        "![a](sources.json) ![b](proposal.md) ![c](notes.txt) ![d](header.SVG) ![e](form.png)"

      files =
        for name <- ~w(sources.json proposal.md notes.txt header.SVG form.png),
            do: {name, "/acme/main/work/7/artifacts/av_1/files/#{name}"}

      html =
        render_component(&C.proposal_frame/1,
          id: "work-item-explore-proposal",
          run: run(%{version: 2, proposal: proposal(%{message: message})}),
          now: @now,
          images: files
        )

      p = "#work-item-explore-proposal-text"

      assert attr(html, "#{p} img", "src") == [
               "/acme/main/work/7/artifacts/av_1/files/header.SVG",
               "/acme/main/work/7/artifacts/av_1/files/form.png"
             ]

      for alt <- ~w(a b c), do: assert(text(html, p) =~ "Image not in this version: #{alt}")
    end

    test "a result stored before the proposal was Markdown shows no text, and does not fail" do
      html = tab(invoice_item(), can_act: true, proposal: %{version: 1, message: nil})

      assert text(html, "#work-item-explore-proposal-h") == "Proposal"
      assert count(html, "#work-item-explore-proposal-text") == 0
      assert count(html, "#work-item-explore-proposal .q-xp-prop") == 0
    end

    test "a hostile proposal: no script, no javascript: link, no image loaded" do
      message = """
      # Plan <script>alert(1)</script>

      <img src="https://img.example.com/x.png" onerror="alert(2)">

      [run this](javascript:alert(3)) and [mail](mailto:team@example.com)

      ![a cat](https://img.example.com/cat.png)

      <a href="https://evil.example.com">raw link</a>
      """

      html = tab(invoice_item(), proposal: proposal_v(2, message))
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
      p = %{version: 2, message: "x", rendered: {:as_written, "Line one\n<b>not bold</b>"}}
      html = tab(invoice_item(), proposal: p)

      assert text(html, "#work-item-explore-proposal-text .q-xp-md-note") == "Shown as written."

      [written] =
        html |> query("#work-item-explore-proposal-text .q-ticket-written") |> Enum.to_list()

      assert LazyHTML.text(written) == "Line one\n<b>not bold</b>"
      assert count(html, "#work-item-explore-proposal-text b") == 0
      assert count(html, "#work-item-explore-proposal-sources") == 0
    end

    test "markdown/1 gives the render, as written past the renderer's bounds, nil for none" do
      assert {:html, _safe} = C.markdown("**bold**")
      assert C.markdown(nil) == nil
      big = String.duplicate("a", ApiaryWeb.ArtifactLive.Markdown.max_bytes() + 1)
      assert C.markdown(big) == {:as_written, big}
    end

    test "confirmed: Confirmed, who and when; no gate and no Add review comment" do
      w = invoice_item(%{status: :shape, confirmed_by: @dana, confirmed_at: ago(30)})
      html = tab(w, can_act: true, proposal: proposal_v(2))
      p = "#work-item-explore-proposal"

      assert text(html, "#{p} .q-xp-frame-h .badge") == "Approved"

      assert text(html, "#{p} .q-xp-cap") ==
               "Version 2. You approved it just now."

      assert count(html, "form, button") == 0

      other =
        tab(%{w | confirmed_by: @priya, confirmed_at: ago(3 * 3600)}, proposal: proposal_v(2))

      assert text(other, "#{p} .q-xp-cap") ==
               "Version 2. Priya approved it 3 hours ago."
    end

    test "confirmed, a proposal with no version: who and when, without the version" do
      w = invoice_item(%{status: :shape, confirmed_by: @dana, confirmed_at: ago(30)})
      p = "#work-item-explore-proposal"

      assert text(tab(w, proposal: proposal_v(nil)), "#{p} .q-xp-cap") ==
               "You approved it just now."

      other = %{w | confirmed_by: @priya, confirmed_at: ago(3 * 3600)}

      assert text(tab(other, proposal: proposal_v(nil)), "#{p} .q-xp-cap") ==
               "Priya approved it 3 hours ago."

      refute tab(w, proposal: proposal_v(nil)) =~ "n/a"
    end

    test "closed at Confirm: the proposal, read" do
      w =
        invoice_item(%{status: :closed, stage: :confirm, ended_by: @priya, ended_at: ago(86_400)})

      html = tab(w, can_act: true, proposal: proposal_v(2))

      assert text(html, "#work-item-explore-proposal-h") == "Proposal"
      assert count(html, ".q-xp-frame-h .badge") == 0
      assert count(html, "form, button") == 0
    end
  end

  describe "explore_tab/1, the gate" do
    defp gate_tab(comments, extra \\ []) do
      tab(
        invoice_item(),
        Keyword.merge(
          [
            can_act: true,
            can_send: true,
            proposal: proposal_v(2),
            review_comments: comments
          ],
          extra
        )
      )
    end

    test "without open review comments: the comment, Run another round disabled, Confirm primary" do
      closed = comment("rc1", %{state: :closed, replies: [run_reply(:changed, 2)]})
      html = gate_tab([closed])
      g = "#work-item-explore-gate"

      assert attr(html, "#work-item-explore > *", "id") |> Enum.take(2) ==
               ["work-item-explore-proposal", "work-item-explore-gate"]

      assert text(html, "#{g} .q-xp-cap") ==
               "Run another round starts the next run. That run reads your comment and updates the proposal."

      assert text(html, "#{g} .q-xp-comment label") == "Comment on the whole proposal"
      assert attr(html, "#{g} .q-xp-comment label", "for") == ["work-item-explore-gate-comment"]
      assert attr(html, "#{g}-comment", "name") == ["comment"]

      assert attr(html, "#{g}-comment", "placeholder") == [
               "Add anything the questions do not cover."
             ]

      assert attr(html, g, "phx-submit") == ["answer"]
      assert attr(html, g, "phx-change") == ["answer_draft"]
      assert texts(html, "#{g} button") == ["Run another round", "Approve"]
      assert attr(html, "#{g}-send", "type") == ["submit"]
      assert attr(html, "#{g}-send", "disabled") == [""]
      refute attr(html, "#{g}-send", "class") |> hd() =~ "btn-primary"
      assert attr(html, "#{g}-go", "phx-click") == ["confirm"]
      assert attr(html, "#{g}-go", "phx-value-number") == ["41"]
      assert attr(html, "#{g}-go", "class") |> hd() =~ "btn-primary"
      assert count(html, "#{g}-unread") == 0

      # The field never words itself as a review comment.
      field = html |> query("#{g} .q-xp-comment") |> LazyHTML.to_html()
      refute field =~ ~r/review comment/i
    end

    test "Run another round is enabled by a comment, or by an open review comment" do
      g = "#work-item-explore-gate"
      written = gate_tab([], comment: "Also check the account page.")

      assert attr(written, "#{g}-send", "disabled") == []
      assert text(written, "#{g}-comment") == "Also check the account page."
      assert attr(gate_tab([], comment: " \n "), "#{g}-send", "disabled") == [""]
      assert attr(gate_tab([comment("rc1")]), "#{g}-send", "disabled") == []
    end

    test "with open review comments: Confirm and what it leaves unread" do
      for {open, words} <- [
            {1, "Approve leaves 1 comment unread."},
            {2, "Approve leaves 2 comments unread."}
          ] do
        comments = for i <- 1..open, do: comment("rc#{i}")
        html = gate_tab(comments)
        g = "#work-item-explore-gate"

        assert attr(html, "#{g} input[type=hidden]", "value") == ["41"]
        assert attr(html, "#{g}-send .hero-play-micro", "class") != []
        assert attr(html, "#{g}-go", "type") == ["button"]
        assert attr(html, "#{g}-go", "aria-describedby") == ["work-item-explore-gate-unread"]
        assert text(html, "#{g}-unread") == words
        assert texts(html, "#{g} button") == ["Run another round", "Approve"]
      end
    end

    test "a reader who may not write review comments: Confirm alone; one with neither right: none" do
      html = gate_tab([comment("rc1")], can_send: false)
      assert count(html, "#work-item-explore-gate-send, #work-item-explore-gate-comment") == 0
      assert text(html, "#work-item-explore-gate-go") == "Approve"

      none = gate_tab([comment("rc1")], can_act: false, can_send: false)
      assert count(none, "#work-item-explore-gate") == 0
    end

    test "each control by its right: the comment and Run another round, Confirm and its line" do
      g = "#work-item-explore-gate"

      # May send (`work_item.review_comment`), may not confirm (`work_item.confirm`).
      html = gate_tab([comment("rc1")], can_act: false)
      assert texts(html, "#{g} button") == ["Run another round"]
      assert attr(html, "#{g}-send", "class") |> hd() =~ "btn-primary"
      assert count(html, "#{g} .q-xp-cap, #{g}-comment") == 2
      assert count(html, "#{g}-go, #{g}-unread") == 0

      # May confirm, may not send: no line on the review comments, which the reader
      # may not send.
      html = gate_tab([comment("rc1")], can_send: false)
      assert texts(html, "#{g} button") == ["Approve"]
      assert attr(html, "#{g}-go", "class") |> hd() =~ "btn-primary"
      assert count(html, "#{g}-send, #{g}-unread, #{g} .q-xp-cap, #{g}-comment") == 0

      # May do both: Approve with the line on the open review comment.
      html = gate_tab([comment("rc1")], [])
      assert text(html, "#{g}-unread") == "Approve leaves 1 comment unread."
    end

    test "a reader with neither right: only the line of a send that was not made" do
      line = "Ask an approver of Explore to act on it."
      html = gate_tab([comment("rc1")], can_act: false, can_send: false, move_error: line)
      g = "#work-item-explore-gate"

      assert text(html, "#{g}-error") == line
      assert count(html, "#{g} button, #{g} .q-xp-cap, #{g}-unread, #{g}-comment") == 0
    end

    test "the old field and Send change are gone" do
      html = gate_tab([])
      refute html =~ "What should change?"
      refute html =~ "Send change"
      refute html =~ "change_draft"
    end
  end

  describe "explore_tab/1, the questions" do
    defp questions_tab(extra) do
      tab(
        invoice_item(%{status: :questions}),
        Keyword.merge(
          [can_act: true, questions: invoice_questions(), questions_version: 2],
          extra
        )
      )
    end

    test "the frame: the line, the closed questions folded, then the open ones in the form" do
      html = questions_tab([])
      q = "#work-item-explore-questions"

      assert text(html, "#{q}-h") == "Questions"
      assert attr(html, "#{q} .q-xp-frame-i", "class") |> hd() =~ "hero-question-mark-circle"

      assert text(html, "#{q}-cap") ==
               "Run another round starts the next run. That run reads your answers and updates the proposal."

      # Closed: answered and withdrawn, each folded to one line.
      assert attr(html, "#{q}-closed > details", "id") == [
               "work-item-explore-questions-question-1",
               "work-item-explore-questions-question-4"
             ]

      assert attr(html, "#{q}-closed > details", "open") == []

      assert texts(html, "#{q}-closed summary") == [
               "1. Which currency should the PDF show? The order's currency",
               "4. Is the old template still used? Withdrawn"
             ]

      assert text(html, "#{q}-question-1 .q-xp-inner strong") == "currency"
      assert text(html, "#{q}-question-1-answer") == "The order's currency"
      assert text(html, "#{q}-question-1-answer-who") == "You answered 1 hour ago"
      # The piece wraps inside itself in a column narrower than it.
      assert texts(html, "#{q}-question-1-answer-who > .q-xp-it.q-xp-by") ==
               ["You answered 1 hour ago"]

      # Open: in the form, one Run another round for all.
      assert texts(html, "#{q} .q-xp-sec > h3") == ["Open questions"]
      assert attr(html, "#{q}-form", "phx-change") == ["answer_draft"]
      assert attr(html, "#{q}-form", "phx-submit") == ["answer"]
      assert attr(html, "#{q}-form input[type=hidden]", "value") == ["41"]

      assert attr(html, "#{q}-form ol > li", "id") == [
               "#{String.trim_leading(q, "#")}-question-2",
               "#{String.trim_leading(q, "#")}-question-3"
             ]

      assert texts(html, "#{q}-form .q-xp-qt") == [
               "Should the credit note PDF change too?",
               "Should customers get corrected PDFs for invoices already sent?"
             ]

      assert count(html, "button") == 1
      assert text(html, "#{q}-go") == "Run another round"
      assert attr(html, "#{q}-go .hero-play-micro", "class") != []
      refute html =~ "Send answers"
      refute html =~ "Sending starts"
      refute html =~ "wrote this"
    end

    test "a closed question's summary: the chevron, then the question, which wraps beside it" do
      html = questions_tab([])
      closed = "#work-item-explore-questions-closed.q-xp-closed > details > summary"

      assert texts(html, "#{closed} > .q-xp-chev:first-child + .q-xp-it.q-xp-wrap") == [
               "1. Which currency should the PDF show?",
               "4. Is the old template still used?"
             ]

      assert texts(html, "#{closed} > .q-xp-it.q-xp-wrap.q-xp-said") == ["The order's currency"]

      assert attr(html, "#{closed} > .q-xp-chev", "class") ==
               List.duplicate("hero-chevron-right-micro q-xp-chev size-3.5", 2)

      # The question is at most the line less the chevron, 0.875rem (size-3.5) and its
      # 8px margin, so a long question wraps beside the chevron, not on the next line.
      # The chevron is centred on the question's first line.
      css = app_css()
      assert css =~ ~r/\n  \.q-xp-chev \{\s*margin-right: 8px;/

      assert css =~
               ~r/\n  \.q-xp-closed > details > summary > \.q-xp-chev \+ \.q-xp-wrap \{\s*max-width: calc\(100% - 0\.875rem - 8px\);\s*\}/

      assert css =~
               ~r/\n  \.q-xp-closed > details > summary > \.q-xp-chev \{\s*align-self: flex-start;\s*margin-top: calc\(\(1lh - 0\.875rem\) \/ 2\);\s*\}/

      assert css =~ ~r/\n  \.q-xp-closed > details > summary \{\s*align-content: center;\s*\}/

      # A word longer than the line breaks inside the frame, in the question and the answer.
      assert css =~
               ~r/\n  \.q-xp-wrap \{\s*white-space: normal;\s*overflow-wrap: anywhere;\s*\}/
    end

    test "each open question: its options, then Give your own option, then one field" do
      html = questions_tab([])
      a = "#work-item-explore-questions-answer-2"
      g = "#{a}-options"

      assert attr(html, g, "role") == ["radiogroup"]
      assert attr(html, g, "aria-labelledby") == ["work-item-explore-questions-q-2"]
      assert attr(html, "#{g} input", "name") == List.duplicate("answers[q2][option]", 3)
      assert attr(html, "#{g} input", "value") == ["1", "2", "own"]
      assert attr(html, "#{g} input", "checked") == []
      assert texts(html, "#{g} .q-xp-opt-t") == ["Yes", "No", "Give your own option"]

      assert attr(html, a, "name") == ["answers[q2][note]"]
      assert attr(html, a, "placeholder") == ["Add details (optional)"]
      assert attr(html, a, "aria-label") == ["Add details (optional)"]
      assert count(html, "label[for='work-item-explore-questions-answer-2']") == 0

      # A question without options has the field alone.
      assert count(html, "#work-item-explore-questions-answer-3-options") == 0
      assert count(html, "#work-item-explore-questions-answer-3-own") == 0

      assert attr(html, "#work-item-explore-questions-answer-3", "placeholder") ==
               ["Give your own option"]

      assert attr(html, "#work-item-explore-questions-answer-3", "name") ==
               ["answers[q3][note]"]
    end

    test "a reopened question shows its earlier answer; one that follows links it" do
      html = questions_tab([])
      q2 = "#work-item-explore-questions-question-2"

      assert texts(html, "#{q2}-earlier-who > span") ==
               ["Earlier answer", "Priya answered 2 hours ago"]

      # No white space of the template between the pieces, which would widen the gap left
      # of the "·" that opens the second piece; a <wbr> lets a narrow column break there.
      # The CSS rule for the "·" covers a piece right after the <wbr>.
      assert html =~ ~r{>Earlier answer</span><wbr></wbr><span class="q-xp-it q-xp-by">}

      assert texts(html, "#{q2}-earlier-who > .q-xp-it + wbr + .q-xp-it.q-xp-by") ==
               ["Priya answered 2 hours ago"]

      css =
        File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
        |> String.replace(~r{/\*.*?\*/}s, "")

      assert [_, selectors, separator] =
               Regex.run(
                 ~r/\n  ([^{}]*\.q-xp-it \+ wbr \+ \.q-xp-it::before[^{}]*)\{([^}]*)\}/,
                 css
               )

      assert ".q-xp-it + wbr + .q-xp-it::before" in Enum.map(
               String.split(selectors, ","),
               &String.trim/1
             )

      assert separator =~ ~s(\n    content: "·" / "";\n)
      assert separator =~ "\n    margin: 0 8px;\n"

      # The who and when is one box, so a narrow line breaks first before its "·"; text in
      # the box wraps in a column narrower than the box.
      assert css =~
               ~r/\n  \.q-xp-it\.q-xp-by \{\s*display: inline-block;\s*max-width: 100%;\s*white-space: normal;\s*overflow-wrap: anywhere;\s*\}/

      # No other rule in app.css matches the class, which would restyle both answer lines.
      assert length(Regex.scan(~r/\.q-xp-by(?![\w-])/, css)) == 1

      assert texts(html, "#{q2}-earlier > span") == ["No", "Only invoices."]
      # No white space of the template in the quote, whose white space is kept.
      assert html =~ ~r{<span class="block">No</span><span>Only invoices.</span></div>}
      assert attr(html, "#{q2}-earlier", "class") |> hd() =~ "q-xp-ans-old"
      assert text(html, "#{q2} .q-xp-cm-m a") == "Follows question 1"

      assert attr(html, "#{q2} .q-xp-cm-m a", "href") == [
               "#work-item-explore-questions-question-1"
             ]
    end

    test "the draft: a picked option is checked; Give your own option shows the Your option field" do
      html =
        questions_tab(
          questions: [
            q(2, %{options: [%{title: "Yes", explanation: nil}, %{title: "No", explanation: nil}]}),
            q(3, %{options: currency_options()})
          ],
          answers: %{
            "q2" => %{"option" => "2", "note" => "Only bank refunds."},
            "q3" => %{"option" => "own", "note" => ""}
          }
        )

      assert attr(html, "#work-item-explore-questions-answer-2-2", "checked") == [""]
      assert text(html, "#work-item-explore-questions-answer-2") == "Only bank refunds."
      assert attr(html, "#work-item-explore-questions-answer-3-own", "checked") == [""]
      assert attr(html, "#work-item-explore-questions-answer-3", "placeholder") == ["Your option"]
      assert attr(html, "#work-item-explore-questions-answer-3", "aria-label") == ["Your option"]
    end

    test "the recommended option: the mark in its card's label, a line of its own, on no other card" do
      options = [
        %{title: "Yes", explanation: "Change it.", recommended: true},
        %{title: "No", explanation: "Leave it."},
        %{title: "Later", explanation: "Change it next month."},
        %{title: "Ask finance", explanation: "Finance owns the template."}
      ]

      html =
        questions_tab(
          questions: [q(1, %{options: options}), q(2, %{options: currency_options()})]
        )

      a = "#work-item-explore-questions-answer-1"

      assert texts(html, "#{a}-options label[for$='-1'] .q-xp-opt-w > .badge") ==
               ["Recommended by the agent"]

      assert text(html, "#{a}-options label[for$='-1']") =~ "Recommended by the agent"
      assert count(html, "#{a}-options .badge") == 1
      assert attr(html, "#{a}-options input", "value") == ["1", "2", "3", "4", "own"]
      assert attr(html, "#{a}-options input", "checked") == []

      # A question stored before the mark looks as it did.
      assert count(html, "#work-item-explore-questions-answer-2-options .badge") == 0
    end

    test "the recommended option with the questions as text: the mark in its card" do
      options = [%{title: "Yes", explanation: "Change it.", recommended: true}]
      html = questions_tab(can_act: false, questions: [q(1, %{options: options})])

      assert texts(html, ".q-xp-opts .q-xp-opt .badge") == ["Recommended by the agent"]
    end

    test "a question with one option: its card, Give your own option, the field, nothing checked" do
      options = [%{title: "Yes", explanation: "Change it.", recommended: true}]
      html = questions_tab(questions: [q(1, %{options: options})])
      a = "#work-item-explore-questions-answer-1"

      assert attr(html, "#{a}-options input", "value") == ["1", "own"]
      assert attr(html, "#{a}-options input", "checked") == []
      assert texts(html, "#{a}-options .q-xp-opt-t") == ["Yes", "Give your own option"]
      assert attr(html, a, "name") == ["answers[q1][note]"]
      assert count(html, "#work-item-explore-questions-closed") == 0
    end

    test "a closed answer: the mark on the recommended option alone" do
      options = [
        %{title: "Yes", explanation: "Change it.", recommended: true},
        %{title: "No", explanation: "Leave it."}
      ]

      answer = fn option, note, recommended ->
        Map.put(given(@dana, option, note, 3600), :recommended, recommended)
      end

      html =
        questions_tab(
          questions: [
            q(1, %{options: options, state: :answered, answer: answer.("Yes", nil, true)}),
            q(2, %{options: options, state: :answered, answer: answer.("No", nil, false)}),
            q(3, %{options: options, state: :answered, answer: answer.(nil, "Neither.", false)}),
            q(4, %{
              options: currency_options(),
              state: :answered,
              answer: given(@dana, "The order's currency", nil, 3600)
            }),
            q(5, %{state: :withdrawn})
          ]
        )

      q = "#work-item-explore-questions-question"

      assert texts(html, "#{q}-1-answer .badge") == ["Recommended by the agent"]
      assert text(html, "#{q}-1-answer") =~ "Yes"

      for n <- [2, 3, 4], do: assert(count(html, "#{q}-#{n}-answer .badge") == 0)

      # A withdrawn question with no options draws.
      assert count(html, "#{q}-5") == 1
    end

    test "an earlier take in's answers: the mark where the answer is the recommended option" do
      marks = fn fields ->
        [question | _] = questions(@answers)

        take_in = %{
          take_in: 1,
          taken_in_by: @dana,
          taken_in_at: ~U[2026-10-16 15:20:00Z],
          ended: :closed,
          ended_by: @dana,
          ended_at: ago(4 * 60),
          runs: [%{run1_answered() | questions: [Map.merge(question, fields)]}]
        }

        tab(work_item(%{number: 94, status: :queued, run: %{attempt: 1, of: 3}}),
          earlier_take_ins: [take_in]
        )
        |> texts(".q-xp-ans .badge")
      end

      assert marks.(%{answer: "Yes", custom: false, recommended: true}) ==
               ["Recommended by the agent"]

      assert marks.(%{answer: "Neither", custom: true, recommended: false}) == []
      assert marks.(%{answer: "Older", custom: false}) == []
    end

    test "errors: under their question, describing it, and the focus on the first" do
      html =
        questions_tab(
          answers: %{"q3" => %{"option" => "own", "note" => ""}},
          errors: %{"q3" => :note_required, "q2" => {:too_long, 2000}},
          submits: 2
        )

      a3 = "#work-item-explore-questions-answer-3"
      assert attr(html, a3, "aria-invalid") == ["true"]
      assert text(html, "#{a3}-error") == "Write your option, or pick one above."

      assert text(html, "#work-item-explore-questions-answer-2-error") ==
               "Write at most 2,000 characters."

      assert attr(html, "#work-item-explore-questions-focus-2-2", "phx-mounted") |> hd() =~
               "#work-item-explore-questions-answer-2"
    end

    test "an empty send: the error over the button, in Explore's words" do
      html = questions_tab(form_error: :blank, submits: 1)

      assert text(html, "#work-item-explore-questions-error") ==
               "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."

      assert attr(html, "#work-item-explore-questions-error", "role") == ["alert"]
      assert count(html, "[aria-invalid]") == 0
    end

    test "a reader who may not act reads the questions and their options, with no input" do
      html = questions_tab(can_act: false)

      assert count(html, "form, input, textarea, button") == 0
      assert count(html, "#work-item-explore-questions-cap") == 0
      assert texts(html, "#work-item-explore-questions-question-2 .q-xp-opt-t") == ["Yes", "No"]
    end

    test "one question: Question" do
      html = questions_tab(questions: [q(1)])
      assert text(html, "#work-item-explore-questions-h") == "Question"
    end

    test "a hostile question: no script, no javascript: link, no image; mermaid is code text" do
      context = """
      Which <script>alert(1)</script> one?

      [click](javascript:alert(2))

      ![chart](https://img.example.com/chart.png)

      ```mermaid
      graph TD; A-->B
      ```
      """

      qs = [
        q(9, %{
          text: "<b>Which</b>?",
          context: context,
          options: [%{title: "<b>Bold</b>", explanation: "<script>x</script>"}]
        })
      ]

      for can_act <- [true, false] do
        html = questions_tab(questions: qs, can_act: can_act)

        refute html =~ "<script"

        assert text(html, "#work-item-explore-questions-question-9 .q-xp-md p") =~
                 "Which alert(1) one?"

        refute html =~ "javascript:"
        refute html =~ "<img"
        refute html =~ "phx-hook"
        assert text(html, "pre.q-mermaid-source code") == "graph TD; A-->B"
        assert html =~ "&lt;b&gt;Which&lt;/b&gt;?"
        assert html =~ "&lt;b&gt;Bold&lt;/b&gt;"
        assert text(html, ".q-xp-opt-e") == "<script>x</script>"
      end
    end
  end

  describe "explore_tab/1, review comments" do
    defp comments_tab(comments, extra \\ []) do
      tab(
        invoice_item(),
        Keyword.merge(
          [
            can_act: true,
            proposal: proposal_v(2),
            review_comments: comments,
            reply_path: &"/acme/main/work/41/explore?reply=#{&1}"
          ],
          extra
        )
      )
    end

    defp invoice_comments do
      [
        comment("rc1", %{
          state: :closed,
          replies: [run_reply(:changed, 2)]
        }),
        comment("rc2", %{
          text: "And the <b>credit notes</b>?",
          by: @priya,
          version: 2,
          reopened: true,
          replies: [
            run_reply(:asked, 2, %{question_number: 2, text: "Asked as a question."}),
            %{
              run: nil,
              by: @dana,
              text: "Only invoices.",
              outcome: nil,
              question_number: nil,
              version: nil
            }
          ]
        }),
        comment("rc3", %{text: "Keep the old template.", version: 2})
      ]
    end

    test "the cards: open ones first, then closed ones; the first of each opened, the rest folded" do
      html = comments_tab(invoice_comments())
      r = "#work-item-explore-proposal-review"

      assert text(html, "#{r}-h") == "Comments"
      assert count(html, "h3#{r}-h") == 1

      assert attr(html, "#{r} > .q-rc", "id") == [
               "#{String.trim_leading(r, "#")}-rc2",
               "#{String.trim_leading(r, "#")}-rc3",
               "#{String.trim_leading(r, "#")}-rc1"
             ]

      assert attr(html, "#{r} .q-rc-head", "aria-expanded") == ["true", "false", "true"]
      # The avatar in a header button is no tab stop; the button is one.
      assert count(html, "#{r} .q-rc-head abbr") == 2
      assert count(html, "#{r} .q-rc-head [tabindex]") == 0

      # No label in place of the content: a screen reader reads each card's writer and text.
      assert attr(html, "#{r} .q-rc-head", "aria-label") == []

      # A second closed card folds too.
      closed = comment("rc4", %{state: :closed, replies: [run_reply(:answered, 2)]})
      folded = comments_tab(invoice_comments() ++ [closed])

      assert attr(folded, "#{r} .q-rc-head", "aria-expanded") == [
               "true",
               "false",
               "true",
               "false"
             ]

      assert text(folded, "#{r}-rc4 .q-rc-out") == "Answered in version 2"

      assert count(html, "#{r}-rc1 .q-rc-tick") == 1
      assert count(html, "#{r}-rc1 .badge") == 0
      assert text(html, "#{r}-rc2 .badge") == "Reopened"
      assert text(html, "#{r}-rc3 .badge") == "Open"

      assert texts(html, "#{r} .q-rc-by") == [
               "Priya, on version 2",
               "You, on version 2",
               "You, on version 1"
             ]

      assert text(html, "#{r}-rc1 .q-rc-out") == "Changed in version 2"

      # Text, escaped, never markup.
      assert count(html, "#{r} b") == 0
      assert html =~ "And the &lt;b&gt;credit notes&lt;/b&gt;?"
    end

    test "replies: a run's outcome, Asked linked to its question; a member's reply by name" do
      html = comments_tab(invoice_comments())
      r = "#work-item-explore-proposal-review-rc2"

      assert text(html, "#{r}-reply-1 .q-rc-m") == "Asked as question 2"

      assert attr(html, "#{r}-reply-1 .q-rc-m a", "href") == [
               "#work-item-explore-questions-question-2"
             ]

      # In the right column of the Ticket and Thread tabs: the Explore tab's question.
      rail =
        render_component(&C.review_comments/1,
          id: "work-item-review",
          comments: invoice_comments(),
          explore_path: "/acme/main/work/41/explore",
          level: "h2",
          tip: "tooltip-right"
        )

      assert count(rail, "h2#work-item-review-h.q-rc-h") == 1
      # The avatars' tooltips open to the right, inside the right column.
      assert count(rail, "#work-item-review abbr.tooltip.tooltip-right") == 3
      assert count(html, "abbr.tooltip-right") == 0

      assert attr(rail, "#work-item-review-rc2-reply-1 .q-rc-m a", "href") == [
               "/acme/main/work/41/explore#work-item-explore-questions-question-2"
             ]

      assert attr(html, "#{r}-reply-1 .hero-play-circle", "class") != []
      assert text(html, "#{r}-reply-2 .q-rc-m > span") == "Dana"
      assert text(html, "#{r}-reply-2 .q-rc-text") == "Only invoices."
      refute html =~ "wrote this"

      for {outcome, words} <- [
            changed: "Changed in version 3",
            answered: "Answered in version 3",
            declined: "Declined in version 3"
          ] do
        c = comment("rc9", %{replies: [run_reply(outcome, 3)], reopened: true})

        assert text(comments_tab([c]), "#work-item-explore-proposal-review-rc9-reply-1 .q-rc-m") ==
                 words
      end
    end

    test "Reply on each card, by its id" do
      html = comments_tab(invoice_comments())

      assert attr(html, "[id$='-reply'][data-phx-link=patch]", "href") == [
               "/acme/main/work/41/explore?reply=rc2",
               "/acme/main/work/41/explore?reply=rc3",
               "/acme/main/work/41/explore?reply=rc1"
             ]

      assert count(comments_tab(invoice_comments(), reply_path: nil), "[id$='-reply']") == 0
    end

    test "the rail's list: review_comments/1 with its class" do
      html =
        render_component(&C.review_comments/1,
          id: "work-item-review",
          class: "q-rc-rail",
          comments: invoice_comments()
        )

      assert attr(html, "#work-item-review", "class") == ["q-rc-list q-rc-rail"]
      assert count(html, "#work-item-review > .q-rc") == 3
    end
  end

  describe "review_page/1" do
    test "Reply: the review comment opened above the field, its id in the form" do
      closed = comment("rc1", %{state: :closed, replies: [run_reply(:changed, 2)]})

      html =
        render_component(&C.review_page/1,
          number: 41,
          comment: closed,
          value: "Also the credit notes.",
          error: {:too_long, 2000},
          submits: 1,
          cancel: "/acme/main/work/41/explore"
        )

      f = "#work-item-review-page-form"
      assert text(html, "h1") == "Reply"
      assert attr(html, f, "phx-submit") == ["reply"]
      assert attr(html, "#{f} input[type=hidden]", "name") == ["number", "comment"]
      assert attr(html, "#{f} input[name=comment]", "value") == ["rc1"]
      assert attr(html, "#work-item-review-page-comment .q-rc-head", "aria-expanded") == ["true"]
      assert count(html, "#work-item-review-page-comment .badge") == 0
      assert text(html, "#{f} textarea") == "Also the credit notes."

      assert text(html, "#work-item-review-page-error") ==
               "Shorten the reply to 2,000 characters or fewer."

      assert attr(html, "#{f} textarea", "aria-invalid") == ["true"]
      assert text(html, "#{f} textarea[name=text]") == "Also the credit notes."
      assert text(html, "#{f} label") == "Reply"
      assert text(html, "#{f} button[type=submit]") == "Reply"
      assert attr(html, "#{f} a", "href") == ["/acme/main/work/41/explore"]
    end

    test "comment_error/2: the words of each error, for the comment and on Reply" do
      for kind <- [:comment, :reply] do
        assert C.comment_error(:reply_blank, kind) == "Write your reply."

        assert C.comment_error(:not_approver, kind) ==
                 "Ask one of this stage's approvers to write comments on the proposal. Only approvers of the stage can write them."

        assert C.comment_error(:other, kind) == nil
      end

      assert C.comment_error({:too_long, 2000}, :comment) ==
               "Shorten the comment to 2,000 characters or fewer."

      assert C.comment_error(:characters, :comment) ==
               "Remove the invisible or control characters from the comment."

      assert C.comment_error({:too_long, 2000}, :reply) ==
               "Shorten the reply to 2,000 characters or fewer."

      assert C.comment_error(:characters, :reply) ==
               "Remove the invisible or control characters from the reply."
    end

    test "send_error/1: the words of a send that wrote nothing, by why; comment_error/2 the same on its form" do
      changed =
        "Check the page, then send again. The work item changed after the page showed it, so nothing was sent."

      gone = "Reload the page. Your access or the work item changed, so nothing was sent."
      not_saved = "Send again. Qory Apiary could not save it."

      assert RichText.plain_text(C.send_error({:running, %{attempt: 3}})) ==
               "Send it again when attempt 3 ends. Attempt 3 started first, so nothing was sent."

      assert C.send_error(:store_unavailable) ==
               "Try again in a minute. The artifact store cannot be reached."

      assert C.send_error(:stale) == changed
      assert C.send_error(:not_waiting) == changed
      for reason <- [:forbidden, :not_found, :not_live], do: assert(C.send_error(reason) == gone)
      assert C.send_error(%Ecto.Changeset{}) == not_saved
      assert C.send_error(:other) == not_saved

      for kind <- [:comment, :reply] do
        assert C.comment_error(:stale, kind) == changed
        assert C.comment_error(:not_live, kind) == gone
        assert C.comment_error(:not_saved, kind) == not_saved
      end
    end
  end

  describe "explore_tab/1, the fold of the runs" do
    test "one fold: how many runs, the proposal's and the questions' versions; closed" do
      runs = [
        acme_run(%{
          id: "rn_0000000000000040",
          number: 40,
          path: "/acme/main/runs/40",
          attempt: 1,
          outcome: :questions,
          version: nil,
          wrote: nil,
          asked: 3,
          ended_at: ago(3 * 3600)
        }),
        acme_run(%{
          attempt: 2,
          version: 2,
          wrote: 2,
          asked: 1,
          wrote_proposal: %{message: @invoice},
          ended_at: ago(3600)
        })
      ]

      [first, last] = runs
      w = invoice_item(%{run: last})

      html =
        tab(w,
          earlier_runs: [first],
          proposal: proposal_v(2),
          questions_version: 2
        )

      r = "#work-item-record"
      assert attr(html, r, "aria-labelledby") == ["work-item-record-h"]
      assert text(html, "h2#work-item-record-h.sr-only") == "Runs and artifacts"
      assert attr(html, "#{r}-fold", "open") == []
      assert text(html, "#{r}-fold > summary") == "2 runs proposal v2 questions v2"
      refute html =~ "Earlier runs of this take in"

      assert texts(html, "#{r} .q-xp-runrow") == [
               "Attempt 1 (Run 40) Wrote 3 questions 3 hours ago",
               "Attempt 2 (Run 41) Wrote a proposal Wrote 1 question 1 hour ago"
             ]
    end

    test "a proposal with no version, as an older confirmed one: the fold's line has no proposal piece" do
      last = acme_run(%{attempt: 1, version: nil, wrote: nil, asked: 0, ended_at: ago(3600)})

      html =
        tab(invoice_item(%{run: last}),
          proposal: proposal_v(nil),
          questions_version: nil
        )

      assert texts(html, "#work-item-record-fold > summary .q-xp-it") == ["1 run"]
    end

    test "an earlier run that wrote a proposal is a fold with it; a lost one shows what happened" do
      wrote =
        acme_run(%{
          id: "rn_0000000000000040",
          number: 40,
          path: "/acme/main/runs/40",
          attempt: 1,
          wrote: 1,
          asked: 0,
          wrote_proposal: %{message: @invoice},
          ended_at: ago(3 * 3600)
        })

      lost =
        acme_run(%{
          id: "rn_0000000000000041",
          attempt: 2,
          state: :lost,
          outcome: nil,
          wrote: nil,
          asked: 0,
          ended_at: ago(3600)
        })

      last =
        acme_run(%{
          id: "rn_0000000000000042",
          number: 42,
          path: "/acme/main/runs/42",
          attempt: 3,
          wrote: 2,
          asked: 0,
          ended_at: ago(60)
        })

      html = tab(invoice_item(%{run: last}), earlier_runs: [wrote, lost], proposal: proposal_v(2))
      r = "#work-item-record"

      assert text(html, "#{r}-40 > summary") =~ "Attempt 1 (Run 40) Wrote a proposal 3 hours ago"
      assert text(html, "#{r}-40-proposal-h") == "Proposal"
      # One level below the tab's frames inside the fold, at the same size, under the
      # fold's hidden h2.
      assert count(html, "h2#work-item-explore-proposal-h.q-xp-frame-t") == 1
      assert count(html, "#{r} > h2#work-item-record-h.sr-only") == 1
      assert count(html, "h3#work-item-record-40-proposal-h.q-xp-frame-t") == 1
      assert text(html, "#{r}-40-proposal .q-xp-cap") == "Version 1"
      assert text(html, "#{r}-41-none-h") == "The run was lost (Run 41)."
      assert count(html, "#{r}-42[class=q-xp-runrow]") == 1
    end

    test "the artifacts slot is at the foot of the fold" do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <C.explore_tab work_item={@w} now={@now} proposal={@p}>
              <:artifacts>
                <p id="arts">Artifacts</p>
              </:artifacts>
            </C.explore_tab>
            """
          end,
          w: invoice_item(),
          now: @now,
          p: proposal_v(2)
        )

      assert count(html, "#work-item-record .q-xp-arts #arts") == 1
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

      assert text(html, "#work-item-explore-none-h") == "The run ended without a result (Run 12)."
      Enum.at(texts(html, "#work-item-explore-none p"), 1)
    end

    test "a read-only run qory closed: the fix, then the cause" do
      wall = "A read-only run needs a wall, and this machine has none."
      inside = "A read-only run cannot run its setup inside the agent's container."

      docker =
        "Choose an image without nested Docker in the repository's environment, then start the run again. A read-only run cannot use an image with nested Docker."

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
                 "Choose an image without nested Docker in the target's environment, then start the run again. A read-only run cannot use an image with nested Docker."
      end)
    end

    test "what happened, and the run's page" do
      for {status, overrides, _run_state, heading, body} <- [
            {:no_result, %{state: :failed, outcome: :error, end_cause: :run_ended}, "Failed",
             "The run ended with an error (Run 12).",
             "The run's last result was an error. There is nothing to show or approve."},
            {:no_result, %{outcome: :none}, "Completed",
             "The run ended without a result (Run 12).", "There is nothing to show or approve."},
            {:no_result, %{outcome: :refused}, "Completed",
             "The run's result did not pass Qory Apiary's check (Run 12).",
             "Qory Apiary accepts a result only in Explore's format and up to 128 KiB. This result is outside those limits, so it is not shown."},
            {:lost, %{state: :lost, outcome: nil}, "Lost", "The run was lost (Run 12).",
             "Qory Apiary has no result from the run. There is nothing to show or approve."},
            {:cancelled, %{state: :cancelled, outcome: nil}, "Cancelled",
             "The run was cancelled (Run 12).", "There is nothing to show or approve."}
          ] do
        r =
          run(Map.merge(%{proposal: nil, ended_at: ago(3600), duration: "4 minutes"}, overrides))

        html = tab(work_item(%{number: 97, status: status, run: r}))

        assert count(html, "#work-item-explore-run") == 0
        assert text(html, "#work-item-explore-none-h") == heading

        assert texts(html, "#work-item-explore-none p") == [
                 heading,
                 body,
                 "The page of attempt 1 (Run 12) shows what it did."
               ]

        # Its heading and the words "attempt 1" link the same run's page.
        assert attr(html, "#work-item-explore-none a", "href") == [
                 "/8wonders/main/runs/12",
                 "/8wonders/main/runs/12"
               ]
      end
    end

    test "above a proposal of an earlier round: the banner says so, and so does the proposal" do
      earlier = "The proposal below is from an earlier round."

      for {status, overrides, body} <- [
            {:no_result, %{state: :failed, outcome: :error, end_cause: :run_ended},
             "The run's last result was an error. " <> earlier},
            {:no_result, %{outcome: :none}, earlier},
            {:lost, %{state: :lost, outcome: nil},
             "Qory Apiary has no result from the run. " <> earlier},
            {:cancelled, %{state: :cancelled, outcome: nil}, earlier}
          ] do
        r = run(Map.merge(%{attempt: 2, proposal: nil, version: nil}, overrides))
        html = tab(work_item(%{number: 97, status: status, run: r}), proposal: proposal_v(1))

        assert Enum.at(texts(html, "#work-item-explore-none p"), 1) == body
        refute html =~ "There is nothing to show or approve."

        assert text(html, "#work-item-explore-proposal .q-xp-cap") ==
                 "Version 1 · from an earlier round"
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

        assert texts(earlier, "#work-item-record-run-1-none p") == words

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
            {%{
               code: "ref_missing",
               rule: %{
                 "rule" => "claim",
                 "values" => %{
                   "url" => "https://github.com/qoryai/qory",
                   "ref" => "gone",
                   "builtin" => true
                 }
               }
             },
             "Contact support. Reading the harness from https://github.com/qoryai/qory failed: the repository has no branch gone."},
            {%{
               code: "harness_unreadable",
               rule: %{
                 "rule" => "claim",
                 "values" => %{
                   "url" => harness,
                   "ref" => "main",
                   "cause" => %{"cause" => "failed"}
                 }
               }
             },
             "Start the run again later. Reading the harness from #{harness} failed: the host returned something other than a git repository over HTTPS. If it fails again, contact support."},
            {%{
               code: "harness_unreadable",
               rule: %{
                 "rule" => "claim",
                 "values" => %{
                   "url" => harness,
                   "ref" => "main",
                   "cause" => %{"cause" => "too_large"}
                 }
               }
             },
             "Start the run again later. Reading the harness from #{harness} failed: the repository is larger than 16 MiB, or a harness file is larger than 0.25 MiB. If it fails again, contact support."},
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
             "The run's harness has no skill for the workflow explore-a-ticket. The harness comes from the harness file at the root of repository acme/web-shop."},
            {:qory,
             "The run's harness has no skill for the workflow explore-a-ticket. The harness is the Qory harness."},
            {nil, "The run's harness has no skill for the workflow explore-a-ticket."}
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
        assert text(html, "#work-item-explore-none-h") == "The run did not start (Run 12)."

        assert Enum.take(texts(html, "#work-item-explore-none p"), 2) ==
                 ["The run did not start (Run 12).", line]
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
        "The run ended with an error (Run 12).",
        "The run's last result was an error. There is nothing to show or approve."
      ]

      html = tab(work_item(%{number: 97, status: :no_result, run: r}))
      assert texts(html, "#work-item-explore-none p") |> Enum.take(2) == words

      earlier =
        tab(work_item(%{number: 97, status: :queued, run: %{attempt: 2, of: 3}}),
          earlier_runs: [r]
        )

      assert texts(earlier, "#work-item-record-12-none p")
             |> Enum.take(2) == words

      for html <- [html, earlier] do
        refute html =~ "The run did not start."
      end
    end

    test "no run line once the run ended; the fold's row has its state and time" do
      lost = acme_run(%{state: :lost, outcome: nil, wrote: nil, asked: 0, ended_at: ago(21 * 60)})
      html = tab(work_item(%{status: :lost, run: lost}))
      assert count(html, "#work-item-explore-run") == 0
      assert text(html, "#work-item-record-41") == "Attempt 1 (Run 41) Lost 21 minutes ago"

      cancelled =
        acme_run(%{state: :cancelled, outcome: nil, wrote: nil, asked: 0, ended_at: ago(30 * 60)})

      html = tab(work_item(%{status: :cancelled, run: cancelled}))
      assert text(html, "#work-item-record-41") == "Attempt 1 (Run 41) Cancelled 30 minutes ago"
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
      assert count(html, "h2#work-item-explore-take-ins-h.q-xp-earlier-t") == 1

      assert texts(html, "#work-item-explore-take-ins-1 summary .q-xp-it") ==
               ["Taken in 16 Oct by you", "Closed by you 4 minutes ago", "3 runs"]

      # The pieces are in one strip (`.q-xp-parts`), so no wrapped line starts with "·".
      assert count(html, "#work-item-explore-take-ins-1 > summary > .q-xp-parts > .q-xp-it") ==
               3

      assert text(html, "#work-item-explore-take-ins-1 .q-xp-inner > p:first-child") ==
               "These runs do not count toward the run limit of this take in."

      assert texts(html, "#work-item-explore-take-ins-1 .q-xp-run > span:first-child") ==
               ["Attempt 1 (Run 13)", "Attempt 2 (Run 14)", "Attempt 3 (Run 15)"]

      # The frames of its runs are h3, under the h2 of Earlier take ins.
      assert count(html, "#work-item-explore-take-ins h3.q-xp-frame-t") == 3
      assert count(html, "#work-item-explore-take-ins :is(h2.q-xp-frame-t, h4.q-xp-frame-t)") == 0
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

    test "a run's questions: the title and the line by the count, and by whether the answers show" do
      unanswered = run1_answered() |> Map.merge(%{answered_by: nil, answered_at: nil})
      one = Map.put(unanswered, :questions, [hd(questions())])

      for {r, title, line} <- [
            {one, "Question", "Attempt 1 (Run 13) wrote this question."},
            {unanswered, "Questions", "Attempt 1 (Run 13) wrote these questions."},
            {Map.put(run1_answered(), :questions, [hd(questions(@answers))]),
             "Question and answer", "Attempt 1 (Run 13) wrote this question."},
            {run1_answered(), "Questions and answers",
             "Attempt 1 (Run 13) wrote these questions."}
          ] do
        take_in = %{
          taken_in_by: @dana,
          taken_in_at: ~U[2026-10-16 15:20:00Z],
          ended: :closed,
          ended_by: @dana,
          ended_at: ago(4 * 60),
          runs: [r]
        }

        html =
          tab(work_item(%{status: :queued, run: %{attempt: 1, of: 3}}),
            earlier_take_ins: [take_in]
          )

        body = "#work-item-explore-take-ins-1-13-body"
        assert text(html, "#{body}-h") == title
        assert text(html, "#{body} .q-xp-cap") == line
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
    test "a run starts: first, with the review comments, with the answers, again; its place beside it; the run's icon" do
      r = run(%{attempt: 2})

      for {start, words} <- [
            {nil, "Explore started in attempt 2"},
            {:review_comments, "Explore started again, with the comments, in attempt 2"},
            {:answers, "Explore started again, with the answers, in attempt 2"},
            {:again, "Explore started again in attempt 2"}
          ] do
        html = event(kind: :started, run: r, start: start)
        assert line(html) == words <> " Attempt 2 14 Oct, 11:25"
        assert text(html, ".q-wi-tag") == "Attempt 2"
        assert attr(html, "p a", "href") == ["/8wonders/main/runs/12"]
        assert count(html, ".q-wi-ev-ic .q-wi-play.hero-play-circle") == 1
      end
    end

    test "Qory asked: how many and after how long, the questions quoted under it" do
      html = event(kind: :asked, questions: questions(), duration: "9 minutes")
      assert line(html) == "Explore wrote 3 questions, after 9 minutes 14 Oct, 11:25"
      assert count(html, ".q-wi-ev-ic .q-wi-play.hero-play-circle") == 1
      assert texts(html, "#ev-1-questions li") == Enum.map(questions(), & &1.text)

      one = event(kind: :asked, questions: [hd(questions())], duration: "8 minutes")
      assert line(one) == "Explore wrote 1 question, after 8 minutes 14 Oct, 11:25"
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

    test "a review comment on the proposal: who, and the comment quoted as plain text" do
      comment = "Also check the basket.\n<b>not bold</b>"

      html = event(kind: :answered, actor: @dana, questions: [], comment: comment)
      assert line(html) == "You wrote a comment on the proposal 14 Oct, 11:25"
      [quoted] = html |> query("#ev-1-answers .q-wi-qa-a") |> Enum.to_list()
      assert LazyHTML.text(quoted) == comment
      assert count(html, "#ev-1-answers b") == 0
      assert count(html, "#ev-1-answers .q-wi-qa-q") == 0

      other = event(kind: :answered, actor: @priya, questions: [], comment: "Ship it.")
      assert line(other) == "Priya wrote a comment on the proposal 14 Oct, 11:25"
      assert text(other, "#ev-1-answers b") == ""
      assert text(other, "li > div > p:first-child b") == "Priya"
    end

    test "Run another round with answers and a comment: one line for both, then each quoted" do
      qs = questions(@answers)
      comment = "Also check the basket."

      html = event(kind: :answered, actor: @dana, questions: [hd(qs)], comment: comment)
      assert line(html) == "You answered 1 question and wrote a comment 14 Oct, 11:25"
      assert texts(html, "#ev-1-answers .q-wi-qa-q") == [hd(qs).text]
      assert hd(@answers) in texts(html, "#ev-1-answers .q-wi-qa-a")

      mine3 = event(kind: :answered, actor: @dana, questions: qs, comment: comment)
      assert line(mine3) == "You answered 3 questions and wrote a comment 14 Oct, 11:25"

      other = event(kind: :answered, actor: @priya, questions: [hd(qs)], comment: comment)
      assert line(other) == "Priya answered 1 question and wrote a comment 14 Oct, 11:25"
      assert text(other, "li > div > p:first-child b") == "Priya"

      other3 = event(kind: :answered, actor: @priya, questions: qs, comment: comment)
      assert line(other3) == "Priya answered 3 questions and wrote a comment 14 Oct, 11:25"
    end

    test "a reply to a review comment: who, and the reply quoted" do
      html =
        event(kind: :answered, actor: @dana, questions: [], comment: "Ship it.", reply: true)

      assert line(html) == "You replied to a comment 14 Oct, 11:25"
      assert text(html, "#ev-1-answers .q-wi-qa-a") == "Ship it."

      other =
        event(kind: :answered, actor: @priya, questions: [], comment: "Ship it.", reply: true)

      assert line(other) == "Priya replied to a comment 14 Oct, 11:25"
      assert text(other, "li > div > p:first-child b") == "Priya"
    end

    test "answered: who, each question and its answer quoted" do
      qs = questions(@answers)

      html = event(kind: :answered, actor: @priya, questions: qs)
      assert line(html) == "Priya answered 3 questions 14 Oct, 11:25"
      assert texts(html, "#ev-1-answers .q-wi-qa-a") == @answers
      assert texts(html, "#ev-1-answers .q-wi-qa-q") == Enum.map(qs, & &1.text)

      mine = event(kind: :answered, actor: @dana, questions: [hd(qs)])
      assert line(mine) == "You answered 1 question 14 Oct, 11:25"

      mine3 = event(kind: :answered, actor: @dana, questions: qs)
      assert line(mine3) == "You answered 3 questions 14 Oct, 11:25"

      one = event(kind: :answered, actor: @priya, questions: [hd(qs)])
      assert line(one) == "Priya answered 1 question 14 Oct, 11:25"
    end

    test "answered: each question is a block, with no white space drawn around it" do
      html = event(kind: :answered, actor: @priya, questions: questions(@answers))

      # The question is its Markdown block, with the template's line breaks around it;
      # the answer is plain text.
      assert count(html, "#ev-1-answers .q-wi-qa-q > .q-xp-md") == 3
      assert count(html, "#ev-1-answers .q-wi-qa-a > *") == 0

      # Under `pre-wrap` those line breaks drew empty lines above and below the question.
      # Every rule for the question that sets its white space sets `normal`; the answer
      # is drawn with the line breaks of its text.
      rules = Regex.scan(~r/([^{}]*)\{([^{}]*)\}/, app_css(), capture: :all_but_first)

      spacing = fn class ->
        for [selectors, body] <- rules,
            selectors =~ ~r/\.#{class}(?![\w-])/,
            [_, value] <- Regex.scan(~r/white-space:\s*([^;]+);/, body),
            do: value
      end

      assert spacing.("q-wi-qa-q") == ["normal"]
      assert spacing.("q-wi-qa-a") == ["pre-wrap"]
    end

    test "replied: how many review comments and after how long, with the run's icon" do
      one = event(kind: :replied, run: run(%{}), replies: 1, duration: "30 seconds")

      assert line(one) ==
               "Explore wrote a reply to 1 comment, after 30 seconds 14 Oct, 11:25"

      assert count(one, ".q-wi-ev-ic .q-wi-play.hero-play-circle") == 1
      assert count(one, ".q-wi-ev-bad") == 0

      two = event(kind: :replied, run: run(%{}), replies: 2, duration: "4 minutes")

      assert line(two) ==
               "Explore wrote replies to 2 comments, after 4 minutes 14 Oct, 11:25"
    end

    test "proposed: after how long, and whose turn; only how long without an owner" do
      assert line(event(kind: :proposed, owner: @dana, duration: "11 minutes")) ==
               "Explore wrote a proposal, after 11 minutes. You approve next 14 Oct, 11:25"

      assert line(event(kind: :proposed, owner: @lea, duration: "7 minutes")) ==
               "Explore wrote a proposal, after 7 minutes. Lea approves next 14 Oct, 11:25"

      assert line(event(kind: :proposed, owner: nil, duration: "7 minutes")) ==
               "Explore wrote a proposal, after 7 minutes 14 Oct, 11:25"

      assert count(
               event(kind: :proposed, owner: nil, duration: "7 minutes"),
               ".q-wi-ev-ic .q-wi-play.hero-play-circle"
             ) == 1
    end

    test "a run without a result, lost or cancelled, with its mark" do
      r = run(%{})

      for {kind, outcome, words} <- [
            {:no_result, :error, "Attempt 1 ended with an error, so Explore has no result"},
            {:no_result, :none, "Attempt 1 ended without a result"},
            {:no_result, :refused,
             "Attempt 1 returned a result that did not pass Qory Apiary's check"},
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
            {[kind: :confirmed, actor: @dana], "You approved the proposal. Ready for Shape"},
            {[kind: :confirmed, actor: @priya], "Priya approved the proposal. Ready for Shape"},
            {[kind: :confirmed, actor: @dana, changed: true],
             "You changed the proposal and approved it. Ready for Shape"},
            {[kind: :confirmed, actor: @priya, changed: true],
             "Priya changed the proposal and approved it. Ready for Shape"}
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
          questions: [q(1, %{id: "qq_01", options: currency_options()})],
          errors: %{"qq_01" => :note_required}
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
        tab(work_item(%{}),
          can_act: true,
          proposal: proposal_v(1),
          review_comments: [comment("rc_1")],
          reply_path: &"/acme/main/work/88/explore?reply=#{&1}"
        ),
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
    assert Enum.any?(values, &match?({"name", "answers[qq_01][note]"}, &1))
    assert Enum.any?(values, &match?({"id", "work-item-record-13"}, &1))

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
                 "Attempt 3 (Run 15) ended without a result. That was attempt 3 of 3, the last attempt of this take in."

        assert count(html, "#work-item-step-again") == 0
        assert count(html, "#work-item-step-next") == 0
        refute html =~ "attempt 4 of 3"
        assert text(html, "#work-item-step-close") == "Close work item…"

        tab = tab(last(status, overrides), can_act: true)
        assert count(tab, "#work-item-explore-limit") == 0
        assert count(tab, "#work-item-explore-none") == 1
      end
    end

    test "questions at attempt 3 of 3 keep the form: answers queue the next run" do
      w = last(:questions, %{outcome: :questions, questions: [hd(questions())]})

      html = tab(w, can_act: true, questions: [q(1)])
      assert count(html, "#work-item-explore-limit") == 0
      assert count(html, "#work-item-explore-questions-form") == 1
      assert text(html, "#work-item-explore-questions-go") == "Run another round"
      refute html =~ "attempt 4 of 3"

      assert text(card(w), ".q-wi-badge") == "Needs answers"
      refute C.status_words(w) == "Explore used its 3 runs"
    end

    test "at attempt 3 of 3 the header, the row, the stages and the card read the run limit alike" do
      for {status, overrides} <- [
            {:lost, %{state: :lost, outcome: nil}},
            {:no_result, %{state: :failed, outcome: :error}}
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
      assert text(html, "#work-item-step-next") == "Run Explore again starts attempt 3."
      assert text(html, "#work-item-step-again") == "Run Explore again"
    end
  end

  ## A field's first line, missing keys, the focus

  describe "the fields and the run's words, robustly" do
    defp form_tab(extra),
      do:
        tab(
          invoice_item(%{status: :questions}),
          Keyword.merge(
            [can_act: true, questions: [q(1, %{options: currency_options()}), q(2)]],
            extra
          )
        )

    test "a value that starts with a line break keeps it in its field" do
      [answer] =
        form_tab(answers: %{"q2" => %{"note" => "\nWeb only."}})
        |> query("#work-item-explore-questions-answer-2")
        |> Enum.to_list()

      assert LazyHTML.text(answer) == "\nWeb only."

      [text] =
        render_component(&C.review_page/1,
          number: 41,
          comment: comment("rc1"),
          value: "\nStarts after a line.",
          cancel: "/acme/main/work/41/explore"
        )
        |> query("#work-item-review-page-text")
        |> Enum.to_list()

      assert LazyHTML.text(text) == "\nStarts after a line."
    end

    test "a draft that is no map, or an option out of range, picks nothing" do
      html = form_tab(answers: %{"q1" => "old", "q2" => %{"option" => "9"}})

      assert attr(html, "input[type=radio]", "checked") == []
      assert text(html, "#work-item-explore-questions-answer-1") == ""
    end

    test "an answer error without words marks nothing" do
      html = form_tab(errors: %{"q1" => :unknown, "q2" => {:odd}})

      assert count(html, ".q-xp-err") == 0
      assert count(html, "[aria-invalid]") == 0
      assert count(html, "[phx-mounted]:not(details)") == 0
    end

    test "the focus span is new after each send, so the focus moves again" do
      for submits <- [1, 2] do
        html = form_tab(errors: %{"q2" => :note_required}, submits: submits)
        assert count(html, "#work-item-explore-questions-focus-#{submits}-2") == 1

        page =
          render_component(&C.review_page/1,
            number: 41,
            comment: comment("rc1"),
            error: :reply_blank,
            submits: submits,
            cancel: "/acme/main/work/41/explore"
          )

        assert count(page, "#work-item-review-page-focus-#{submits}") == 1
      end
    end
  end

  describe "a source's words for its items" do
    @bug %{one: "bug", other: "bugs"}

    test "Explore reads the item by its source's word, or the ticket where it names none" do
      queued = work_item(%{number: 341, status: :queued, run: %{attempt: 1, of: 3}})

      assert text(tab(queued, item_noun: @bug), "#work-item-explore-wait p:last-child") ==
               "Attempt 1 starts when the workspace's pool takes it. It reads the bug, then writes a proposal and questions."

      running = run(%{state: :running, outcome: nil, ended_at: nil, answers_by: []})

      assert text(
               card(work_item(%{status: :running, run: running}), item_noun: @bug),
               "#work-item-step-line"
             ) ==
               "Explore reads the bug and writes a proposal."

      again = run(%{attempt: 2, state: :running, outcome: nil, ended_at: nil})

      assert text(
               tab(work_item(%{status: :running, run: again}),
                 item_noun: @bug,
                 earlier_runs: [run1_answered()]
               ),
               "#work-item-explore-wait p:last-child"
             ) ==
               "Attempt 2 reads the bug, the newest proposal and the questions with your answers, then writes the next proposal and questions."
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

      assert count(html, "#work-item-record-run-1") == 1
      assert count(html, "#work-item-record-run-1 summary .q-mono") == 0
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
      html = form_tab([])
      assert attr(html, "textarea", "maxlength") == ["4000", "4000"]

      html =
        render_component(&C.review_page/1,
          number: 41,
          comment: comment("rc1"),
          cancel: "/acme/main/work/41/explore"
        )

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
               @key_fix <> " The gateway had no model key for attempt 1 (Run 16)."

      assert attr(html, "#work-item-step-line a", "href") == [
               "/8wonders/main/runs/16"
             ]

      refute html =~ "ended with an error"
    end

    test "Explore's tab says the run ended before it started, then the fix and why" do
      html = tab(work_item(%{number: 97, status: :no_result, run: refused("model_key_missing")}))

      assert text(html, "#work-item-explore-none-h") == "The run did not start (Run 16)."

      assert texts(html, "#work-item-explore-none p") == [
               "The run did not start (Run 16).",
               @key_fix <> " The gateway had no model key for the run.",
               "The page of attempt 1 (Run 16) shows what it did."
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
                 "Attempt 1 (Run 16) ended with an error, so Explore has no result."

        assert text(tab(item), "#work-item-explore-none-h") ==
                 "The run ended with an error (Run 16)."

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
                 " The gateway had no model key for attempt 3 (Run 16). That was attempt 3 of 3, the last attempt of this take in."

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
               "The run did not start (Run 16).",
               @key_fix <> " The gateway had no model key for the run.",
               "The page of attempt 3 (Run 16) shows what it did."
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
               "Attempt 3 (Run 16) ended without a result. That was attempt 3 of 3, the last attempt of this take in."

      refute html =~ "model key"
    end
  end

  describe "the comment on the whole proposal, under the questions" do
    defp commenting_tab(extra) do
      tab(
        invoice_item(%{status: :questions}),
        Keyword.merge(
          [
            can_act: true,
            can_send: true,
            proposal: proposal_v(2),
            questions: invoice_questions(),
            questions_version: 2
          ],
          extra
        )
      )
    end

    test "one field below the last question and above the button; no button of its own" do
      html = commenting_tab([])
      q = "#work-item-explore-questions"

      assert attr(html, "#{q}-form > *", "class") |> Enum.reject(&is_nil/1) ==
               ["q-xp-sec", "q-xp-comment", "q-xp-form-foot"]

      assert attr(html, "#{q}-form > .q-xp-sec > *", "class") |> Enum.reject(&is_nil/1) ==
               ["q-xp-qs"]

      assert text(html, "#{q}-form .q-xp-comment label") == "Comment on the whole proposal"
      assert attr(html, "#{q}-comment", "name") == ["comment"]

      assert attr(html, "#{q}-comment", "placeholder") == [
               "Add anything the questions do not cover."
             ]

      assert texts(html, "#{q}-form button") == ["Run another round"]
      assert count(html, "#work-item-explore-gate") == 0

      # The field never words itself as a review comment.
      field = html |> query("#{q}-form .q-xp-comment") |> LazyHTML.to_html()
      refute field =~ ~r/review comment/i
    end

    test "only for a reader who may write review comments, where a proposal exists" do
      q = "#work-item-explore-questions"
      assert count(commenting_tab(can_send: false), "#{q}-comment") == 0
      assert count(commenting_tab(proposal: nil), "#{q}-comment") == 0
      assert count(commenting_tab(can_send: false), "#{q}-go") == 1
    end

    test "the line above the questions names the comment only where the field shows" do
      q = "#work-item-explore-questions"

      assert text(commenting_tab([]), "#{q}-cap") ==
               "Run another round starts the next run. That run reads your answers and your comment, and updates the proposal."

      for no_field <- [commenting_tab(can_send: false), commenting_tab(proposal: nil)] do
        assert text(no_field, "#{q}-cap") ==
                 "Run another round starts the next run. That run reads your answers and updates the proposal."
      end
    end

    test "Run another round: disabled with nothing to send; an answer, a comment or an open review comment enables it" do
      go = "#work-item-explore-questions-go"
      assert attr(commenting_tab([]), go, "disabled") == [""]

      for answers <- [
            %{"q2" => %{"option" => "1"}},
            %{"q3" => %{"note" => "Only new ones."}},
            %{"q2" => %{"option" => "own"}}
          ] do
        assert attr(commenting_tab(answers: answers), go, "disabled") == []
      end

      assert attr(commenting_tab(answers: %{"q3" => %{"note" => "  "}}), go, "disabled") == [""]
      assert attr(commenting_tab(comment: "Also check the totals."), go, "disabled") == []
      assert attr(commenting_tab(comment: " \n "), go, "disabled") == [""]
      assert attr(commenting_tab(review_comments: [comment("rc1")]), go, "disabled") == []

      closed = comment("rc1", %{state: :closed, replies: [run_reply(:changed, 2)]})
      assert attr(commenting_tab(review_comments: [closed]), go, "disabled") == [""]

      # For a reader who may not send review comments, the open ones do not count.
      blocked = commenting_tab(can_send: false, review_comments: [comment("rc1")])
      assert attr(blocked, go, "disabled") == [""]
    end
  end

  describe "a diagram's frame" do
    test "the image scales to the frame's width, and only the frame scrolls" do
      css = app_css()

      assert css =~ ~r/\.q-mermaid-frame \{\s*overflow-x: auto;/
      assert css =~ ~r/\.q-mermaid-frame \{[^}]*contain: inline-size;/
      assert css =~ ~r/\.q-mermaid-frame \{[^}]*scrollbar-color: auto;/
      assert css =~ ~r/\.q-mermaid-frame::-webkit-scrollbar \{\s*height: 8px;/
      assert css =~ ~r/\.q-mermaid-diagram \{\s*display: block;\s*max-width: 100%;/
      refute css =~ "40rem);\n    height: auto"
    end
  end

  describe "the right column's breakpoint" do
    test "from 1007 px, a window of 1024 px less a 17 px scrollbar, the rail is a sticky column with Details and the review comments; below it, the review comments are in the proposal" do
      css = app_css()

      assert css =~
               ~r/@media \(min-width: 1007px\) \{\s*\.q-wi \{\s*grid-template-columns: minmax\(0, 1fr\) 320px;/

      # The sticky rule is inside the 1007 px query: no other query starts between them.
      assert css =~ ~r/@media \(min-width: 1007px\) \{[^@]*?\.q-wi-r \{\s*position: sticky;/
      assert css =~ ~r/@media \(min-width: 1007px\) \{\s*\.q-wi-dtoggle \{\s*display: none;/
      assert css =~ ~r/@media \(min-width: 1007px\) \{\s*\.q-xp-rc-inline \{\s*display: none;/
      assert css =~ ~r/@media \(max-width: 1006\.98px\) \{\s*\.q-rc-rail \{\s*display: none;/

      assert css =~
               ~r/@media \(min-width: 1007px\) \{\s*\.q-art-cols \{\s*grid-template-columns: minmax\(0, 1fr\) 18rem;/

      refute css =~ ~r/@media \(min-width: 1440px\) \{\s*\.q-(wi|xp-rc|rc)[\s{-]/
      refute css =~ "1439.98px"
    end
  end

  describe "explore_tab/1, the run's decisions" do
    defp decided(number, overrides \\ %{}) do
      q(
        number,
        Map.merge(
          %{
            text: "Where can a customer change the date after paying?",
            options: [
              %{title: "In the account page", explanation: "The order gets a date field."},
              %{title: "In the order email", explanation: "A link opens the date step again."}
            ],
            state: :decided,
            decision: %{
              option: "In the account page",
              reason: "The account page already lists each open order.",
              run: 41,
              at: ago(720)
            }
          },
          overrides
        )
      )
    end

    defp changed(number, by, option, note) do
      decided(number, %{state: :answered, answer: given(by, option, note, 2400)})
    end

    defp decisions_tab(status, questions, extra \\ []) do
      tab(
        invoice_item(%{status: status}),
        Keyword.merge(
          [
            can_act: true,
            can_send: true,
            can_change: true,
            proposal: proposal_v(2),
            questions: questions,
            questions_version: 3
          ],
          extra
        )
      )
    end

    @ask "Run another round starts the next run. That run reads your answers, your changed decisions and your comment, and updates the proposal."
    @changed_cap "Run another round starts the next run. That run reads your changed decisions and your comment, and updates the proposal."
    @gate_cap "Run another round starts the next run. That run reads your comment and updates the proposal."

    test "with open questions: in the questions frame, above the open questions, inside the form" do
      html = decisions_tab(:questions, invoice_questions() ++ [decided(5)])
      q = "#work-item-explore-questions"

      assert text(html, "#{q}-h") == "Questions and decisions"
      assert text(html, "#{q}-cap") == @ask
      assert count(html, "#work-item-explore-decisions") == 0
      assert count(html, "#work-item-explore-gate") == 0

      # Answered and withdrawn questions stay at the top; then the decisions, then the
      # open questions, then the comment and Run another round.
      assert attr(html, "#{q}-closed > details", "id") == [
               "work-item-explore-questions-question-1",
               "work-item-explore-questions-question-4"
             ]

      assert texts(html, "#{q}-form > .q-xp-sec > h3") == ["Decisions", "Open questions"]

      assert attr(html, "#{q}-form > *", "class") |> Enum.reject(&is_nil/1) ==
               ["q-xp-sec", "q-xp-sec", "q-xp-comment", "q-xp-form-foot"]

      assert attr(html, "#{q}-decisions .q-xp-decs > details", "id") ==
               ["work-item-explore-questions-decision-5"]

      assert attr(html, "#{q}-comment", "placeholder") ==
               ["Add anything the questions and decisions do not cover."]

      # Folded: the question, the run's option, and the run's reason on a second line.
      row = "#{q}-decision-5"
      assert attr(html, row, "open") == []

      assert text(html, "#{row} > summary > .q-xp-wrap b") ==
               "5. Where can a customer change the date after paying?"

      assert text(html, "#{row} > summary > .q-xp-said") == "In the account page"

      assert text(html, "#{row} > summary > .q-xp-dec-why") ==
               "The account page already lists each open order."

      # Open: the reason, the run and when, the options with the run's option picked.
      assert text(html, "#{row} .q-xp-dec-r") ==
               "The account page already lists each open order."

      assert text(html, "#{row} .q-xp-cm-m") == "Run 41 chose it 12 minutes ago"

      field = "work-item-explore-questions-answer-5"

      assert attr(html, "##{field}-options input", "name") ==
               List.duplicate("answers[q5][option]", 3)

      assert attr(html, "##{field}-options input", "value") == ["1", "2", "own"]
      assert attr(html, "##{field}-options input", "checked") == [""]
      assert attr(html, "##{field}-1", "checked") == [""]
      assert attr(html, "##{field}-options input", "form") == []

      assert texts(html, "##{field}-options label") == [
               "In the account page Chosen by the agent The order gets a date field.",
               "In the order email A link opens the date step again.",
               "Give your own option"
             ]

      assert attr(html, "##{field}", "name") == ["answers[q5][note]"]
      assert attr(html, "##{field}", "placeholder") == ["Add details (optional)"]
      refute html =~ "Recommended by the agent"
    end

    test "Run another round: a changed decision enables it; the run's option again does not" do
      go = "#work-item-explore-questions-go"
      questions = invoice_questions() ++ [decided(5)]

      assert attr(decisions_tab(:questions, questions), go, "disabled") == [""]

      for same <- [%{"option" => "1"}, %{"option" => "1", "note" => " "}, %{"option" => ""}] do
        html = decisions_tab(:questions, questions, answers: %{"q5" => same})
        assert attr(html, go, "disabled") == [""]
      end

      for change <- [
            %{"option" => "2"},
            %{"option" => "own", "note" => "Only by phone."},
            %{"option" => "1", "note" => "And in the app."}
          ] do
        html = decisions_tab(:questions, questions, answers: %{"q5" => change})
        assert attr(html, go, "disabled") == []
        # The head keeps the run's option while the change is a draft.
        assert text(html, "#work-item-explore-questions-decision-5 > summary > .q-xp-said") ==
                 "In the account page"
      end

      own = decisions_tab(:questions, questions, answers: %{"q5" => %{"option" => "own"}})
      assert attr(own, "#work-item-explore-questions-answer-5", "placeholder") == ["Your option"]
    end

    test "without open questions: a frame between the proposal and the gate" do
      html =
        decisions_tab(:confirm, [
          decided(1),
          decided(2, %{text: "Does gift wrapping move the first date?"})
        ])

      d = "#work-item-explore-decisions"
      g = "#work-item-explore-gate"

      assert attr(html, "#work-item-explore > *", "id") |> Enum.take(3) ==
               [
                 "work-item-explore-proposal",
                 "work-item-explore-decisions",
                 "work-item-explore-gate"
               ]

      assert count(html, "#work-item-explore-questions") == 0
      assert text(html, "#{d}-h") == "Decisions"
      assert attr(html, "#{d} .q-xp-frame-i", "class") |> hd() =~ "hero-check-circle"

      assert attr(html, "#{d} .q-xp-decs > details", "id") == [
               "work-item-explore-decisions-decision-1",
               "work-item-explore-decisions-decision-2"
             ]

      # The fields belong to the gate's form, which sends them.
      assert attr(html, "#{d} input", "form") |> Enum.uniq() == ["work-item-explore-gate"]
      assert attr(html, "#{d} textarea", "form") |> Enum.uniq() == ["work-item-explore-gate"]

      assert text(html, "#{g} .q-xp-cap") == @gate_cap

      assert attr(html, "#{g}-comment", "placeholder") ==
               ["Add anything the questions and decisions do not cover."]

      assert attr(html, "#{g}-send", "disabled") == [""]
      assert attr(html, "#{g}-go", "disabled") == []
      assert count(html, "#{g}-hint") == 0
    end

    test "at the gate, a draft change: Run another round enabled, Approve disabled with why" do
      html =
        decisions_tab(:confirm, [decided(1), decided(2)],
          answers: %{"q2" => %{"option" => "2", "note" => ""}},
          review_comments: [comment("rc1")]
        )

      g = "#work-item-explore-gate"
      field = "#work-item-explore-decisions-answer-2"

      assert attr(html, "#{field}-2", "checked") == [""]
      assert attr(html, "#{field}-1", "checked") == []
      assert text(html, "#{field}-options label:first-child .badge") == "Chosen by the agent"

      assert text(html, "#work-item-explore-decisions-decision-2 > summary > .q-xp-said") ==
               "In the account page"

      assert count(html, "#work-item-explore-decisions .badge-sm.bg-primary-soft") == 0
      assert text(html, "#{g} .q-xp-cap") == @changed_cap
      assert attr(html, "#{g}-send", "disabled") == []
      assert attr(html, "#{g}-go", "disabled") == [""]
      assert attr(html, "#{g}-go", "aria-describedby") == ["work-item-explore-gate-hint"]
      assert text(html, "#{g}-hint") == "Run another round to apply your change."
      assert count(html, "#{g}-unread") == 0

      # The run's option again clears the change.
      same =
        decisions_tab(:confirm, [decided(1), decided(2)], answers: %{"q2" => %{"option" => "1"}})

      assert attr(same, "#{g}-go", "disabled") == []
      assert text(same, "#{g} .q-xp-cap") == @gate_cap
    end

    test "a changed decision: Changed and the member's option; open, the run's choice under Changed from" do
      sam = %{id: "pr_sam", name: "Sam", email: "sam@example.com", you: false}

      html =
        decisions_tab(:confirm, [
          decided(1),
          changed(2, sam, "In the order email", nil),
          changed(3, @dana, nil, "Only by phone.")
        ])

      row = "#work-item-explore-decisions-decision-2"
      assert text(html, "#{row} > summary .q-xp-dec-chg .badge") == "Changed"
      assert text(html, "#{row} > summary .q-xp-dec-said") == "In the order email"
      assert count(html, "#{row} > summary .q-xp-dec-why") == 0
      assert count(html, "#{row} input") == 0

      assert text(html, "#{row}-answer") == "In the order email"

      assert texts(html, "#{row} .q-xp-cm-m > span") ==
               ["Sam changed it 40 minutes ago", "Changed from", "Run 41 chose it 12 minutes ago"]

      assert html =~ ~r{>Changed from</span><wbr></wbr><span class="q-xp-it q-xp-by">}

      assert texts(html, "#{row} .q-xp-ans-old > span") ==
               ["In the account page", "The account page already lists each open order."]

      # A member's text in place of an option is the head's words.
      third = "#work-item-explore-decisions-decision-3"
      assert text(html, "#{third} > summary .q-xp-dec-said") == "Only by phone."
      assert text(html, "#{third} .q-xp-cm-m:first-of-type") == "You changed it 40 minutes ago"

      # Approve stays enabled: a sent change is not a draft.
      assert attr(html, "#work-item-explore-gate-go", "disabled") == []
    end

    test "the run's option with a note: no Changed; open, the options as text, who added the note and the note" do
      sam = %{id: "pr_sam", name: "Sam", email: "sam@example.com", you: false}

      html =
        decisions_tab(:confirm, [
          changed(1, sam, "In the account page", "Show the date in the order list too."),
          changed(2, @dana, "In the account page", "And in the app.")
        ])

      row = "#work-item-explore-decisions-decision-1"

      # Folded: the run's option and reason, as before the note.
      assert count(html, "#{row} > summary .badge") == 0
      assert count(html, "#{row} > summary .q-xp-dec-chg") == 0
      assert text(html, "#{row} > summary .q-xp-said") == "In the account page"

      assert text(html, "#{row} > summary .q-xp-dec-why") ==
               "The account page already lists each open order."

      # Opened: the run's choice as on a decision without an answer, then the note.
      assert text(html, "#{row} .q-xp-dec-r") ==
               "The account page already lists each open order."

      assert count(html, "#{row} input") == 0
      assert count(html, "#{row} textarea") == 0

      assert texts(html, "#{row} .q-xp-opts > li .q-xp-opt-t") == [
               "In the account page",
               "In the order email"
             ]

      assert texts(html, "#{row} .q-xp-cm-m") ==
               ["Run 41 chose it 12 minutes ago", "Sam added a note 40 minutes ago"]

      assert text(html, "#{row}-answer") == "Show the date in the order list too."
      refute html =~ "Changed from"
      assert count(html, "#{row} .q-xp-ans-old") == 0

      second = "#work-item-explore-decisions-decision-2"
      assert text(html, "#{second} .q-xp-cm-m:last-of-type") == "You added a note 40 minutes ago"

      # A note is no draft: Approve stays enabled.
      assert attr(html, "#work-item-explore-gate-go", "disabled") == []
    end

    test "a reader who may not change them reads the options as text" do
      html = decisions_tab(:confirm, [decided(1)], can_change: false, can_send: false)
      d = "#work-item-explore-decisions"

      assert count(html, "#{d} input") == 0
      assert count(html, "#{d} textarea") == 0

      assert texts(html, "#{d}-decision-1 .q-xp-opts > li") == [
               "In the account page Chosen by the agent The order gets a date field.",
               "In the order email A link opens the date step again."
             ]

      assert count(html, "#work-item-explore-gate-send") == 0
      assert attr(html, "#work-item-explore-gate-go", "disabled") == []

      # While a run runs, the decisions in the questions frame are text too.
      running =
        tab(invoice_item(%{status: :running, run: running_run(3)}),
          can_act: true,
          can_change: true,
          questions: invoice_questions() ++ [decided(5)]
        )

      assert count(running, "#work-item-explore-questions-decisions input") == 0

      assert texts(running, "#work-item-explore-questions .q-xp-sec > h3") ==
               ["Decisions", "Open questions"]
    end

    test "decision_changed?/2: another option, Give your own option, or a note" do
      question = decided(2)
      refute C.decision_changed?(question, nil)
      refute C.decision_changed?(question, %{"option" => "1"})
      refute C.decision_changed?(question, %{"option" => "", "note" => "  "})
      assert C.decision_changed?(question, %{"option" => "2"})
      assert C.decision_changed?(question, %{"option" => "own"})
      assert C.decision_changed?(question, %{"option" => "1", "note" => "Also by phone."})
      refute C.decision_changed?(changed(2, @dana, "In the order email", nil), %{"option" => "2"})
      refute C.decision_changed?(q(2), %{"option" => "1"})
    end

    test "the row's reason is cut to one line, and hidden in the opened row" do
      css = app_css()
      assert css =~ ~r/\.q-xp-dec-why \{[^}]*white-space: nowrap;[^}]*text-overflow: ellipsis;/s
      assert css =~ ~r/details\[open\] > summary > \.q-xp-dec-why \{\s*display: none;/
      assert css =~ ~r/\.q-xp-dec-said \{[^}]*text-overflow: ellipsis;/s
    end

    @no_comment_cap "Run another round starts the next run. That run reads your answers and your changed decisions, and updates the proposal."
    @gate_no_comment_cap "Run another round starts the next run. That run reads your changed decisions and updates the proposal."

    test "may change them and may not comment: the caption at the gate has no comment" do
      gate = "#work-item-explore-gate"

      for can_act <- [false, true], answers <- [%{}, %{"q1" => %{"option" => "2"}}] do
        html =
          decisions_tab(:confirm, [decided(1)],
            can_act: can_act,
            can_send: false,
            answers: answers
          )

        assert text(html, "#{gate} .q-xp-cap") == @gate_no_comment_cap
        assert count(html, "#{gate}-comment") == 0
        assert count(html, "#{gate}-send") == 1
      end
    end

    test "may change them and may not comment: the caption under the questions has no comment" do
      html = decisions_tab(:questions, invoice_questions() ++ [decided(5)], can_send: false)
      q = "#work-item-explore-questions"

      assert text(html, "#{q}-cap") == @no_comment_cap
      assert count(html, "#{q}-comment") == 0
      assert count(html, "#{q}-decisions input[name='answers[q5][option]']") == 3
    end

    test "every decision sent: no field, no words about a changed decision, and no gate with nothing to send" do
      sent = changed(1, @dana, "In the order email", nil)

      # A reader with only the right to change decisions has nothing left to send.
      html = decisions_tab(:confirm, [sent], can_act: false, can_send: false)
      assert count(html, "#work-item-explore-gate") == 0
      assert count(html, "#work-item-explore-decisions-decision-1 .badge") == 1

      # An approver has the gate, with the caption for a comment.
      html = decisions_tab(:confirm, [sent])
      assert text(html, "#work-item-explore-gate .q-xp-cap") == @gate_cap

      # Under the questions the caption is about the answers and the comment.
      html = decisions_tab(:questions, invoice_questions() ++ [changed(5, @dana, "A", nil)])

      assert text(html, "#work-item-explore-questions-cap") ==
               "Run another round starts the next run. That run reads your answers and your comment, and updates the proposal."
    end

    test "one decision sent and one not: the unsent one keeps its fields" do
      html = decisions_tab(:confirm, [changed(1, @dana, "In the order email", nil), decided(2)])

      assert count(html, "#work-item-explore-decisions-decision-1 input") == 0
      assert count(html, "#work-item-explore-decisions-decision-2 input[type=radio]") == 3
    end

    test "a reopened decision answered with the run's option and no note: the answered line" do
      sam = %{id: "u2", name: "Sam", email: "sam@example.com", you: false}
      html = decisions_tab(:confirm, [changed(1, sam, "In the account page", nil), decided(2)])
      row = "#work-item-explore-decisions-decision-1"

      assert count(html, "#{row} .badge:not(.justify-self-start)") == 0
      assert count(html, "#{row} > summary .q-xp-dec-chg") == 0
      assert text(html, "#{row} > summary .q-xp-said") == "In the account page"
      assert count(html, "#{row} input") == 0
      assert count(html, "#{row} textarea") == 0

      assert texts(html, "#{row} .q-xp-opts > li .q-xp-opt-t") ==
               ["In the account page", "In the order email"]

      assert texts(html, "#{row} .q-xp-cm-m") ==
               ["Run 41 chose it 12 minutes ago", "Sam answered 40 minutes ago"]

      assert count(html, "#{row}-answer") == 0
      refute html =~ "added a note"
      refute html =~ "Changed from"
    end

    test "a reader with no right to change them reads Decisions, with no Run another round" do
      html =
        decisions_tab(:confirm, [decided(1)], can_act: false, can_send: false, can_change: false)

      d = "#work-item-explore-decisions"

      assert count(html, "#{d}-decision-1") == 1
      assert count(html, "#{d} input") == 0
      assert count(html, "#{d} textarea") == 0
      assert count(html, "#{d}-decision-1 .q-xp-opts > li") == 2
      assert count(html, "#work-item-explore-gate-send") == 0
      assert count(html, "#work-item-explore-gate") == 0
    end

    defp repeated(number, overrides \\ %{}) do
      decided(
        number,
        Map.merge(
          %{
            options: [
              %{title: "In the account page", explanation: "First."},
              %{title: "In the account page", explanation: "Second, with the same title."},
              %{title: "In the order email", explanation: "Third."}
            ]
          },
          overrides
        )
      )
    end

    test "decision_changed?/2 compares titles, as the move does, not places" do
      question = repeated(1)
      refute C.decision_changed?(question, %{"option" => "1"})
      refute C.decision_changed?(question, %{"option" => "2"})
      assert C.decision_changed?(question, %{"option" => "3"})
      assert C.decision_changed?(question, %{"option" => "own"})
      assert C.decision_changed?(question, %{"option" => "9"})
      assert C.decision_changed?(question, %{"option" => "0"})
      assert C.decision_changed?(question, %{"option" => "2", "note" => "And by phone."})

      spaced =
        repeated(1, %{
          options: [
            %{title: "In the account page ", explanation: "Trailing space."},
            %{title: "In the order email", explanation: "Second."}
          ]
        })

      refute C.decision_changed?(spaced, %{"option" => "1"})
      assert C.decision_changed?(spaced, %{"option" => "2"})
    end

    test "a title that differs by a trailing space: the card shows as the run's option" do
      spaced =
        decided(1, %{
          options: [
            %{title: "In the account page ", explanation: "Trailing space."},
            %{title: "In the order email", explanation: "Second."}
          ]
        })

      html = decisions_tab(:confirm, [spaced])
      field = "#work-item-explore-decisions-answer-1"

      assert count(html, "#{field}-1[checked]") == 1
      assert text(html, "#{field}-options > label:first-child .badge") == "Chosen by the agent"
    end

    test "the second card of the run's title is no change: Approve stays, Run another round waits" do
      html = decisions_tab(:confirm, [repeated(1)], answers: %{"q1" => %{"option" => "2"}})
      gate = "#work-item-explore-gate"

      assert attr(html, "#{gate}-go", "disabled") == []
      assert attr(html, "#{gate}-send", "disabled") != []
      assert count(html, "#{gate}-hint") == 0

      html =
        decisions_tab(:questions, invoice_questions() ++ [repeated(5)],
          answers: %{"q5" => %{"option" => "2"}}
        )

      assert attr(html, "#work-item-explore-questions-go", "disabled") != []
    end

    test "a send that wrote nothing because the questions changed shows its line at the gate" do
      html = decisions_tab(:confirm, [decided(1)], form_error: :stale)

      assert text(html, "#work-item-explore-gate-error") =~
               "The questions changed after the page showed them"

      # The line of the move comes first, as under the questions.
      html = decisions_tab(:confirm, [decided(1)], form_error: :stale, move_error: "Not sent.")
      assert text(html, "#work-item-explore-gate-error") == "Not sent."
    end

    test "an error in a decision: its line under the field, and the fold opened after each send" do
      for {frame, questions} <- [
            {"#work-item-explore-decisions", [decided(1)]},
            {"#work-item-explore-questions", [decided(1), q(2)]}
          ] do
        status = if length(questions) == 1, do: :confirm, else: :questions

        html =
          decisions_tab(status, questions,
            answers: %{"q1" => %{"option" => "own", "note" => ""}},
            errors: %{"q1" => :note_required},
            submits: 3
          )

        row = "#{frame}-decision-1"
        assert count(html, "#{frame}-answer-1-error") == 1
        assert attr(html, "#{frame}-answer-1", "aria-invalid") == ["true"]

        assert [opens] = attr(html, "#{row}-opens-3", "phx-mounted")
        assert opens =~ ~s(#{row}:not([open]\) > summary)
        assert opens =~ "click"
        assert attr(html, "#{row}-opens-3", "hidden") != []
      end

      html = decisions_tab(:confirm, [decided(1)], submits: 3)
      assert count(html, "#work-item-explore-decisions-decision-1-opens-3") == 0
    end

    test "an error in a decision at the gate: focus moves to the first such field" do
      d = "#work-item-explore-decisions"

      html =
        decisions_tab(:confirm, [decided(1), decided(2), decided(3)],
          answers: %{
            "q2" => %{"option" => "own", "note" => ""},
            "q3" => %{"option" => "own", "note" => ""}
          },
          errors: %{"q2" => :note_required, "q3" => :note_required},
          submits: 3
        )

      assert [focus] = attr(html, "#{d}-focus-3-2", "phx-mounted")
      assert focus =~ "#{d}-answer-2"
      assert attr(html, "#{d}-focus-3-2", "hidden") != []
      assert count(html, "#{d}-focus-3-3") == 0

      # No error, and a reader with no fields: no focus moves.
      assert count(
               decisions_tab(:confirm, [decided(1)], submits: 3),
               "[id^='work-item-explore-decisions-focus-']"
             ) == 0

      html =
        decisions_tab(:confirm, [decided(1)],
          can_change: false,
          errors: %{"q1" => :note_required},
          submits: 3
        )

      assert count(html, "[id^='work-item-explore-decisions-focus-']") == 0
    end

    test "an error in a decision under the questions: focus moves there before an open question" do
      q = "#work-item-explore-questions"

      html =
        decisions_tab(:questions, [decided(1), q(2)],
          answers: %{"q1" => %{"option" => "own", "note" => ""}},
          errors: %{"q1" => :note_required, "q2" => :note_required},
          submits: 3
        )

      assert [focus] = attr(html, "#{q}-focus-3-1", "phx-mounted")
      assert focus =~ "#{q}-answer-1"
      assert count(html, "#{q}-focus-3-2") == 0
    end

    test "a question that follows a decision links to the decision's row" do
      html =
        decisions_tab(:questions, [
          decided(1),
          q(2, %{text: "Which basket?", follows: [1]})
        ])

      q = "work-item-explore-questions"

      assert text(html, "##{q}-question-2 a") == "Follows question 1"
      assert attr(html, "##{q}-question-2 a", "href") == ["##{q}-question-1"]
      assert text(html, "##{q}-decision-1 > summary ##{q}-question-1") =~ "1."
    end

    test "a decision in its frame has the address a reply links to" do
      html = decisions_tab(:confirm, [decided(1)])

      assert text(
               html,
               "#work-item-explore-decisions-decision-1 > summary #work-item-explore-questions-question-1"
             ) =~ "1."
    end
  end
end
