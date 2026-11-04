defmodule ApiaryWeb.WorkItemLive.ShowTest do
  # A work item's page (`ApiaryWeb.WorkItemLive.Show`): its tabs, not found for a number
  # no work item of the workspace has; what a reader does there (the answers, Confirm, a
  # comment on the proposal, Close, Run Explore again),
  # each refused without words where the page read an earlier state, and the form's
  # errors under its fields; the page read again on a message of its work item, with the
  # scope first, as after a refused action; people by the short name of their account,
  # and a deleted account as a former member; a run's link only where the reader may read
  # the runs of the workspace it ran in, after the work item moved; and a close by the
  # instance.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, dispatched!: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [event_fixture: 4]
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Projector
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp page(scope, number, tail \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <> tail

  # A work item as a take in leaves it: its first run waiting in the queue.
  defp queued(scope) do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, state: :waiting)
    work_item
  end

  defp asked(scope) do
    work_item = work_item_fixture(scope)
    %{run: run} = explore_run_fixture(work_item, result: questions_result())
    {work_item, run}
  end

  defp proposed(scope) do
    work_item = work_item_fixture(scope)
    %{run: run} = explore_run_fixture(work_item, result: understood_result())
    {work_item, run}
  end

  defp state(work_item), do: Repo.get!(WorkItem, work_item.id).state

  # Runs `push` with the run of the queue `dispatch_run` live, as a run pushes before it
  # ends (`Apiary.Artifacts.push/5` returns `{:error, :run_ended}` for a run that
  # ended), then sets the run back to its state, end and outcome.
  defp while_live(dispatch_run, push) do
    was = Repo.get!(DispatchRun, dispatch_run.id)
    set_run!(was, state: :handed_over, end_cause: nil, result_outcome: nil, result: nil)
    value = push.()

    set_run!(
      was,
      Keyword.new([:state, :end_cause, :result_outcome, :result], &{&1, Map.fetch!(was, &1)})
    )

    value
  end

  defp set_run!(dispatch_run, changes) do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id), set: changes)
  end

  # How many runs of the queue the work item has.
  defp runs(work_item),
    do: Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

  # The answers of the newest questions, in order: `{option, note}` each.
  defp answered(work_item) do
    case Apiary.Explore.Questions.newest(work_item) do
      {_version, document} ->
        for %{"state" => "answered", "answer" => answer} <- document["questions"],
            do: {answer["option"], answer["note"]}

      nil ->
        []
    end
  end

  describe "the tabs" do
    test "Ticket, Explore and the Thread, with the header, the step card and Details", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      assert html =~ "The checkout keeps the old price"
      assert has_element?(view, "#work-item-head-title")
      assert has_element?(view, "#work-item-step")
      assert has_element?(view, "#work-item-details")
      assert has_element?(view, "#work-item-ticket-text")
      assert render(view) =~ "The basket shows the price from before the sale."

      view |> element("#work-item-tabs a", "Explore") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore")

      view |> element("#work-item-tabs a", "Thread") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/thread"))
      assert has_element?(view, "#work-item-thread-ev-1")
      assert render(view) =~ "You took this in from"
    end

    test "the ticket's title as a page shows it, and none where nothing is left", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [title: "Totals \u202Eoff\u202C by a cent"]
      )

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      refute html =~ "\u202E"
      assert has_element?(view, "#work-item-head-title bdi", "Totals off by a cent")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [title: "\u202E\u200B"]
      )

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      refute has_element?(view, "#work-item-head-title bdi")

      assert has_element?(
               view,
               "#work-item-head-title",
               "#" <> Integer.to_string(work_item.number)
             )
    end

    test "a title of only whitespace or invisible characters is no title: the header says its number",
         %{conn: conn, scope: scope} do
      for title <- ["\u00A0", "\u202E\u200B"] do
        work_item = queued(scope)
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [title: title])

        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        refute has_element?(view, "#work-item-head-title bdi")
        assert has_element?(view, "#work-item-head-title", "##{work_item.number}")
      end
    end

    test "a take in whose first run is not written yet reads as queued, on every tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)

      for tail <- ["", "/explore", "/thread"] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number, tail))
        assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      end

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-run", "Attempt 1")
      refute has_element?(view, "#work-item-explore-run", "of 3")
      assert has_element?(view, "#work-item-explore-run", "Queued")
    end

    test "a number no work item of the workspace has is not found", %{conn: conn, scope: scope} do
      for number <- ["99", "0", "x", "1" <> String.duplicate("0", 30)] do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, page(scope, number)) end
      end

      %{scope: other} = sign_up_fixture()
      theirs = queued(other)

      assert get(conn, ~p"/#{other.organisation}/#{other.workspace}/work/#{theirs.number}").status ==
               404
    end
  end

  describe "the answers" do
    test "the form sends an option, an option with a note, and a note alone; the next run is queued",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)

      explore_run_fixture(work_item,
        result:
          questions_result([
            %{
              "question" => "Which currency should the invoice PDF show?",
              "options" => [
                %{"title" => "The order's currency", "explanation" => "What the customer paid."},
                %{"title" => "The shop's currency", "explanation" => "What the books keep."}
              ]
            },
            %{
              "question" => "Should the credit note PDF change too?",
              "options" => [%{"title" => "Yes", "explanation" => "Both use one template."}]
            },
            "Which invoices are affected?"
          ])
      )

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-questions-answer-1-options[role=radiogroup]")
      assert has_element?(view, "#work-item-explore-questions-answer-1-own[value=own]")

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => Integer.to_string(work_item.number),
        "answers" => %{
          "q1" => %{"option" => "1", "note" => "", "x" => "y"},
          "q2" => %{"option" => "1", "note" => "Only for bank refunds."},
          "q3" => %{"note" => "Every invoice since 1 October."},
          "x" => %{"note" => "y"}
        },
        "other" => "z"
      })

      assert answered(work_item) == [
               {"The order's currency", nil},
               {"Yes", "Only for bank refunds."},
               {nil, "Every invoice since 1 October."}
             ]

      assert runs(work_item) == 2
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      refute has_element?(view, "#work-item-explore-questions-form")
    end

    test "Give your own option needs the field: the error under it, the draft kept, nothing written",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)

      explore_run_fixture(work_item,
        result:
          questions_result([
            %{
              "question" => "Which currency should the invoice PDF show?",
              "options" => [
                %{"title" => "The order's currency", "explanation" => "What the customer paid."}
              ]
            }
          ])
      )

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      form = element(view, "#work-item-explore-questions-form")
      field = "#work-item-explore-questions-answer-1"

      assert has_element?(view, ~s|#{field}[placeholder="Add details (optional)"]|)

      render_change(form, %{"answers" => %{"q1" => %{"option" => "own", "note" => ""}}})
      assert has_element?(view, ~s(#{field}[placeholder="Your option"][aria-label="Your option"]))
      assert has_element?(view, "#{field}-own[checked]")

      render_submit(form, %{
        "number" => Integer.to_string(work_item.number),
        "answers" => %{"q1" => %{"option" => "own", "note" => "  "}}
      })

      assert has_element?(view, "#{field}-error", "Write your option, or pick one above.")
      assert has_element?(view, ~s(#{field}[aria-invalid="true"]))
      assert has_element?(view, "#{field}-own[checked]")
      assert answered(work_item) == []
      assert runs(work_item) == 1

      render_submit(form, %{
        "number" => Integer.to_string(work_item.number),
        "answers" => %{
          "q1" => %{"option" => "own", "note" => "The currency of the shop's country."}
        }
      })

      assert answered(work_item) == [{nil, "The currency of the shop's country."}]
      assert runs(work_item) == 2
    end

    test "a partial send writes the answers with text; the rest stays open", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => Integer.to_string(work_item.number),
        "answers" => %{"q1" => %{"note" => "The one at checkout."}, "q2" => %{"note" => "  "}}
      })

      assert answered(work_item) == [{nil, "The one at checkout."}]
      {_version, document} = Apiary.Explore.Questions.newest(work_item)
      assert Enum.map(document["questions"], & &1["state"]) == ["answered", "open"]
      assert runs(work_item) == 2
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
    end

    test "a send with no answer is refused under the form, and nothing is written", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => Integer.to_string(work_item.number),
        "answers" => %{"q1" => %{"note" => " "}, "q2" => %{"note" => "  "}}
      })

      assert has_element?(
               view,
               "#work-item-explore-questions-error[role=alert]",
               "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
             )

      refute has_element?(view, "[aria-invalid]")
      assert state(work_item) == :exploring
      assert answered(work_item) == []
      assert runs(work_item) == 1
    end

    test "an answer that is not text counts as none: the form's error, and nothing is written",
         %{conn: conn, scope: scope} do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      for forged <- [
            %{"a" => "b"},
            %{"note" => ["x"]},
            %{"option" => %{"x" => "1"}},
            ["x"],
            1.5,
            true,
            7,
            nil
          ] do
        html =
          render_hook(view, "answer", %{
            "number" => Integer.to_string(work_item.number),
            "answers" => %{"q1" => forged, "q2" => %{"note" => "  "}}
          })

        assert html =~
                 "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
      end

      # An option out of range, or a word, picks nothing.
      for option <- ["0", "9", "-1", "own1", "The one at checkout"] do
        render_hook(view, "answer", %{
          "number" => Integer.to_string(work_item.number),
          "answers" => %{"q1" => %{"option" => option}}
        })

        assert has_element?(
                 view,
                 "#work-item-explore-questions-error",
                 "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
               ),
               option

        assert answered(work_item) == [], option
      end

      render_hook(view, "answer", %{
        "number" => Integer.to_string(work_item.number),
        "answers" => "x"
      })

      assert answered(work_item) == []
      assert state(work_item) == :exploring
    end

    test "answers sent after another member answered are refused without words", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      {:ok, _} =
        WorkItems.answer(scope, work_item, 1, [
          %{"id" => "q1", "note" => "First."},
          %{"id" => "q2", "note" => "Second."}
        ])

      html =
        render_hook(view, "answer", %{
          "number" => Integer.to_string(work_item.number),
          "answers" => %{"q1" => %{"note" => "Late."}, "q2" => %{"note" => "Late."}}
        })

      refute html =~ "Late."
      refute html =~ "Choose an option"
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      assert answered(work_item) == [{nil, "First."}, {nil, "Second."}]
      assert runs(work_item) == 2
    end
  end

  describe "the gate and review comments" do
    test "the step card links Explore's tab, where Confirm confirms", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-step button")
      view |> element("#work-item-step-explore", "Read the proposal") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/explore"))

      # No review comment open: Confirm alone, the primary button.
      refute has_element?(view, "#work-item-explore-gate-send")
      refute has_element?(view, "#work-item-explore-gate-unread")
      view |> element("#work-item-explore-gate-go", "Confirm") |> render_click()

      assert has_element?(view, "#work-item-step .q-wi-badge", "Ready")
      refute has_element?(view, "#work-item-explore-gate")
      refute has_element?(view, "#work-item-explore-proposal-review-add")
      assert has_element?(view, "#work-item-explore-proposal .badge", "Confirmed")

      assert %{result: %{"proposal_version" => 1}} =
               Apiary.WorkItems.Explore.confirmation(work_item.id, 1)

      assert runs(work_item) == 1
    end

    test "Add review comment is a page: it writes an open review comment, then Run with comments queues one run",
         %{conn: conn, scope: scope} do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      view |> element("#work-item-explore-proposal-review-add") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/explore?review=new"))
      assert has_element?(view, "#work-item-review-page h1", "Add review comment")
      refute has_element?(view, "#work-item-explore")

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "text" => "Show the order's currency."
      })

      assert_patch(view, page(scope, work_item.number, "/explore"))
      refute has_element?(view, "#work-item-review-page")

      {_version, comments} = Apiary.Explore.ReviewComments.newest(work_item)

      assert [%{"id" => "c1", "text" => "Show the order's currency.", "state" => "open"} = c1] =
               comments["review_comments"]

      assert c1["on"]["version"] == 1
      # A review comment queues no run.
      assert runs(work_item) == 1

      card = "#work-item-review-c1"
      assert has_element?(view, "#{card} .q-rc-by", "You, on version 1")
      assert has_element?(view, "#{card} .badge", "Open")
      assert has_element?(view, "#{card} .q-rc-text", "Show the order's currency.")
      assert has_element?(view, "#work-item-explore-proposal-review-c1")

      gate = "#work-item-explore-gate"

      assert has_element?(
               view,
               gate,
               "Running again sends your review comments, and the agent updates the proposal."
             )

      assert has_element?(view, "#{gate}-unread", "Confirm leaves 1 review comment unread.")

      view |> element(gate) |> render_submit(%{"number" => "#{work_item.number}"})

      assert runs(work_item) == 2
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      refute has_element?(view, gate)
      refute has_element?(view, "#work-item-explore-proposal-review-add")
      refute has_element?(view, "#{card}-reply")
      assert has_element?(view, "#{card}-reading", "Attempt 2 reads this review comment.")

      # A second send while the run is queued changes nothing.
      render_hook(view, "run_with_comments", %{"number" => "#{work_item.number}"})
      assert runs(work_item) == 2
    end

    test "Confirm with open review comments shows how many it leaves unread, and confirms", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = proposed(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Show the order's currency.")
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Keep the old PDFs.")

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(
               view,
               "#work-item-explore-gate-unread",
               "Confirm leaves 2 review comments unread."
             )

      assert has_element?(view, "#work-item-explore-gate-send", "Run with comments")
      view |> element("#work-item-explore-gate-go", "Confirm") |> render_click()

      assert has_element?(view, "#work-item-step .q-wi-badge", "Ready")
      assert runs(work_item) == 1
    end

    test "Reply is a page: a member's reply to a review comment a run closed opens it again", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)

      %{dispatch_run: dispatch_run, run: run} =
        explore_run_fixture(work_item, result: understood_result())

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Show the order's currency.")
      while_live(dispatch_run, fn -> reply_as_run!(dispatch_run, run, "declined") end)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      card = "#work-item-review-c1"
      assert has_element?(view, "#{card}.q-rc-done")
      # The only closed card is the first of the closed ones, so it is opened.
      assert has_element?(view, "#{card}-h[aria-expanded=true]")
      assert has_element?(view, "#{card} .q-rc-out", "Declined in version 1")
      refute has_element?(view, "#{card} .badge")
      refute has_element?(view, "#work-item-explore-gate-unread")

      view |> element("#{card}-reply") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/explore?reply=c1"))
      assert has_element?(view, "#work-item-review-page h1", "Reply")

      assert has_element?(
               view,
               "#work-item-review-page-comment .q-rc-text",
               "Show the order's currency."
             )

      form = element(view, "#work-item-review-page-form")
      render_submit(form, %{"number" => "#{work_item.number}", "comment" => "c1", "text" => " "})
      assert has_element?(view, "#work-item-review-page-error", "Write your reply.")

      render_submit(form, %{
        "number" => "#{work_item.number}",
        "comment" => "c1",
        "text" => "The customer pays in their currency."
      })

      assert_patch(view, page(scope, work_item.number, "/explore"))

      {_version, comments} = Apiary.Explore.ReviewComments.newest(work_item)

      assert [%{"state" => "open", "replies" => [_run_reply, member]}] =
               comments["review_comments"]

      assert member["text"] == "The customer pays in their currency."

      assert has_element?(view, "#{card} .badge", "Reopened")

      assert has_element?(
               view,
               "#{card}-reply-2.q-rc-member",
               "The customer pays in their currency."
             )

      assert has_element?(
               view,
               "#work-item-explore-gate-unread",
               "Confirm leaves 1 review comment unread."
             )

      assert runs(work_item) == 1
    end

    test "a run's reply with the outcome asked, as stored: Asked as question 1, linked to that question",
         %{
           conn: conn,
           scope: scope
         } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result())
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the refund rule.")

      %{dispatch_run: dispatch_run, run: run} =
        explore_run_fixture(work_item, result: questions_result(["Which refund?"]))

      while_live(dispatch_run, fn -> reply_as_run!(dispatch_run, run, "asked", "q1") end)

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)

      assert [%{"replies" => [%{"outcome" => "asked", "question" => "q1"}]}] =
               document["review_comments"]

      explore = page(scope, work_item.number, "/explore")
      {:ok, view, _html} = live(conn, explore)
      target = "work-item-explore-questions-question-1"
      assert has_element?(view, "##{target}", "Which refund?")

      inline = "#work-item-explore-proposal-review-c1-reply-1 a"
      assert has_element?(view, inline, "Asked as question 1")
      assert has_element?(view, ~s(#{inline}[href="##{target}"]))

      rail = "#work-item-review-c1-reply-1 a"
      assert has_element?(view, rail, "Asked as question 1")
      assert has_element?(view, ~s(#{rail}[href="#{explore}##{target}"]))
    end

    test "a review comment page the reader may not use goes back to Explore's tab", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = proposed(scope)

      # Opened at its address: sent to Explore's tab.
      explore = page(scope, work_item.number, "/explore")
      assert {:error, {:live_redirect, %{to: ^explore}}} = live(conn, explore <> "?reply=c9")

      queued = queued(scope)
      queued_explore = page(scope, queued.number, "/explore")

      assert {:error, {:live_redirect, %{to: ^queued_explore}}} =
               live(conn, queued_explore <> "?review=new")

      # Patched to from the tab: back to the tab.
      {:ok, view, _html} = live(conn, explore)
      render_patch(view, explore <> "?reply=c9")
      assert_patch(view, explore)
      refute has_element?(view, "#work-item-review-page")
      assert has_element?(view, "#work-item-explore")
    end

    test "Add review comment without a proposal goes back to Explore's tab", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)
      explore = page(scope, work_item.number, "/explore")

      assert {:error, {:live_redirect, %{to: ^explore}}} = live(conn, explore <> "?review=new")

      {:ok, view, _html} = live(conn, explore)
      refute has_element?(view, "#work-item-explore-proposal-review-add")
      render_patch(view, explore <> "?review=new")
      assert_patch(view, explore)
      refute has_element?(view, "#work-item-review-page")
      assert has_element?(view, "#work-item-explore")
    end

    test "another form page starts with an empty field and no error", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = proposed(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Show the order's currency.")
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Keep the old PDFs.")
      explore = page(scope, work_item.number, "/explore")
      number = "#{work_item.number}"

      {:ok, view, _html} = live(conn, explore <> "?reply=c1")

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{"number" => number, "comment" => "c1", "text" => " "})

      assert has_element?(view, "#work-item-review-page-error", "Write your reply.")

      render_patch(view, explore)
      render_patch(view, explore <> "?review=new")
      assert has_element?(view, "#work-item-review-page h1", "Add review comment")
      refute has_element?(view, "#work-item-review-page-error")
      refute has_element?(view, ~s(#work-item-review-page-text[aria-invalid]))

      long = String.duplicate("a", 2_001)
      render_patch(view, explore <> "?reply=c1")

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{"number" => number, "comment" => "c1", "text" => long})

      assert has_element?(view, "#work-item-review-page-text", long)

      render_patch(view, explore)
      render_patch(view, explore <> "?reply=c2")
      assert has_element?(view, "#work-item-review-page-comment .q-rc-text", "Keep the old PDFs.")
      refute has_element?(view, "#work-item-review-page-text", long)
      refute has_element?(view, "#work-item-review-page-error")
    end

    test "the proposal's Markdown on the tab, and the review comment in the Thread", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(view, "#work-item-explore-proposal-text h4", "What this is")
      assert has_element?(view, "#work-item-explore-proposal-text li", "Clear the basket")
      assert has_element?(view, "#work-item-explore-proposal .q-xp-cap", "Version 1")
      refute render(view) =~ "wrote this"
      refute has_element?(view, "#work-item-explore-run")

      {:ok, page_view, _html} = live(conn, page(scope, work_item.number, "/explore?review=new"))

      page_view
      |> element("#work-item-review-page-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "text" => "Offer **a refund** first."
      })

      {:ok, thread, _html} = live(conn, page(scope, work_item.number, "/thread"))
      html = render(thread)
      assert html =~ "You wrote a review comment on the proposal"
      assert html =~ "Offer **a refund** first."
      refute html =~ "<strong>a refund</strong>"
    end

    test "a blank, long or hidden-character review comment is refused under the field, and the text stays",
         %{conn: conn, scope: scope} do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore?review=new"))
      form = element(view, "#work-item-review-page-form")
      number = "#{work_item.number}"

      render_submit(form, %{"number" => number, "text" => " \n "})
      assert has_element?(view, "#work-item-review-page-error", "Write your review comment.")
      assert has_element?(view, ~s(#work-item-review-page-text[aria-invalid="true"]))

      long = String.duplicate("a", 2_001)
      render_submit(form, %{"number" => number, "text" => long})

      assert has_element?(
               view,
               "#work-item-review-page-error",
               "Shorten the comment to 2,000 characters or fewer."
             )

      assert has_element?(view, "#work-item-review-page-text", long)

      render_submit(form, %{"number" => number, "text" => "Offer \u202Ea refund."})

      assert has_element?(
               view,
               "#work-item-review-page-error",
               "Remove the invisible or control characters from the comment."
             )

      assert Apiary.Explore.ReviewComments.newest(work_item) == nil
      assert state(work_item) == :exploring
    end

    test "the edit page is gone", %{conn: conn, scope: scope} do
      {work_item, _run} = proposed(scope)
      assert get(conn, page(scope, work_item.number, "/explore/edit")).status == 404
    end
  end

  describe "Close and Run Explore again" do
    test "Close asks under the header, then closes", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> element("#work-item-head-close") |> render_click()
      assert has_element?(view, "#work-item-close")
      view |> element("#work-item-close-go") |> render_click()

      assert state(work_item) == :closed
    end

    test "Run Explore again after a run without a result", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, run: %{exit_state: "failed", state: "failed"})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> element("#work-item-step-again") |> render_click()
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
    end

    test "the run-limit card shows Close work item… to a person who may close",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)

      for _attempt <- 1..3 do
        explore_run_fixture(work_item, run: %{exit_state: "failed", state: "failed"})
      end

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step .q-wi-badge", "3 of 3 attempts used")
      assert has_element?(view, "#work-item-step-close", "Close work item…")
    end

    test "questions at the take in's third run still take answers, which queue a fourth",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)

      for _attempt <- 1..3 do
        explore_run_fixture(work_item, result: questions_result(["Which invoices?"]))
      end

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      refute has_element?(view, "#work-item-step-close")
      assert has_element?(view, "#work-item-explore-questions-form")

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q3" => %{"note" => "Every invoice since 1 October."}}
      })

      assert runs(work_item) == 4
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
    end

    test "an event for another number does nothing", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "close", %{"number" => "#{work_item.number + 1}"})
      render_hook(view, "close", %{"number" => "#{work_item.number}x"})
      assert state(work_item) == :exploring
    end
  end

  describe "a run that ended at its handover, before it started" do
    test "Explore's tab says what to fix and why; neither tab says the run ended with an error",
         %{conn: conn, scope: scope} do
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
        work_item = work_item_fixture(scope)
        explore_run_fixture(work_item, end_cause: cause)

        {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))

        assert has_element?(
                 view,
                 "#work-item-explore-none-h",
                 "The run did not start."
               )

        assert has_element?(view, "#work-item-explore-none p", body)
        refute html =~ "ended with an error"
        refute html =~ "The run&#39;s last result was an error"

        {:ok, _view, html} = live(conn, page(scope, work_item.number, "/thread"))
        refute html =~ "ended with an error"
      end
    end

    test "a run that stopped at a call to an adapter names the adapter on Explore's tab",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      %{dispatch_run: run} = explore_run_fixture(work_item, end_cause: :inputs_invalid)
      name = "code-host-#{System.unique_integer([:positive])}"
      adapter = Apiary.NodesFixtures.adapter_fixture(%{name: name})

      :ok =
        Apiary.Adapters.Calls.record_failure(Apiary.Repo, run, %Apiary.Adapters.CallFailure{
          adapter_id: adapter.id,
          adapter_public_id: adapter.public_id,
          adapter_name: adapter.name,
          path: "resolve",
          cause: :unreachable
        })

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(
               view,
               "#work-item-explore-none-adapter",
               "Contact support. The run did not start: the call to #{name} for the harness sources did not reach it."
             )
    end

    test "a run whose last result was an error still says so", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      %{dispatch_run: dispatch_run} = explore_run_fixture(work_item)

      # A release that read the run's result event stored `error` for one whose
      # `is_error` was true; Core reads that event no more, and the row keeps it.
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
          set: [result_outcome: :error]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-none-h", "The run ended with an error.")
    end
  end

  describe "a run the gateway refused" do
    @key_fix "Add a model key in Organisation settings › Model providers."

    # Run `attempt` of 3 of a work item, refused by its gateway with `code` through the
    # refusal's path: queued, claimed and handed over, then its `run.refused` event
    # projected, which ends its run of the queue `run_refused` with the code
    # (`Apiary.Dispatches.RunEnd.refused/1`). The runs before it ended without a result.
    defp refused(scope, code, attempt \\ 1) do
      place = handover_place_fixture(scope)
      work_item = work_item_fixture(scope)

      if attempt == 1 do
        {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, work_item.take_in) end)
      else
        for _earlier <- 1..(attempt - 1), do: explore_run_fixture(work_item)

        {:ok, _queued} =
          Repo.transact(fn -> Dispatches.queue_next(work_item, work_item.take_in) end)
      end

      %{registered: run} = dispatched!(place.key)
      event_fixture(run, 1, "run.refused", %{"code" => code, "names" => ["MODEL_KEY"]})
      {:ok, run} = Projector.project(run)

      {work_item, run}
    end

    test "for want of a model key: each tab puts the fix first, none says it ended with an error",
         %{conn: conn, scope: scope} do
      {work_item, _run} = refused(scope, "model_key_missing")

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-step-line",
               @key_fix <> " The gateway had no model key for attempt 1."
             )

      refute html =~ "ended with an error"

      {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-none-h", "The run did not start.")

      assert has_element?(
               view,
               "#work-item-explore-none p",
               @key_fix <> " The gateway had no model key for the run."
             )

      refute html =~ "ended with an error"

      {:ok, _view, html} = live(conn, page(scope, work_item.number, "/thread"))
      assert html =~ @key_fix <> " The gateway had no model key for attempt"
      refute html =~ "ended with an error"
    end

    test "at attempt 3 of 3: the step card puts the fix first and keeps that no run is left",
         %{conn: conn, scope: scope} do
      {work_item, _run} = refused(scope, "model_key_missing", 3)

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-step-line",
               @key_fix <>
                 " The gateway had no model key for attempt 3. That was attempt 3 of 3, the last attempt of this take in."
             )

      refute html =~ "ended without a result. That was run"

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(
               view,
               "#work-item-explore-none p",
               @key_fix <> " The gateway had no model key for the run."
             )

      {:ok, _view, html} = live(conn, page(scope, work_item.number, "/thread"))
      assert html =~ @key_fix <> " The gateway had no model key for attempt"
    end

    test "with another code, every tab keeps the words for an error",
         %{conn: conn, scope: scope} do
      {work_item, _run} = refused(scope, "image_user_root")

      {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-none-h", "The run ended with an error.")
      refute html =~ "model key"

      {:ok, _view, html} = live(conn, page(scope, work_item.number, "/thread"))
      assert html =~ "ended with an error, so Explore has no result"
      refute html =~ "model key"
    end
  end

  describe "live" do
    test "a change to the work item is drawn; one to another is not read", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)
      other = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-ended")

      # Closed in the database without a word to the page: only a message that names it
      # makes the page read it again.
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now(), closed_by_id: scope.user.id]
      )

      send(view.pid, {:work_items_changed, [other.public_id]})
      refute has_element?(view, "#work-item-ended")

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert has_element?(view, "#work-item-ended")
    end

    test "a work item moved to another workspace is not found here", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      other = workspace_fixture(scope.organisation, "Second")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert_redirect(view, page(scope, work_item.number))
    end

    test "a member removed behind the page's back is sent away on a message of the work item",
         %{scope: scope} do
      work_item = queued(scope)
      member = member_fixture(scope, :member)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), page(scope, work_item.number))

      # Removed without a word to the page: the scope is read again before the work item.
      Repo.delete!(member.membership)

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert_redirect(view, ~p"/")
    end

    test "a member removed behind the page's back is sent away after a refused action",
         %{scope: scope} do
      work_item = queued(scope)
      member = member_fixture(scope, :member)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), page(scope, work_item.number))

      Repo.delete!(member.membership)

      render_hook(view, "close", %{"number" => "#{work_item.number}"})
      assert_redirect(view, ~p"/")
      assert state(work_item) == :exploring
    end
  end

  describe "people" do
    defp thread_path(scope, work_item), do: page(scope, work_item.number, "/thread")

    defp author(view, comment) do
      view
      |> element("#work-item-thread-#{comment.public_id}")
      |> render()
    end

    test "a comment's author is their first letter, the address its hint", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)
      member = member_fixture(scope, :member)
      {:ok, comment} = WorkItems.comment(member.scope, work_item, "Seen on staging")

      {:ok, view, _html} = live(conn, thread_path(scope, work_item))
      letter = String.upcase(String.first(member.user.email))
      dom = "#work-item-thread-#{comment.public_id}"

      assert has_element?(view, ~s{#{dom} > abbr[data-tip="#{member.user.email}"][tabindex="0"]})
      assert has_element?(view, "#{dom} > abbr > span[aria-hidden=true]", letter)
      assert has_element?(view, "#{dom} > abbr > .sr-only", member.user.email)
      refute has_element?(view, "#{dom} .q-wi-box-h b")
    end

    defp owner(view), do: view |> element("#work-item-details-owner") |> render()

    test "a person removed from the organisation is named by their account", %{
      conn: conn,
      scope: scope
    } do
      member = member_fixture(scope, :member)
      work_item = work_item_fixture(scope, owner_id: member.user.id)
      explore_run_fixture(work_item, state: :waiting)
      {:ok, comment} = WorkItems.comment(member.scope, work_item, "Seen on staging")
      Repo.delete!(member.membership)

      {:ok, view, _html} = live(conn, thread_path(scope, work_item))
      short = Apiary.Accounts.User.short_name(member.user.email)
      line = author(view, comment)
      assert line =~ short
      refute line =~ "Former member"
      assert owner(view) =~ short
      refute owner(view) =~ "Former member"
    end

    test "a deleted account is a former member", %{conn: conn, scope: scope} do
      member = member_fixture(scope, :member)
      work_item = work_item_fixture(scope, owner_id: member.user.id)
      explore_run_fixture(work_item, state: :waiting)
      {:ok, comment} = WorkItems.comment(member.scope, work_item, "Seen on staging")
      {:ok, _deleted} = Apiary.Accounts.delete_user(member.user)

      {:ok, view, _html} = live(conn, thread_path(scope, work_item))
      short = Apiary.Accounts.User.short_name(member.user.email)
      line = author(view, comment)
      assert line =~ "Former member"
      refute line =~ short
      assert owner(view) =~ "Former member"
      refute owner(view) =~ short
    end

    test "a person who is not a member of the organisation is named by their account", %{
      conn: conn,
      scope: scope
    } do
      user = Apiary.AccountsFixtures.user_fixture()
      work_item = work_item_fixture(scope, owner_id: user.id)
      explore_run_fixture(work_item, state: :waiting)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert owner(view) =~ Apiary.Accounts.User.short_name(user.email)
      refute owner(view) =~ "Former member"
    end
  end

  describe "a run's link, after the work item moved" do
    setup %{scope: scope} do
      :ok = Edition.put_test_stub(EditionStubs.MembersReachNamed)
      owner = scope
      here = owner.workspace
      there = workspace_fixture(owner.organisation, "There")
      {work_item, run} = asked(owner)

      {:ok, _} =
        WorkItems.answer(owner, work_item, 1, [
          %{"id" => "q1", "note" => "At checkout."},
          %{"id" => "q2", "note" => "Spring."}
        ])

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: there.id]
      )

      %{user: member} = member_fixture(owner, :member)
      %{here: here, there: there, work_item: work_item, run: run, member: member}
    end

    test "to the run's page where the reader reads the workspace it ran in", ctx do
      EditionStubs.MembersReachNamed.put([ctx.here.id, ctx.there.id])
      conn = log_in_user(ctx.conn, ctx.member)
      org = ctx.scope.organisation

      {:ok, view, html} =
        live(conn, ~p"/#{org}/#{ctx.there}/work/#{ctx.work_item.number}/explore")

      href = ~p"/#{org}/#{ctx.here}/runs/#{ctx.run.number}"
      assert has_element?(view, ~s(a[href="#{href}"]))
      assert html =~ "At checkout."
    end

    test "its attempt alone where the reader reads only the workspace it is in now", ctx do
      EditionStubs.MembersReachNamed.put([ctx.there.id])
      conn = log_in_user(ctx.conn, ctx.member)
      org = ctx.scope.organisation

      {:ok, view, html} =
        live(conn, ~p"/#{org}/#{ctx.there}/work/#{ctx.work_item.number}/explore")

      refute has_element?(view, ~s(a[href*="/runs/"]))
      assert has_element?(view, "#work-item-explore-run", "Attempt 2")
      refute html =~ "Run #{ctx.run.number}"
      assert html =~ "At checkout."

      {:ok, thread, _html} =
        live(conn, ~p"/#{org}/#{ctx.there}/work/#{ctx.work_item.number}/thread")

      refute has_element?(thread, ~s(a[href*="/runs/"]))
      assert render(thread) =~ "Explore started in attempt 1"
      refute render(thread) =~ "Run #{ctx.run.number}"
      assert render(thread) =~ "At checkout."
    end
  end

  describe "a close by the instance" do
    defp instance_close!(work_item, reason) do
      {:ok, _queues} =
        Repo.transact(fn ->
          locked = Repo.one!(from w in WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE")
          WorkItems.close_locked([locked], {:instance, reason}, DateTime.utc_now())
        end)
    end

    test "when its integration was removed, every tab says so", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      instance_close!(work_item, "adapter_removed")

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      assert html =~ "when its integration was removed."
      assert has_element?(view, "#work-item-details-ended")

      {:ok, _view, thread} = live(conn, page(scope, work_item.number, "/thread"))
      assert thread =~ "Closed when its integration was removed"
    end

    test "for a reason without words, nothing names who closed it, and nothing fails", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)
      instance_close!(work_item, "another_reason")

      for tail <- ["", "/explore", "/thread"] do
        {:ok, _view, html} = live(conn, page(scope, work_item.number, tail))
        refute html =~ "integration was removed"
        refute html =~ "another_reason"
      end
    end
  end
end
