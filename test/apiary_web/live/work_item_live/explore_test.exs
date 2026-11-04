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
               "The agent is waiting for your answers. Running again sends them and updates the proposal."
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

      assert has_element?(view, "#{q}-answer-2-own")
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

    test "a question answered in take in 1 that take in 2's run reopened: the frame and the form show it; take in 1's fold too",
         %{conn: conn, scope: scope} do
      work_item = reopened_in_take_in_2(scope)
      {:ok, view, _html} = live(conn, explore(scope, work_item.number))

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-form")
      assert has_element?(view, "#{q}-question-1", "Which currency should the invoice PDF show?")
      assert has_element?(view, "#{q}-form [name^='answers[q1]']")

      assert has_element?(
               view,
               "#work-item-explore-take-ins-1",
               "Which currency should the invoice PDF show?"
             )
    end
  end

  # A work item whose take in 1 wrote question q1, a member answered it, and the take in
  # was closed; take in 2's run reopened q1, so q1 is open again.
  defp reopened_in_take_in_2(scope) do
    [currency, _credit_note] = @questions
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
    explore_run_fixture(work_item, result: questions_result([currency]))
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
    assert Enum.map(document["questions"], &{&1["id"], &1["state"]}) == [{"q1", "open"}]
    again
  end

  # A work item whose take in 1 wrote question q1, left open, and was closed; take in 2,
  # taken in again, wrote question q2, so q1 and q2 are both open in its questions.
  defp asked_in_two_take_ins(scope) do
    [currency, credit_note] = @questions
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^work_item.id)
    explore_run_fixture(work_item, result: questions_result([currency]))
    {:ok, _closed} = WorkItems.close(scope, work_item)

    {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

    Repo.delete_all(from d in DispatchRun, where: d.work_item_id == ^again.id and d.take_in == 2)

    explore_run_fixture(again, take_in: 2, result: questions_result([credit_note]))

    {_version, document} = Apiary.Explore.Questions.newest(again)

    assert Enum.map(document["questions"], &{&1["id"], &1["state"]}) == [
             {"q1", "open"},
             {"q2", "open"}
           ]

    again
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
    test "without open review comments: Confirm alone; with them, Run with comments first", %{
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
      refute render(view) =~ "Running again sends"

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the currency field.")
      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert has_element?(view, "#{gate}-send.btn-primary", "Run with comments")
      refute has_element?(view, "#{gate}-go.btn-primary")
      assert has_element?(view, "#{gate}-go", "Confirm")
      assert has_element?(view, "#{gate}-unread", "Confirm leaves 1 review comment unread.")
      assert has_element?(view, "#work-item-review h2", "Review comments")
      assert has_element?(view, "#work-item-review-c1-reply", "Reply")
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

  describe "a run that failed after it wrote a proposal" do
    # Run 1 proposes version 1; run 2 pushes version 2, then fails, and its stored outcome
    # stays `none`.
    defp failed_after_proposal(scope) do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      %{dispatch_run: dispatch_run} =
        explore_run_fixture(work_item,
          settle: false,
          run: %{state: "failed", exit_state: "failed", outcome_state: "failed"},
          result: understood_result(%{"message" => "Version two."})
        )

      dispatch_run
      |> Ecto.Changeset.change(result_outcome: :none)
      |> Repo.update!()

      work_item
    end

    test "every line shows the proposal it wrote; none shows that there is nothing to show", %{
      conn: conn,
      scope: scope
    } do
      work_item = failed_after_proposal(scope)
      {:ok, view, html} = live(conn, explore(scope, work_item.number))

      failed = "The run failed after it wrote proposal version 2."
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
      assert has_element?(thread, events, failed)
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
