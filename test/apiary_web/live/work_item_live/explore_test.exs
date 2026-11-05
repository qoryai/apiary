defmodule ApiaryWeb.WorkItemLive.ExploreTest do
  # Explore's tab of a work item's page (`ApiaryWeb.WorkItemLive.Show`) in each state, on
  # data the moves and the runs write: the questions with the answer form, a partial send
  # with the next run queued, the gate without and with open review comments, the
  # proposal confirmed, what a running run hides, and a run that failed after it wrote a
  # proposal. The answer form's draft as the answers `Apiary.WorkItems.answer/4` takes
  # (`answer_list/2`).
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias ApiaryWeb.WorkItemLive.Show

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp explore(scope, number),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore"

  defp runs(work_item),
    do: Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

  @proposal """
  ## Facts

  The invoice PDF shows the shop's currency, not the order's.

  ## Proposed solution

  Read the currency from the order.
  """

  @questions [
    %{
      "question" => "Which currency should the invoice PDF show?",
      "options" => [
        %{"title" => "The order's currency", "explanation" => "What the customer paid."},
        %{"title" => "The shop's currency", "explanation" => "What the books keep."}
      ]
    },
    "Should the credit note PDF change too?"
  ]

  # Run 1 proposes; run 2 writes two questions, so the proposal waits and the questions
  # are open.
  defp asked_after_proposal(scope) do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
    explore_run_fixture(work_item, result: questions_result(@questions))
    work_item
  end

  describe "the questions" do
    test "with the form: the line, each open question, its options, Give your own option, Run with answers",
         %{conn: conn, scope: scope} do
      work_item = asked_after_proposal(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-h", "Questions")

      assert has_element?(
               view,
               "#{q}-cap",
               "Run with answers starts the next run. That run reads your answers and updates the proposal."
             )

      assert has_element?(view, "#{q} h3", "Open questions")
      assert has_element?(view, "#{q}-q-1 b", "Which currency should the invoice PDF show?")
      assert has_element?(view, "#{q}-answer-1-1[value='1']")
      assert has_element?(view, "#{q}-answer-1-2[value='2']")

      assert has_element?(
               view,
               "label[for=work-item-explore-questions-answer-1-own]",
               "Give your own option"
             )

      refute has_element?(view, "#{q}-answer-2-own")
      assert has_element?(view, "#{q}-go", "Run with answers")

      # The proposal stays above, with Add review comment while the questions are open.
      assert has_element?(view, "#work-item-explore-proposal-h", "Proposal")
      assert has_element?(view, "#work-item-explore-proposal .q-xp-cap", "Version 1")
      assert has_element?(view, "#work-item-explore-proposal-review-add", "Add review comment")
      refute has_element?(view, "#work-item-explore-gate")
      refute has_element?(view, "#work-item-explore-run")
      refute render(view) =~ "Qory&#39;s"

      # Run 1 wrote version 1, the newest: its fold in the runs fold shows that proposal.
      run_1 =
        Repo.one(
          from r in Apiary.Runs.Run,
            join: d in DispatchRun,
            on: r.dispatch_run_id == d.id,
            where: d.work_item_id == ^work_item.id and d.attempt == 1,
            select: r.number
        )

      assert has_element?(
               view,
               "#work-item-record-#{run_1}",
               "Read the currency from the order."
             )
    end

    test "a partial send: the answered question folds to one line, the other stays open as text while the run is queued",
         %{conn: conn, scope: scope} do
      work_item = asked_after_proposal(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"option" => "1", "note" => "Only for orders paid by card."}}
      })

      assert runs(work_item) == 3

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-closed #{q}-question-1 summary", "The order's currency")
      assert has_element?(view, "#{q}-question-1-answer", "Only for orders paid by card.")
      assert has_element?(view, "#{q}-question-1-answer-who", "You answered")

      # While the next run is queued: the open question as text, with no form.
      assert has_element?(view, "#{q}-question-2", "Should the credit note PDF change too?")
      refute has_element?(view, "#{q}-form")
      refute has_element?(view, "#{q}-cap")
      refute has_element?(view, "#{q} textarea")
      refute has_element?(view, "#{q} input[type=radio]")

      # The wait line shows the attempt, and nothing else starts a run.
      assert has_element?(view, "#work-item-explore-run", "Attempt 3")

      assert has_element?(
               view,
               "#work-item-explore-wait-h",
               "Explore is queued again, with your answers."
             )

      refute has_element?(view, "#work-item-explore-proposal-review-add")
      refute has_element?(view, "#work-item-explore-gate")

      render_hook(view, "answer", %{
        "number" => "#{work_item.number}",
        "answers" => %{"q2" => %{"note" => "Yes."}}
      })

      assert runs(work_item) == 3
    end

    test "Run with answers sends the open review comments with the answers, in one run", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Name the currency field.")
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert has_element?(view, "#work-item-review-c1 .badge", "Open")

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q2" => %{"note" => "Yes, both use one template."}}
      })

      assert runs(work_item) == 3

      # The run input has no review comments (`Apiary.Dispatches.Inputs`): the queued run
      # reads the open ones of the newest review comments, and c1 is open there.
      assert [%{attempt: 3, state: :waiting}] =
               Repo.all(
                 from d in DispatchRun,
                   where: d.work_item_id == ^work_item.id and d.attempt == 3,
                   select: %{attempt: d.attempt, state: d.state}
               )

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)

      assert [%{"id" => "c1", "text" => "Name the currency field.", "state" => "open"}] =
               Apiary.Explore.ReviewComments.entries(document)

      assert has_element?(
               view,
               "#work-item-review-c1-reading",
               "Attempt 3 reads this review comment."
             )

      refute has_element?(view, "#work-item-review-c1-reply")
    end

    test "Run with answers with every answer blank sends the open review comments, and the questions stay open",
         %{conn: conn, scope: scope} do
      work_item = asked_after_proposal(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Name the currency field.")
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => " "}, "q2" => %{"note" => ""}}
      })

      assert [%{attempt: 3, state: :waiting}] =
               Repo.all(
                 from d in DispatchRun,
                   where: d.work_item_id == ^work_item.id and d.attempt == 3,
                   select: %{attempt: d.attempt, state: d.state}
               )

      {_version, document} = Apiary.Explore.Questions.newest(work_item)
      assert Enum.map(document["questions"], & &1["state"]) == ["open", "open"]
      refute Enum.any?(document["questions"], &Map.has_key?(&1, "answer"))
      refute has_element?(view, "#work-item-explore-questions-error")
      refute render(view) =~ "Choose an option or write an answer."

      assert has_element?(
               view,
               "#work-item-review-c1-reading",
               "Attempt 3 reads this review comment."
             )
    end

    test "Run with answers with every answer blank and no open review comment: the error, and no run",
         %{conn: conn, scope: scope} do
      work_item = asked_after_proposal(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      assert has_element?(
               view,
               "#work-item-explore-questions-error",
               "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
             )

      assert runs(work_item) == 2
    end

    test "the blank-answer error is gone after Add review comment and back to the tab",
         %{conn: conn, scope: scope} do
      work_item = asked_after_proposal(scope)
      path = explore(scope, work_item.number)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      assert has_element?(view, "#work-item-explore-questions-error")

      render_patch(view, path <> "?review=new")
      assert has_element?(view, "#work-item-review-page-form")
      render_patch(view, path)

      assert has_element?(view, "#work-item-explore-questions-form")
      refute has_element?(view, "#work-item-explore-questions-error")
      refute render(view) =~ "Choose an option or write an answer."
    end

    test "questions that changed after the page showed them: no answer sent, the form shows that and the draft stays",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      %{dispatch_run: asking} =
        explore_run_fixture(work_item, result: questions_result(@questions))

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      shown = :sys.get_state(view.pid).socket.assigns.questions

      # Run 2 withdraws the first question. The click comes before the page reads the
      # questions again, so the page still has the questions it showed.
      withdraw!(asking, work_item, "q1")
      render(view)
      :sys.replace_state(view.pid, &put_in(&1.socket.assigns.questions, shown))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{
          "q1" => %{"option" => "1"},
          "q2" => %{"note" => "Yes, both use one template."}
        }
      })

      q = "#work-item-explore-questions"

      assert has_element?(
               view,
               "#{q}-error",
               "Check the questions and your answers, then click Run with answers again. The questions changed after the page showed them, so no answer was sent."
             )

      # The questions read again: the first is withdrawn, the second open with the draft.
      refute has_element?(view, "#{q}-answer-1")
      assert has_element?(view, "#{q}-answer-2", "Yes, both use one template.")

      # No answer written, and no run queued.
      assert runs(work_item) == 2
      {_version, document} = Apiary.Explore.Questions.newest(work_item)
      assert Enum.map(document["questions"], & &1["state"]) == ["withdrawn", "open"]
      refute Enum.any?(document["questions"], &Map.has_key?(&1, "answer"))
    end

    test "the line of questions that changed stays after a read that leaves the questions as they are",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      %{dispatch_run: asking} =
        explore_run_fixture(work_item, result: questions_result(@questions))

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      shown = :sys.get_state(view.pid).socket.assigns.questions

      # Another member's move withdraws the first question; the click comes before the
      # page reads the questions again, as in the case above.
      withdraw!(asking, work_item, "q1")
      render(view)
      :sys.replace_state(view.pid, &put_in(&1.socket.assigns.questions, shown))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{
          "q1" => %{"option" => "1"},
          "q2" => %{"note" => "Yes, both use one template."}
        }
      })

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-error", "The questions changed after the page showed them")

      # That move's message arrives after the refusal: the page reads the same questions.
      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert has_element?(view, "#{q}-error", "The questions changed after the page showed them")
      assert has_element?(view, "#{q}-answer-2", "Yes, both use one template.")
    end

    test "an answer's field error stays after a Thread comment", %{conn: conn, scope: scope} do
      work_item = asked_after_proposal(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      field = "#work-item-explore-questions-answer-1"

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"option" => "own", "note" => " "}}
      })

      assert has_element?(view, "#{field}-error", "Write your option, or pick one above.")

      {:ok, _comment} =
        WorkItems.comment(scope, Repo.get!(WorkItems.WorkItem, work_item.id), "Seen on staging")

      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert has_element?(view, "#{field}-error", "Write your option, or pick one above.")
      assert has_element?(view, "#{field}-own[checked]")
    end
  end

  describe "a question with one option, or none" do
    @form "#work-item-explore-questions-form"
    @one_option %{
      "question" => "Which refund?",
      "options" => [%{"title" => "Card", "explanation" => "Back to the card."}]
    }

    defp asked(scope, question) do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      explore_run_fixture(work_item, result: questions_result([question]))
      work_item
    end

    defp sent(view, work_item, answer) do
      view
      |> element(@form)
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{"q1" => answer}})

      {_version, %{"questions" => [question]}} =
        Apiary.Explore.Questions.newest(Repo.get!(WorkItems.WorkItem, work_item.id))

      question
    end

    test "no options: the field alone, and a written answer closes the question", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked(scope, "Which refund?")
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      field = "#work-item-explore-questions-answer-1"

      refute has_element?(view, "#{field}-options")
      refute has_element?(view, "#{field}-own")
      assert has_element?(view, "textarea#{field}[placeholder='Give your own option']")

      assert %{"state" => "answered", "answer" => %{"note" => "Card only."} = answer} =
               sent(view, work_item, %{"note" => "Card only."})

      assert answer["option"] == nil
    end

    test "one option, picked: the question closes with that option", %{conn: conn, scope: scope} do
      work_item = asked(scope, @one_option)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert %{"state" => "answered", "answer" => %{"option" => "Card"}} =
               sent(view, work_item, %{"option" => "1"})
    end

    test "one option, Give your own option: the question closes with the written answer", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked(scope, @one_option)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert %{"state" => "open"} = sent(view, work_item, %{"option" => "own", "note" => " "})

      assert %{"state" => "answered", "answer" => %{"note" => "A credit note."} = answer} =
               sent(view, work_item, %{"option" => "own", "note" => "A credit note."})

      assert answer["option"] == nil
    end

    test "the recommended option: the mark in the form; a closed answer has it on that option alone",
         %{conn: conn, scope: scope} do
      question = %{
        "question" => "Which refund?",
        "options" => [
          %{"title" => "Card", "explanation" => "Back to the card.", "recommended" => true},
          %{"title" => "Credit", "explanation" => "A credit note."}
        ]
      }

      q = "#work-item-explore-questions-question-1"
      a = "#work-item-explore-questions-answer-1"

      for {answer, mark?} <- [
            {%{"option" => "1"}, true},
            {%{"option" => "2"}, false},
            {%{"option" => "own", "note" => "Neither."}, false}
          ] do
        work_item = asked(scope, question)
        {:ok, view, _html} = live(conn, explore(scope, work_item.number))

        assert has_element?(
                 view,
                 "#{a}-options label[for$='-1'] .badge",
                 "Recommended by the agent"
               )

        refute has_element?(view, "#{a}-options label[for$='-2'] .badge")
        refute has_element?(view, "#{a}-1[checked]")

        sent(view, work_item, answer)
        assert has_element?(view, "#{q}-answer .badge", "Recommended by the agent") == mark?
      end
    end

    test "one recommended option goes both ways, and is not answered until it is sent",
         %{conn: conn, scope: scope} do
      question = %{
        "question" => "Which refund?",
        "options" => [%{"title" => "Card", "explanation" => "Back.", "recommended" => true}]
      }

      for {answer, option} <- [
            {%{"option" => "1"}, "Card"},
            {%{"option" => "own", "note" => "A credit note."}, nil}
          ] do
        work_item = asked(scope, question)
        {:ok, view, _html} = live(conn, explore(scope, work_item.number))

        assert has_element?(view, "#work-item-explore-questions-answer-1-options")
        assert %{"state" => "answered", "answer" => stored} = sent(view, work_item, answer)
        assert stored["option"] == option
      end
    end
  end

  describe "a question reopened twice" do
    test "counts once, in the fold of the runs, on the line of each run that wrote or reopened it: Wrote 1 question",
         %{conn: conn, scope: scope} do
      [currency, _credit_note] = @questions
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: questions_result([currency]))
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The order's."})

      # Run 2, queued by the answer, reopens q1, which is answered at it; run 3, queued
      # by that answer, reopens q1 again.
      reopen_at_end!(work_item, "q1")
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The shop's."})
      reopen_at_end!(work_item, "q1")

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      numbers =
        Repo.all(
          from r in Apiary.Runs.Run,
            join: d in DispatchRun,
            on: r.dispatch_run_id == d.id,
            where: d.work_item_id == ^work_item.id,
            order_by: d.attempt,
            select: r.number
        )

      assert length(numbers) == 3

      for number <- numbers do
        assert has_element?(view, "#work-item-record-#{number}", "Wrote 1 question")
      end
    end
  end

  describe "the questions after Take in again" do
    test "the frame and the form show the questions of the current take in; the earlier take in's fold shows its question",
         %{conn: conn, scope: scope} do
      work_item = asked_in_two_take_ins(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-form")
      assert has_element?(view, "#{q}-question-2", "Should the credit note PDF change too?")
      assert has_element?(view, "#{q}-form [name^='answers[q2]']")
      refute has_element?(view, "#{q}-question-1")
      refute has_element?(view, "#{q}-form [name^='answers[q1]']")
      refute has_element?(view, q, "Which currency should the invoice PDF show?")

      assert has_element?(
               view,
               "#work-item-explore-take-ins-1",
               "Which currency should the invoice PDF show?"
             )

      refute has_element?(
               view,
               "#work-item-explore-take-ins-1",
               "Should the credit note PDF change too?"
             )
    end

    test "an answer by an option's place, from the form, reaches take in 2's question, not take in 1's open one",
         %{conn: conn, scope: scope} do
      work_item =
        asked_in_two_take_ins(scope, %{
          "question" => "Should the credit note PDF change too?",
          "options" => [
            %{"title" => "Yes", "explanation" => "One template for both."},
            %{"title" => "No", "explanation" => "The credit note stays as it is."}
          ]
        })

      runs = runs(work_item)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-answer-2-2[value='2']")
      refute has_element?(view, "#{q}-form [name^='answers[q1]']")

      view
      |> element("#{q}-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q2" => %{"option" => "2"}}
      })

      # The stored questions: q2 answered with its second option; q1 open, with no answer.
      {_version, document} = Apiary.Explore.Questions.newest(work_item)

      assert [
               %{"id" => "q1", "state" => "open"} = q1,
               %{"id" => "q2", "state" => "answered", "answer" => %{"option" => "No"}}
             ] = document["questions"]

      refute Map.has_key?(q1, "answer")

      # The next run of take in 2 is queued.
      assert runs(work_item) == runs + 1

      assert [%{take_in: 2, state: :waiting}] =
               Repo.all(
                 from d in DispatchRun,
                   where: d.work_item_id == ^work_item.id and d.state == :waiting,
                   select: %{take_in: d.take_in, state: d.state}
               )
    end

    test "a question answered in take in 1 that take in 2's run reopened: the frame and the form show it; take in 1's fold too",
         %{conn: conn, scope: scope} do
      work_item = reopened_in_take_in_2(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-form")
      assert has_element?(view, "#{q}-question-1", "Which currency should the invoice PDF show?")
      assert has_element?(view, "#{q}-form [name^='answers[q1]']")
      refute has_element?(view, "#{q}-question-2")
      refute has_element?(view, "#{q}-form [name^='answers[q2]']")

      assert has_element?(
               view,
               "#work-item-explore-take-ins-1",
               "Which currency should the invoice PDF show?"
             )
    end

    test "a question take in 2's run reopened and nobody answered after: the run's line counts it, and take in 3's page shows it in take in 2's fold",
         %{conn: conn, scope: scope} do
      work_item = reopened_in_take_in_2(scope)

      # On take in 2's page, the line of the run in the fold of the runs.
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      assert has_element?(view, "#work-item-record", "Wrote 1 question")

      {:ok, _closed} = WorkItems.close(scope, Repo.get!(WorkItems.WorkItem, work_item.id))
      ticket = Repo.get!(Apiary.Sources.Item, work_item.item_id)
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)
      assert again.take_in == 3

      {:ok, view, _html} = live(conn, explore(scope, again.number))

      fold = "#work-item-explore-take-ins-2"

      assert has_element?(
               view,
               "#{fold} [id$='-body'] li",
               "Which currency should the invoice PDF show?"
             )
    end

    test "Run with answers with every answer blank while take in 1's review comment is open: the error, and no run",
         %{conn: conn, scope: scope} do
      [_currency, credit_note] = @questions
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the currency field.")
      {:ok, _closed} = WorkItems.close(scope, Repo.get!(WorkItems.WorkItem, work_item.id))

      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

      Repo.delete_all(
        from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2
      )

      explore_run_fixture(again, take_in: 2, result: questions_result([credit_note]))
      runs = runs(again)

      {:ok, view, _html} = live(conn, explore(scope, again.number))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{again.number}", "answers" => %{"q1" => %{"note" => ""}}})

      assert has_element?(
               view,
               "#work-item-explore-questions-error",
               "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
             )

      assert runs(again) == runs

      assert [%{"id" => "c1", "state" => "open"}] =
               again
               |> Apiary.Explore.ReviewComments.newest()
               |> elem(1)
               |> Apiary.Explore.ReviewComments.entries()
    end

    test "the open questions WorkItems.explore/2 returns are those Questions.open_in_take_in/2 returns",
         %{scope: scope} do
      work_item = reopened_in_take_in_2(scope)
      {_version, document} = Apiary.Explore.Questions.newest(work_item)
      runs = Apiary.Explore.Questions.take_in_runs(work_item.id, 2)
      core = Apiary.Explore.Questions.open_in_take_in(document, runs)
      assert Enum.map(core, & &1["id"]) == ["q1"]

      explore = WorkItems.explore(scope, Repo.get!(WorkItems.WorkItem, work_item.id))

      assert for(%{state: :open, id: id} <- explore.questions, do: id) ==
               Enum.map(core, & &1["id"])

      assert Enum.map(explore.run.questions, & &1.text) == Enum.map(core, & &1["question"])
    end
  end

  # A work item whose take in 1 wrote questions q1 and q2, a member answered q1 only, and
  # the take in was closed; take in 2's run reopened q1, so q1 and q2 are both open, and
  # only q1 is the current take in's.
  defp reopened_in_take_in_2(scope) do
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
    explore_run_fixture(work_item, result: questions_result(@questions))
    {:ok, _} = WorkItems.answer(scope, work_item, 1, [%{"id" => "q1", "note" => "The order's."}])
    {:ok, _closed} = WorkItems.close(scope, Repo.get!(WorkItems.WorkItem, work_item.id))

    {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2)

    %{dispatch_run: reopening, run: run} =
      explore_run_fixture(again, take_in: 2, settle: false)

    {_version, document} = Apiary.Explore.Questions.newest(again)
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    questions =
      Enum.map(document["questions"], fn
        %{"id" => "q1", "answer" => answer} = question ->
          question
          |> Map.delete("answer")
          |> Map.put("state", "open")
          |> Map.put("history", [
            Map.put(answer, "reopened", %{"run" => run.number, "at" => at})
          ])

        question ->
          question
      end)

    {:ok, _version} =
      while_live(reopening, fn ->
        Apiary.Artifacts.push(
          {:run, reopening},
          Repo.get!(Apiary.WorkItems.WorkItem, again.id),
          "questions",
          [Apiary.Explore.Questions.file(%{"questions" => questions})],
          name: "main",
          stage_id: reopening.stage_id
        )
      end)

    {:ok, _told} =
      Repo.transact(fn ->
        {:ok, Apiary.Dispatches.Settle.settle_locked(Repo.get!(DispatchRun, reopening.id))}
      end)

    {_version, document} = Apiary.Explore.Questions.newest(again)

    assert Enum.map(document["questions"], &{&1["id"], &1["state"]}) == [
             {"q1", "open"},
             {"q2", "open"}
           ]

    again
  end

  # A work item whose take in 1 wrote question q1, left open, and was closed; take in 2,
  # taken in again, wrote question q2 (`second`, else the credit note question), so q1
  # and q2 are both open in its questions.
  defp asked_in_two_take_ins(scope, second \\ nil) do
    [currency, credit_note] = @questions
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
    explore_run_fixture(work_item, result: questions_result([currency]))
    {:ok, _closed} = WorkItems.close(scope, work_item)

    {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2)

    explore_run_fixture(again, take_in: 2, result: questions_result([second || credit_note]))

    {_version, document} = Apiary.Explore.Questions.newest(again)

    assert Enum.map(document["questions"], &{&1["id"], &1["state"]}) == [
             {"q1", "open"},
             {"q2", "open"}
           ]

    again
  end

  # Ends the newest run of `work_item` by its exit, after it pushed a new version of the
  # questions with the answered question `id` reopened by it: its answer moved to the
  # end of its history.
  defp reopen_at_end!(work_item, id) do
    Apiary.StagesFixtures.end_run!(
      Repo.get!(WorkItems.WorkItem, work_item.id),
      fn dispatch_run, run ->
        {_version, document} = Apiary.Explore.Questions.newest(work_item)
        at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        questions =
          Enum.map(document["questions"], fn
            %{"id" => ^id, "answer" => answer} = question ->
              reopened = Map.put(answer, "reopened", %{"run" => run.number, "at" => at})

              question
              |> Map.delete("answer")
              |> Map.put("state", "open")
              |> Map.put("history", (question["history"] || []) ++ [reopened])

            question ->
              question
          end)

        {:ok, _version} =
          Apiary.Artifacts.push(
            {:run, dispatch_run},
            Repo.get!(WorkItems.WorkItem, work_item.id),
            "questions",
            [Apiary.Explore.Questions.file(%{"questions" => questions})],
            name: "main",
            stage_id: dispatch_run.stage_id
          )
      end
    )
  end

  # A new version of the questions, pushed as the run of the queue `dispatch_run`, with
  # the question `id` withdrawn.
  defp withdraw!(dispatch_run, work_item, id) do
    {_version, document} = Apiary.Explore.Questions.newest(work_item)

    questions =
      Enum.map(document["questions"], fn
        %{"id" => ^id} = question -> Map.put(question, "state", "withdrawn")
        question -> question
      end)

    {:ok, _version} =
      while_live(dispatch_run, fn ->
        Apiary.Artifacts.push(
          {:run, dispatch_run},
          Repo.get!(Apiary.WorkItems.WorkItem, work_item.id),
          "questions",
          [Apiary.Explore.Questions.file(%{"questions" => questions})],
          name: "main",
          stage_id: dispatch_run.stage_id
        )
      end)
  end

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

  describe "the gate and the proposal" do
    test "without open review comments: Confirm alone; with them, Send review comments first", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      gate = "#work-item-explore-gate"
      assert has_element?(view, "#{gate}-go.btn-primary", "Confirm")
      refute has_element?(view, "#{gate}-send")
      refute has_element?(view, "#work-item-review")
      refute render(view) =~ "Send review comments starts"

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the currency field.")
      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert has_element?(view, "#{gate}-send.btn-primary", "Send review comments")
      refute has_element?(view, "#{gate}-go.btn-primary")
      assert has_element?(view, "#{gate}-go", "Confirm")
      assert has_element?(view, "#{gate}-unread", "Confirm leaves 1 review comment unread.")
      assert has_element?(view, "#work-item-review h2", "Review comments")
      assert has_element?(view, "#work-item-review-c1-reply", "Reply")
    end

    test "the proposal's Mermaid block is inside the diagram hook's element of its version",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      diagram = "## Flow\n\n```mermaid\nflowchart LR\n  Cart --> Invoice\n```\n"
      explore_run_fixture(work_item, result: understood_result(%{"message" => diagram}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert has_element?(
               view,
               ~s(#work-item-explore-proposal-v1[phx-hook="Mermaid"] pre.q-mermaid-source code),
               "Cart --> Invoice"
             )
    end

    defp confirmations(work_item),
      do:
        Repo.aggregate(
          from(c in Apiary.WorkItems.Confirmation, where: c.work_item_id == ^work_item.id),
          :count
        )

    test "Confirm after the gate changed: nothing confirmed, and the page read again", %{
      conn: conn,
      scope: scope
    } do
      [currency | _] = @questions
      gate = "#work-item-explore-gate"

      # Attempt 2 wrote a question after the page showed attempt 1's gate (`:stale`).
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      explore_run_fixture(work_item, result: questions_result([currency]))

      view |> element("#{gate}-go", "Confirm") |> render_click()
      refute has_element?(view, gate)
      assert has_element?(view, "#work-item-explore-questions-form")

      assert confirmations(work_item) == 0

      # A confirmation saved after the page showed the gate, with no message to the page
      # (`:not_waiting`).
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      Repo.insert!(%Apiary.WorkItems.Confirmation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        take_in: work_item.take_in,
        attempt: 1,
        result: %{"proposal_version" => 1},
        confirmed_by_id: scope.user.id,
        confirmed_at: DateTime.utc_now()
      })

      assert {:error, :not_waiting} = WorkItems.confirm(scope, work_item, 1)
      view |> element("#{gate}-go", "Confirm") |> render_click()
      refute has_element?(view, gate)
      assert has_element?(view, "#work-item-explore-proposal .badge", "Confirmed")
      assert confirmations(work_item) == 1
    end

    test "confirmed: the proposal with Confirmed and who confirmed it, and no gate", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, _} = WorkItems.confirm(scope, work_item, 1)

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      p = "#work-item-explore-proposal"
      assert has_element?(view, "#{p} .badge", "Confirmed")
      assert has_element?(view, "#{p} .q-xp-cap", "Version 1. You confirmed it")
      assert has_element?(view, "#{p}-text h4", "Proposed solution")
      refute has_element?(view, "#work-item-explore-gate")
      refute has_element?(view, "#{p}-review-add")
      refute has_element?(view, "#work-item-explore-questions-form")
    end

    test "the fold of the runs: how many, the proposal's and the questions' versions", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      summary = "#work-item-record-fold > summary"
      assert has_element?(view, summary, "2 runs")
      assert has_element?(view, summary, "proposal v1")
      assert has_element?(view, summary, "questions v1")
      assert has_element?(view, "#work-item-record[aria-labelledby=work-item-record-h]")
      assert has_element?(view, "#work-item-record > h2#work-item-record-h", "Runs and artifacts")
      refute render(view) =~ "Earlier runs of this take in"
    end
  end

  describe "the Thread after a send of the review comments" do
    defp thread(scope, number),
      do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/thread"

    # The run of the queue a move queued as `attempt`, in place of its queued row, ended
    # as `opts` give it (`explore_run_fixture/2`).
    defp ran!(work_item, attempt, opts) do
      Repo.delete_all(
        from d in DispatchRun, where: d.work_item_id == ^work_item.id and d.attempt == ^attempt
      )

      explore_run_fixture(work_item, Keyword.put(opts, :attempt, attempt))
    end

    test "each run a send started reads with the review comments, at the gate and while questions wait",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      # At the gate: run 2, sent with c1.
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the currency field.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
      ran!(work_item, 2, result: questions_result(@questions))

      # While run 2's questions wait: run 3, sent with c2, the questions left open.
      {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Keep the old PDFs.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 2)
      ran!(work_item, 3, [])

      {:ok, view, _html} = live(conn, thread(scope, work_item.number))
      events = "[id^='work-item-thread-ev-']"

      for attempt <- [2, 3] do
        assert has_element?(
                 view,
                 events,
                 "Explore started again, with the review comments, in attempt #{attempt}"
               )
      end

      refute has_element?(view, events, "with the answers")
      refute has_element?(view, events, "Explore started again in attempt")
    end

    test "a run that only replied to a review comment: how many it replied to, counted by its run",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      # Run 2 writes questions and replies to c1.
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the currency field.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)

      %{dispatch_run: second, run: second_run} =
        ran!(work_item, 2, result: questions_result(@questions))

      while_live(second, fn -> reply_as_run!(second, second_run, "asked", "q1") end)

      # Run 3 declines c2 and writes no proposal and no question; run 2's stay open.
      {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Keep the old PDFs.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 2)
      %{dispatch_run: third, run: third_run} = ran!(work_item, 3, [])

      while_live(third, fn -> reply_as_run!(third, third_run, "declined") end)

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)

      assert [[%{"by" => %{"run" => n2}}], [%{"by" => %{"run" => n3}}]] =
               Enum.map(document["review_comments"], & &1["replies"])

      assert {n2, n3} == {second_run.number, third_run.number}

      {:ok, view, _html} = live(conn, thread(scope, work_item.number))
      events = "[id^='work-item-thread-ev-']"

      # The fixture's run took 30 s. The line shows the run's icon, as for a run that wrote
      # questions.
      replied = "Explore wrote a reply to 1 review comment, after 30 s"
      assert has_element?(view, "#{events}:has(.q-wi-ev-ic .q-wi-play)", replied)
      refute has_element?(view, "#{events}:has(.q-wi-ev-bad)", replied)
      refute has_element?(view, events, "Attempt 3 ended without a result")
    end
  end

  describe "a send while the artifact store cannot be reached" do
    @store_error "Try again in a minute. The artifact store cannot be reached."

    # The stored copy of the version's one file moved away, as a store that cannot read
    # it, until the test ends or the function it returns puts it back. The store keeps one
    # copy of each content, so each document here has a unique number, and no other test
    # stores the same content.
    defp unreadable!(version) do
      [file] = version.files
      {:ok, path} = Apiary.Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      back = fn -> File.rename(path <> ".away", path) end
      on_exit(back)
      back
    end

    defp unique(text), do: "#{text} #{System.unique_integer([:positive])}"

    # Run 1 proposes, and c1, with a unique number, is open on it.
    defp commented_unreadable(scope) do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, unique("Name the field."))
      work_item
    end

    defp review_comments_away!(work_item) do
      {version, _document} = Apiary.Explore.ReviewComments.newest(work_item)
      unreadable!(version)
    end

    test "Send review comments at the gate: the line under the gate, and no run", %{
      conn: conn,
      scope: scope
    } do
      work_item = commented_unreadable(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      review_comments_away!(work_item)

      view
      |> element("#work-item-explore-gate")
      |> render_submit(%{"number" => "#{work_item.number}"})

      assert has_element?(view, "#work-item-explore-gate-error", @store_error)
      assert has_element?(view, "#work-item-explore-gate-send", "Send review comments")
      assert runs(work_item) == 1
    end

    test "Run with answers: the line under the form, the draft kept, and no run", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: questions_result([unique("Which currency?")]))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      {version, _document} = Apiary.Explore.Questions.newest(work_item)
      unreadable!(version)

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The order's currency."}}
      })

      assert has_element?(view, "#work-item-explore-questions-error", @store_error)
      assert has_element?(view, "#work-item-explore-questions-answer-1", "The order's currency.")
      assert runs(work_item) == 1
    end

    test "Run with answers with every answer blank and an open review comment: the line under the form",
         %{conn: conn, scope: scope} do
      work_item = commented_unreadable(scope)
      explore_run_fixture(work_item, result: questions_result([unique("Which currency?")]))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      review_comments_away!(work_item)

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      assert has_element?(view, "#work-item-explore-questions-error", @store_error)
      assert runs(work_item) == 2
    end

    test "Add review comment and Reply: the line under the field, with the text kept", %{
      conn: conn,
      scope: scope
    } do
      work_item = commented_unreadable(scope)
      explore = explore(scope, work_item.number)

      for {address, comment} <- [{"?review=new", []}, {"?reply=c1", [{"comment", "c1"}]}] do
        {:ok, view, _html} = live(conn, explore <> address)
        back = review_comments_away!(work_item)

        view
        |> element("#work-item-review-page-form")
        |> render_submit(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        back.()

        assert has_element?(view, "#work-item-review-page-error", @store_error)
        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
      end

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
      # Nothing written: c1 alone, with no reply.
      assert [%{"id" => "c1"} = c1] = document["review_comments"]
      assert (c1["replies"] || []) == []
    end
  end

  describe "a run that starts first" do
    # Run 1 proposes, and c1 is open on it.
    defp commented(scope) do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the currency field.")
      work_item
    end

    # Attempt 2 queued without a message to the page.
    defp queue_attempt_2!(work_item), do: explore_run_fixture(work_item, state: :waiting)

    # The line for a page whose run row is `number`: at_attempt_2 changes only the attempt.
    defp started_as(number),
      do:
        "Send it again when attempt 2 ends. Attempt 2 (Run #{number}) started first, so nothing was sent."

    # The page's latest run set to attempt 2, as a page that read the work item before
    # that run was queued, while its attempt was 2: the send's line shows attempt 2, which
    # is queued.
    defp at_attempt_2(view) do
      :sys.replace_state(
        view.pid,
        &update_in(&1.socket.assigns.item.run, fn run -> %{run | attempt: 2} end)
      )
    end

    test "after a send, a fresh page read: Details has the attempt and the run count of the fold",
         %{conn: conn, scope: scope} do
      work_item = commented(scope)
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert has_element?(view, "#work-item-details-runs", "Attempt 2 · 2 runs, queued")
      assert has_element?(view, "#work-item-record-fold summary b", "2 runs")
      assert has_element?(view, "#work-item-record-fold .q-xp-inner", "Attempt 2")
    end

    # The run these tests start has no run row yet, so the line has no number and no link.
    @started "Send it again when attempt 2 ends. Attempt 2 started first, so nothing was sent."

    test "while Add review comment or Reply is open: the page stays, with the draft and the line",
         %{conn: conn, scope: scope} do
      for {address, comment} <- [{"?review=new", []}, {"?reply=c1", [{"comment", "c1"}]}] do
        work_item = commented(scope)
        {:ok, view, _html} = live(conn, explore(scope, work_item.number) <> address)

        view
        |> element("#work-item-review-page-form")
        |> render_change(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
        send(view.pid, {:work_items_changed, [work_item.public_id]})

        assert has_element?(view, "#work-item-review-page-form")
        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
        assert has_element?(view, "#work-item-review-page-error", @started)
        assert runs(work_item) == 2
      end
    end

    @page_submit ~s(#work-item-review-page-form button[type="submit"])

    test "after a confirm, a close or an undo: the open form page stays, with the draft and its line",
         %{conn: conn, scope: scope} do
      moves = [
        &WorkItems.confirm(&1, &2, 1),
        &WorkItems.close(&1, &2),
        &WorkItems.undo(&1, &2)
      ]

      for move <- moves,
          {address, comment, line} <- [
            {"?review=new", [],
             "Copy your text if you need it. You can no longer send this review comment, because the work item changed."},
            {"?reply=c1", [{"comment", "c1"}],
             "Copy your text if you need it. You can no longer send this reply, because the work item changed."}
          ] do
        work_item = commented(scope)
        {:ok, view, _html} = live(conn, explore(scope, work_item.number) <> address)

        view
        |> element("#work-item-review-page-form")
        |> render_change(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        assert has_element?(view, @page_submit)

        {:ok, _} = move.(scope, work_item)
        send(view.pid, {:work_items_changed, [work_item.public_id]})

        assert has_element?(view, "#work-item-review-page-form")
        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
        assert has_element?(view, "#work-item-review-page-error", line)
        assert has_element?(view, "#work-item-review-page-form a", "Cancel")
        refute has_element?(view, @page_submit)
      end
    end

    test "once the reader can send again: the line goes and the form page's button is back",
         %{conn: conn, scope: scope} do
      for {address, comment, line} <- [
            {"?review=new", [],
             "Copy your text if you need it. You can no longer send this review comment, because the work item changed."},
            {"?reply=c1", [{"comment", "c1"}],
             "Copy your text if you need it. You can no longer send this reply, because the work item changed."}
          ] do
        work_item = commented(scope)
        open = Repo.get!(WorkItems.WorkItem, work_item.id)
        {:ok, view, _html} = live(conn, explore(scope, work_item.number) <> address)

        view
        |> element("#work-item-review-page-form")
        |> render_change(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        {:ok, _} = WorkItems.close(scope, work_item)
        send(view.pid, {:work_items_changed, [work_item.public_id]})
        assert has_element?(view, "#work-item-review-page-error", line)
        refute has_element?(view, @page_submit)

        Repo.get!(WorkItems.WorkItem, work_item.id)
        |> Ecto.Changeset.change(
          state: open.state,
          closed_at: open.closed_at,
          closed_by_id: open.closed_by_id
        )
        |> Repo.update!()

        send(view.pid, {:work_items_changed, [work_item.public_id]})

        refute has_element?(view, "#work-item-review-page-error")
        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
        assert has_element?(view, @page_submit)
      end
    end

    test "a review comment or a reply sent after the run started: the line under the field, with the text kept",
         %{conn: conn, scope: scope} do
      work_item = commented(scope)
      explore = explore(scope, work_item.number)

      views =
        for address <- ["?review=new", "?reply=c1"], do: elem(live(conn, explore <> address), 1)

      queue_attempt_2!(work_item)

      for {view, comment} <- Enum.zip(views, [[], [{"comment", "c1"}]]) do
        at_attempt_2(view)

        view
        |> element("#work-item-review-page-form")
        |> render_submit(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        assert has_element?(
                 view,
                 "#work-item-review-page-error",
                 started_as(run_number(work_item, 1))
               )

        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
      end

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
      assert [%{"id" => "c1"} = c1] = document["review_comments"]
      assert (c1["replies"] || []) == []
    end

    test "Send review comments after the run started: the line under the gate", %{
      conn: conn,
      scope: scope
    } do
      work_item = commented(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      queue_attempt_2!(work_item)
      at_attempt_2(view)

      view
      |> element("#work-item-explore-gate")
      |> render_submit(%{"number" => "#{work_item.number}"})

      assert has_element?(
               view,
               "#work-item-explore-gate-error",
               started_as(run_number(work_item, 1))
             )

      assert runs(work_item) == 2
    end

    test "Run with answers after the run started: the line under the form, the draft kept", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: questions_result(["Which currency?"]))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      queue_attempt_2!(work_item)
      at_attempt_2(view)

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The order's currency."}}
      })

      assert has_element?(
               view,
               "#work-item-explore-questions-error",
               started_as(run_number(work_item, 1))
             )

      assert has_element?(view, "#work-item-explore-questions-answer-1", "The order's currency.")
      assert runs(work_item) == 2
    end
  end

  describe "a reply" do
    test "goes only to the review comment of the open Reply page", %{conn: conn, scope: scope} do
      work_item = commented(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Keep the old PDFs.")
      explore = explore(scope, work_item.number)
      reply = &%{"number" => "#{work_item.number}", "comment" => &1, "text" => "Done."}

      # Another review comment's id, on the Reply page of c1 or on Add review comment.
      for {address, id} <- [{"?reply=c1", "c2"}, {"?review=new", "c1"}] do
        {:ok, view, _html} = live(conn, explore <> address)
        render_hook(view, "reply", reply.(id))
        assert has_element?(view, "#work-item-review-page-form")
      end

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
      assert Enum.map(document["review_comments"], &(&1["replies"] || [])) == [[], []]

      {:ok, view, _html} = live(conn, explore <> "?reply=c1")
      view |> element("#work-item-review-page-form") |> render_submit(reply.("c1"))
      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)

      assert [[%{"text" => "Done."}], []] =
               Enum.map(document["review_comments"], &(&1["replies"] || []))
    end
  end

  describe "the wait block of a run that a send of review comments started" do
    test "queued: the review comments; running: your review comments for the member who sent them, the review comments for another member",
         %{conn: conn, scope: scope} do
      work_item = commented(scope)
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
      %{user: member} = Apiary.OrganisationsFixtures.member_fixture(scope)
      wait = "#work-item-explore-wait p:last-child"

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert has_element?(
               view,
               wait,
               ~r/Attempt 2 starts when the workspace's pool takes it\. It reads the \w+, the newest proposal and the review comments\./
             )

      # Attempt 2 runs.
      Repo.delete_all(
        from d in DispatchRun, where: d.work_item_id == ^work_item.id and d.attempt == 2
      )

      explore_run_fixture(work_item, attempt: 2, state: :handed_over)

      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert has_element?(
               view,
               wait,
               ~r/Attempt 2 reads the \w+, the newest proposal and your review comments, then writes the next proposal and questions\./
             )

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member), explore(scope, work_item.number))

      assert has_element?(
               view,
               wait,
               ~r/Attempt 2 reads the \w+, the newest proposal and the review comments, then writes the next proposal and questions\./
             )
    end

    test "a run that answers started keeps the words of the answers", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: questions_result(@questions))
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "Euro"})
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-explore-wait p:last-child",
               ~r/Attempt 2 starts when the workspace's pool takes it\. It reads the \w+, the newest proposal and the questions with their answers\./
             )
    end
  end

  describe "the sender of the latest run" do
    test "is nil for a run that no send of review comments started", %{scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result())
      row = Repo.get!(WorkItems.WorkItem, work_item.id)
      page = ApiaryWeb.WorkItemLive.View.page(scope, row, WorkItems.explore(scope, row), [], %{})

      assert page.work_item.run.sent == false
      assert page.work_item.run.sent_by == nil
    end
  end

  describe "a send that writes nothing" do
    @changed "Check the page, then send again. The work item changed after the page showed it, so nothing was sent."
    @gone "Reload the page. Your access or the work item changed, so nothing was sent."

    test "Add review comment after another run wrote a proposal: the page read again, the line under the field, the text kept",
         %{conn: conn, scope: scope} do
      work_item = commented(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number) <> "?review=new")

      # Run 2 writes version 2 without a message to the page, which still shows attempt 1.
      explore_run_fixture(work_item, result: understood_result(%{"message" => "Version two."}))

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{"number" => "#{work_item.number}", "text" => "Keep the old PDFs."})

      assert has_element?(view, "#work-item-review-page-error", @changed)
      assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
      assert :sys.get_state(view.pid).socket.assigns.item.run.attempt == 2

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
      assert [%{"id" => "c1"}] = document["review_comments"]
    end

    test "Send review comments with none open on the server: the line under the gate, and no run",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      view
      |> element("#work-item-explore-gate")
      |> render_submit(%{"number" => "#{work_item.number}"})

      assert has_element?(view, "#work-item-explore-gate-error", @changed)
      assert runs(work_item) == 1
    end

    test "Reply to a work item closed after the page read it: the line under the field, the text kept",
         %{conn: conn, scope: scope} do
      work_item = commented(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number) <> "?reply=c1")

      Repo.get!(WorkItems.WorkItem, work_item.id)
      |> Ecto.Changeset.change(state: :closed, closed_at: DateTime.utc_now())
      |> Repo.update!()

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "comment" => "c1",
        "text" => "Keep the old PDFs."
      })

      assert has_element?(
               view,
               "#work-item-review-page-error",
               "Copy your text if you need it. You can no longer send this reply, because the work item changed."
             )

      assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
      refute has_element?(view, ~s(#work-item-review-page-form button[type="submit"]))

      {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
      assert [%{"id" => "c1"} = c1] = document["review_comments"]
      assert (c1["replies"] || []) == []
    end

    test "Run with answers on a work item the page can no longer find: the line under the form, the draft kept",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: questions_result(["Which currency?"]))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      :sys.replace_state(
        view.pid,
        &update_in(&1.socket.assigns.row, fn row -> %{row | id: Ecto.UUID.generate()} end)
      )

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The order's currency."}}
      })

      assert has_element?(view, "#work-item-explore-questions-error", @gone)
      assert has_element?(view, "#work-item-explore-questions-answer-1", "The order's currency.")
      assert runs(work_item) == 1
    end
  end

  describe "an earlier run's proposal" do
    test "its fold in the runs fold reads its text when it opens, and keeps it", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "The first take."}))
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      [run_1] =
        Repo.all(
          from r in Apiary.Runs.Run,
            join: d in DispatchRun,
            on: r.dispatch_run_id == d.id,
            where: d.work_item_id == ^work_item.id and d.attempt == 1,
            select: r.number
        )

      fold = "#work-item-record-#{run_1}"
      assert has_element?(view, "#{fold}-proposal .q-xp-cap", "Version 1")
      refute has_element?(view, fold, "The first take.")

      view |> element("#{fold}-s") |> render_click()
      assert has_element?(view, "#{fold}-proposal-text", "The first take.")
      assert has_element?(view, "#{fold}[phx-mounted]")
      refute has_element?(view, "#{fold}-s[phx-click]")

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert has_element?(view, "#{fold}-proposal-text", "The first take.")
    end

    test "a member removed after the page loaded opens an earlier proposal's fold: no store read and no text",
         %{scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "The first take."}))
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      member = Apiary.OrganisationsFixtures.member_fixture(scope, :member)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), explore(scope, work_item.number))

      fold = "#work-item-record-#{run_number(work_item, 1)}"
      Repo.delete!(member.membership)

      {result, opened} =
        opened_in(view.pid, fn -> view |> element("#{fold}-s") |> render_click() end)

      assert opened == []
      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == explore(scope, work_item.number)
    end

    # What `fun` returned, and the files `Apiary.Artifacts.open_file/1` opened in the
    # page's process `pid` while it ran, oldest first. The trace pattern stays set after
    # the call: only a traced process sends trace messages, and another test may trace
    # the same function at the same time.
    defp opened_in(pid, fun) do
      me = self()
      mfa = {Apiary.Artifacts, :open_file, 1}
      collector = spawn_link(fn -> collect_opened(pid, me, []) end)
      Code.ensure_loaded!(Apiary.Artifacts)
      assert :erlang.trace_pattern(mfa, true, [:local]) > 0
      :erlang.trace(pid, true, [:call, {:tracer, collector}])

      try do
        result = fun.()
        ref = :erlang.trace_delivered(pid)
        receive do: ({:trace_delivered, ^pid, ^ref} -> :ok)
        send(collector, :done)
        {result, receive(do: ({:opened, files} -> files))}
      after
        if Process.alive?(pid), do: :erlang.trace(pid, false, [:call])
      end
    end

    defp collect_opened(pid, me, files) do
      receive do
        {:trace, ^pid, :call, {Apiary.Artifacts, :open_file, [file]}} ->
          collect_opened(pid, me, [file | files])

        :done ->
          send(me, {:opened, Enum.reverse(files)})
      end
    end

    defp run_number(work_item, attempt) do
      Repo.one!(
        from r in Apiary.Runs.Run,
          join: d in DispatchRun,
          on: r.dispatch_run_id == d.id,
          where: d.work_item_id == ^work_item.id and d.attempt == ^attempt,
          select: r.number
      )
    end

    test "opening a run's fold reads that version's Markdown once, and nothing else from the store",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "The first take."}))
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      fold = "#work-item-record-#{run_number(work_item, 1)}"

      {_html, files} =
        opened_in(view.pid, fn -> view |> element("#{fold}-s") |> render_click() end)

      assert [%{content_type: "text/markdown" <> _}] = files
      assert has_element?(view, "#{fold}-proposal-text", "The first take.")
    end

    test "a fold whose read failed is read again when it opens again", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      first = unique("The first take.")
      explore_run_fixture(work_item, result: understood_result(%{"message" => first}))
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      fold = "#work-item-record-#{run_number(work_item, 1)}"

      [version] =
        Repo.all(
          from v in Apiary.Artifacts.Version,
            join: a in Apiary.Artifacts.Artifact,
            on: a.id == v.artifact_id,
            where: a.work_item_id == ^work_item.id and a.type == "proposal" and v.number == 1,
            preload: :files
        )

      [markdown] =
        Enum.filter(version.files, &String.starts_with?(&1.content_type, "text/markdown"))

      back = unreadable!(%{version | files: [markdown]})

      view |> element("#{fold}-s") |> render_click()
      refute has_element?(view, "#{fold}-proposal-text")
      assert has_element?(view, "#{fold}-s[phx-click]")

      back.()
      view |> element("#{fold}-s") |> render_click()
      assert has_element?(view, "#{fold}-proposal-text", first)
    end

    test "an earlier take in's fold reads its runs' proposals when it opens", %{
      conn: conn,
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "Take in one."}))
      {:ok, _closed} = WorkItems.close(scope, work_item)
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

      Repo.delete_all(
        from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2
      )

      explore_run_fixture(again, take_in: 2, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, again.number))

      fold = "#work-item-explore-take-ins-1"
      refute has_element?(view, fold, "Take in one.")

      view |> element("#{fold}-s") |> render_click()
      assert has_element?(view, fold, "Take in one.")
      refute has_element?(view, "#{fold}-s[phx-click]")
    end

    test "an earlier take in's fold whose file is lost shows its run's message, and reads the file again at each open",
         %{conn: conn, scope: scope} do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
      text = unique("Take in one.")
      kept = unique("The run's message.")

      %{dispatch_run: run} =
        explore_run_fixture(work_item, result: understood_result(%{"message" => text}))

      run |> Ecto.Changeset.change(result: %{"message" => kept}) |> Repo.update!()

      {:ok, _closed} = WorkItems.close(scope, work_item)
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

      Repo.delete_all(
        from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2
      )

      explore_run_fixture(again, take_in: 2, result: understood_result(%{"message" => @proposal}))

      [version] =
        Repo.all(
          from v in Apiary.Artifacts.Version,
            join: a in Apiary.Artifacts.Artifact,
            on: a.id == v.artifact_id,
            where: a.work_item_id == ^work_item.id and a.type == "proposal" and v.number == 1,
            preload: :files
        )

      [markdown] =
        Enum.filter(version.files, &String.starts_with?(&1.content_type, "text/markdown"))

      back = unreadable!(%{version | files: [markdown]})
      {:ok, view, _html} = live(conn, explore(scope, again.number))
      fold = "#work-item-explore-take-ins-1"
      refute has_element?(view, fold, kept)

      for _open <- 1..2 do
        view |> element("#{fold}-s") |> render_click()
        assert has_element?(view, fold, kept)
        assert has_element?(view, "#{fold}-s[phx-click]")
      end

      back.()
      view |> element("#{fold}-s") |> render_click()
      assert has_element?(view, fold, text)
      refute has_element?(view, fold, kept)
      refute has_element?(view, "#{fold}-s[phx-click]")
    end
  end

  describe "a version of the proposal with no Markdown file" do
    # Takes the Markdown file out of version `number` of the work item's proposal.
    defp without_markdown!(work_item, number) do
      Repo.delete_all(
        from f in Apiary.Artifacts.ArtifactFile,
          join: v in Apiary.Artifacts.Version,
          on: v.id == f.version_id,
          join: a in Apiary.Artifacts.Artifact,
          on: a.id == v.artifact_id,
          where: a.work_item_id == ^work_item.id and a.type == "proposal" and v.number == ^number,
          where: like(f.content_type, "text/markdown%")
      )
    end

    test "a row for a run that ended well, and no result for a failed run, with no read", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "The first take."}))

      %{dispatch_run: failed} =
        explore_run_fixture(work_item,
          settle: false,
          run: %{state: "failed", exit_state: "failed", outcome_state: "failed"},
          result: understood_result(%{"message" => "Version two."})
        )

      failed |> Ecto.Changeset.change(result_outcome: :none) |> Repo.update!()
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      without_markdown!(work_item, 1)
      without_markdown!(work_item, 2)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))
      [one, two] = [run_number(work_item, 1), run_number(work_item, 2)]

      assert has_element?(view, "div#work-item-record-#{one}.q-xp-runrow")
      refute has_element?(view, "#work-item-record-#{one}-s")
      assert has_element?(view, "#work-item-record-#{two}-none")
      refute has_element?(view, "#work-item-record-#{two}-proposal")
      refute has_element?(view, "#work-item-record-#{two}-s[phx-click]")
    end
  end

  describe "an earlier take in's fold, with a run that failed after it wrote a proposal" do
    test "opening it reads only the proposals its runs show", %{conn: conn, scope: scope} do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "Take in one."}))

      # Run 2 pushes version 2, then fails: the fold shows no proposal for it.
      %{dispatch_run: dispatch_run} =
        explore_run_fixture(work_item,
          settle: false,
          run: %{state: "failed", exit_state: "failed", outcome_state: "failed"},
          result: understood_result(%{"message" => "Version two."})
        )

      dispatch_run |> Ecto.Changeset.change(result_outcome: :none) |> Repo.update!()

      {:ok, _closed} = WorkItems.close(scope, Repo.get!(WorkItems.WorkItem, work_item.id))
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

      Repo.delete_all(
        from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2
      )

      explore_run_fixture(again, take_in: 2, result: understood_result(%{"message" => @proposal}))
      {:ok, view, _html} = live(conn, explore(scope, again.number))
      fold = "#work-item-explore-take-ins-1"

      {_html, files} =
        opened_in(view.pid, fn -> view |> element("#{fold}-s") |> render_click() end)

      assert [%{content_type: "text/markdown" <> _}] = files
      assert has_element?(view, fold, "Take in one.")
      refute has_element?(view, fold, "Version two.")
    end
  end

  describe "a run that failed after it wrote a proposal" do
    # Run 1 proposes version 1; run 2 pushes version 2, then fails, and its stored outcome
    # stays `none`.
    defp failed_after_proposal(scope) do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      %{dispatch_run: dispatch_run, run: run} =
        explore_run_fixture(work_item,
          settle: false,
          run: %{state: "failed", exit_state: "failed", outcome_state: "failed"},
          result: understood_result(%{"message" => "Version two."})
        )

      dispatch_run
      |> Ecto.Changeset.change(result_outcome: :none)
      |> Repo.update!()

      {work_item, run}
    end

    test "every line shows the proposal it wrote; none shows that there is nothing to show", %{
      conn: conn,
      scope: scope
    } do
      {work_item, run} = failed_after_proposal(scope)
      {:ok, view, html} = live(conn, explore(scope, work_item.number))

      failed = "The run failed after it wrote proposal version 2 (Run #{run.number})."
      assert has_element?(view, "#work-item-explore-none-h", failed)
      assert has_element?(view, "#work-item-explore-proposal-text", "Version two.")
      assert has_element?(view, "#work-item-step", failed)
      assert has_element?(view, "#work-item-record .q-xp-runrow", "Wrote a proposal")
      assert has_element?(view, "#work-item-record .q-xp-runrow", "Failed")

      for part <- ["#work-item-step", "#work-item-explore"],
          do: refute(has_element?(view, part, "ended without a result"))

      refute html =~ "There is nothing to show or confirm."

      {:ok, thread, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/thread")

      events = "[id^='work-item-thread-ev-']"
      assert has_element?(thread, events, "The run failed after it wrote proposal version 2.")
      refute has_element?(thread, events, "ended without a result")
    end
  end

  describe "answer_list/2" do
    @open [
      %{id: "q1", options: [%{title: "The order's currency"}, %{title: "The shop's currency"}]},
      %{id: "q2", options: []},
      %{id: "q3", options: [%{title: "Yes"}]}
    ]

    test "an option by its place, with a note; a note alone; Give your own option with its note" do
      draft = %{
        "q1" => %{"option" => "2", "note" => "As the books keep it."},
        "q2" => %{"note" => "Every invoice since 1 October."},
        "q3" => %{"option" => "own", "note" => "Only for bank refunds."}
      }

      assert Show.answer_list(draft, @open) ==
               {:ok,
                [
                  %{
                    "id" => "q1",
                    "option" => "The shop's currency",
                    "note" => "As the books keep it."
                  },
                  %{"id" => "q2", "option" => nil, "note" => "Every invoice since 1 October."},
                  %{"id" => "q3", "option" => nil, "note" => "Only for bank refunds."}
                ]}
    end

    test "a question with nothing picked and a blank field is left out; none at all is an empty list" do
      assert Show.answer_list(
               %{"q1" => %{"option" => "1", "note" => "  "}, "q2" => %{"note" => " "}},
               @open
             ) ==
               {:ok, [%{"id" => "q1", "option" => "The order's currency", "note" => nil}]}

      assert Show.answer_list(%{}, @open) == {:ok, []}
      assert Show.answer_list(%{"q9" => %{"note" => "Not a question."}}, @open) == {:ok, []}
    end

    test "Give your own option with a blank field is note_required, by question id" do
      draft = %{"q1" => %{"option" => "1"}, "q3" => %{"option" => "own", "note" => " \n "}}
      assert Show.answer_list(draft, @open) == {:error, %{"q3" => :note_required}}
    end

    test "an option out of range or not a place picks nothing" do
      for option <- ["0", "3", "-1", "1.0", "x", "The order's currency"] do
        assert Show.answer_list(%{"q1" => %{"option" => option}}, @open) == {:ok, []}, option
      end
    end
  end
end
