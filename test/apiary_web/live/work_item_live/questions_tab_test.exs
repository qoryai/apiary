defmodule ApiaryWeb.WorkItemLive.QuestionsTabTest.NoSendRight do
  # A reader who may answer but may not send review comments: the form has no comment.
  def check(_scope, :"work_item.review_comment", _subject), do: {:error, :forbidden}
  def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
end

defmodule ApiaryWeb.WorkItemLive.QuestionsTabTest.NoAnswerRight do
  # A reader without `work_item.answer`: the questions are text.
  def check(_scope, :"work_item.answer", _subject), do: {:error, :forbidden}
  def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
end

defmodule ApiaryWeb.WorkItemLive.QuestionsTabTest do
  # The Questions tab of a work item's page (`ApiaryWeb.WorkItemLive.Show`, `/work/:number/
  # questions`): the open questions with the form that answers them, the answered questions
  # in groups by stage, the count in the tab bar, the line that points to the tab from a
  # stage's tab and from Explore's, the opening tab, and the texts of the form, which name
  # the stage that waits. A work item with a stage card (`taken_in_fixture/1`) and one with
  # none (`work_item_fixture/1`, the page as before the workflow model).
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkflowFake
  alias ApiaryWeb.WorkItemLive.QuestionsTabTest.{NoAnswerRight, NoSendRight}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"

  @options [
    %{"title" => "Redis", "explanation" => "The store the other services use."},
    %{"title" => "Postgres", "explanation" => "The database of the storefront."}
  ]

  @proposal """
  ## Facts

  The invoice PDF shows the shop's currency, not the order's.

  ## Proposed solution

  Read the currency from the order.
  """

  @open "#work-item-questions-open"
  @form "#work-item-questions-open-form"

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  setup %{scope: scope} do
    workspace = scope.workspace

    :ok =
      Processes.record_declared(
        workspace,
        Processes.qory_workflows(Apiary.Stacks.Sources.chosen(workspace)) ++
          ~w(shape-a-ticket build-it)
      )

    for workflow <- ~w(shape-a-ticket build-it) do
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        workflow: workflow,
        access: :read
      })
    end

    for name <- ~w(spec test-features) do
      {:ok, _type} =
        Artifacts.create_type(scope, workspace, %{
          "name" => name,
          "base_view" => "document",
          "size_limit" => 1_048_576,
          "max_files" => 1
        })
    end

    process!(scope)
    :ok
  end

  # The default process with Shape running a workflow, `outputs` its outputs.
  defp process!(scope, outputs \\ nil) do
    document = Processes.default_document("software")

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @shape} = stage ->
          Map.merge(stage, %{
            "sequence" => [%{"workflow" => "shape-a-ticket"}],
            "outputs" =>
              outputs ||
                [
                  %{"type" => "spec", "required" => true},
                  %{"type" => "decision-record", "required" => false},
                  %{"type" => "mockup", "required" => false},
                  %{"type" => "test-features", "required" => false}
                ],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          })

        stage ->
          stage
      end)

    {:ok, version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
    version
  end

  ## Addresses and reads

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp page(scope, number, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <> rest

  defp questions(scope, number), do: page(scope, number, "/questions")
  defp stage(scope, number, id \\ @shape), do: page(scope, number, "/stages/#{id}")

  defp run_path(scope, number),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{number}"

  defp attempt(work_item), do: newest_run(work_item).attempt

  # The text of the element, white space folded.
  defp line(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # The texts of the elements the selector matches, white space folded, in the page's order.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  # The line "Asked in <stage>, Run N" under the question `number`.
  defp asked(view, number) do
    view
    |> texts("#work-item-questions-question-#{number} .q-xp-by")
    |> Enum.find(&String.starts_with?(&1, "Asked in"))
  end

  # As `line/2`, with a link's text followed by the full stop that ends the sentence.
  defp sentence(view, selector),
    do: view |> line(selector) |> String.replace(~r/\s+\./, ".")

  defp question_document(work_item) do
    {_version, document} = Apiary.Explore.Questions.newest(work_item)
    document
  end

  # The number of the run that asked the question `id`, or reopened it last.
  defp run_of(work_item, id) do
    question = Enum.find(question_document(work_item)["questions"], &(&1["id"] == id))

    reopened =
      for entry <- question["history"] || [],
          run = get_in(entry, ["reopened", "run"]),
          do: run

    List.last(reopened) || question["asked"]["run"]
  end

  ## Work items with a stage card

  defp push!(run, work_item, type, text) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        reload(work_item),
        type,
        [%{filename: "#{type}.md", content_type: "text/markdown", binary: text}],
        name: "main",
        stage_id: run.stage_id
      )

    version
  end

  defp passed!(run) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        "verdict",
        %{"verdict" => "passed"},
        stage_id: run.stage_id
      )
  end

  # A work item at Shape: Explore's proposal confirmed, and Shape's first run queued.
  defp at_shape!(scope) do
    work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
    {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
    reload(work_item)
  end

  # A work item whose Shape run wrote spec and `questions`, so Shape waits for answers.
  defp waiting!(scope, questions \\ ["Which basket?", "Which sale?"]) do
    work_item = at_shape!(scope)

    work_item
    |> end_run!(fn run, registered ->
      push!(run, work_item, "spec", "## The spec text")
      push_result!(run, registered, questions_result(questions))
    end)
    |> reload()
  end

  defp decision(question) do
    %{
      "question" => question,
      "options" => @options,
      "option" => "Redis",
      "reason" => "The other services use Redis."
    }
  end

  # As `waiting!/2`, with a decision of the run, chosen and not answered, after the questions.
  defp waiting_with_decision!(scope) do
    work_item = at_shape!(scope)

    work_item
    |> end_run!(fn run, registered ->
      push!(run, work_item, "spec", "## The spec text")
      push_result!(run, registered, questions_result(["Which basket?"]))
      push_decided!(run, registered, [decision("Which store keeps the baskets?")])
    end)
    |> reload()
  end

  # Answers every open question of `work_item` with a note: queues the next run.
  defp answer_all!(scope, work_item) do
    answers =
      for %{"id" => id, "state" => "open"} <- question_document(work_item)["questions"],
          do: %{"id" => id, "option" => nil, "note" => "Answer to #{id}."}

    {:ok, _answered} = WorkItems.answer(scope, work_item, attempt(work_item), answers)
    reload(work_item)
  end

  # A work item at Shape's gate whose two questions, asked by Shape's first run, a member
  # answered.
  defp answered_at_gate!(scope) do
    work_item = scope |> waiting!() |> then(&answer_all!(scope, &1))

    work_item
    |> end_run!(fn run, _registered ->
      push!(run, work_item, "spec", "## The spec text")
      passed!(run)
    end)
    |> reload()
  end

  # Shape asked q1 and q2 and a member answered both; Shape reached its gate; the work item
  # moved back to Explore, whose run asked q3, and a member answered q3. The questions were
  # asked in the order q1 (Shape), q2 (Shape), q3 (Explore), the process order is Explore,
  # Shape.
  defp asked_at_two_stages!(scope) do
    work_item = answered_at_gate!(scope)
    assert work_item.stage_state == :at_gate
    {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

    work_item = work_item |> reload() |> end_run!(questions_result(["Which store?"])) |> reload()
    assert work_item.stage_state == :waiting_answers
    answer_all!(scope, work_item)
  end

  # Explore asked q1 and q2 and a member answered both; Shape's first run reopened q1 and
  # a member answered it again. q1 belongs to Shape's group now, q2 to Explore's.
  defp reopened_at_shape!(scope) do
    work_item = scope |> taken_in_fixture() |> end_run!(questions_result())
    work_item = scope |> answer_all!(work_item) |> end_run!(understood_result())
    {:ok, _confirmed} = WorkItems.confirm(scope, work_item, attempt(work_item))
    work_item = reload(work_item)

    work_item =
      work_item
      |> end_run!(fn run, registered ->
        questions =
          Enum.map(question_document(work_item)["questions"], fn
            %{"id" => "q1", "answer" => answer} = question ->
              at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
              reopened = Map.put(answer, "reopened", %{"run" => registered.number, "at" => at})

              question
              |> Map.delete("answer")
              |> Map.put("state", "open")
              |> Map.put("history", (question["history"] || []) ++ [reopened])

            question ->
              question
          end)

        push!(run, work_item, "spec", "## The spec text")

        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            reload(work_item),
            "questions",
            [Apiary.Explore.Questions.file(%{"questions" => questions})],
            name: "main",
            stage_id: run.stage_id
          )

        passed!(run)
      end)
      |> reload()

    assert work_item.stage_state == :waiting_answers
    answer_all!(scope, work_item)
  end

  ## Work items with no stage card

  # Run 1 proposes, run 2 writes two questions: the proposal waits and the questions are open.
  defp asked_after_proposal!(scope, opts \\ []) do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

    explore_run_fixture(
      work_item,
      [result: questions_result(["Which currency?", "Should the credit note change too?"])] ++
        opts
    )

    work_item
  end

  # A work item whose first run asked a question: no proposal yet.
  defp asked_first!(scope) do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, result: questions_result(["Which currency?"]))
    work_item
  end

  describe "the open and answered questions of a work item with a stage card" do
    test "an open question: the stage and the run that asked it, the run linked", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope)
      run = run_of(work_item, "q1")

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert has_element?(view, "#{@open}-h", "Open questions")
      refute has_element?(view, "#{@open} h3", "Open questions")
      refute has_element?(view, "#work-item-questions-answered")

      assert asked(view, 1) == "Asked in Shape, Run #{run}"
      assert asked(view, 2) == "Asked in Shape, Run #{run}"

      assert has_element?(
               view,
               ~s|#work-item-questions-question-1 .q-xp-by a.q-link[href="#{run_path(scope, run)}"]|,
               "Run #{run}"
             )

      assert has_element?(view, "#{@open}-answer-1")
      assert has_element?(view, "#{@open}-answer-2")
    end

    test "the answered questions are in groups by stage, in the process order", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_at_two_stages!(scope)

      # The agents asked q1 and q2 at Shape before they asked q3 at Explore.
      assert run_of(work_item, "q1") < run_of(work_item, "q3")

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      refute has_element?(view, @open)
      assert has_element?(view, "#work-item-questions-answered-h", "Answered questions")

      list = "#work-item-questions-answered-list"
      assert line(view, "#{list} > .q-xp-sec:nth-child(1) > h3") == "Explore"
      assert line(view, "#{list} > .q-xp-sec:nth-child(2) > h3") == "Shape"
      refute has_element?(view, "#{list} > .q-xp-sec:nth-child(3)")

      # Explore's group: q3, which keeps its number from the order of the questions.
      assert has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(1) #work-item-questions-question-3"
             )

      refute has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(1) #work-item-questions-question-1"
             )

      # Shape's group: q1, then q2, the order in which they were asked.
      group = "#{list} > .q-xp-sec:nth-child(2) .q-xp-closed"
      assert has_element?(view, "#{group} > details:nth-child(1)#work-item-questions-question-1")
      assert has_element?(view, "#{group} > details:nth-child(2)#work-item-questions-question-2")
      refute has_element?(view, "#{group} #work-item-questions-question-3")

      assert has_element?(view, "#work-item-questions-question-1-answer", "Answer to q1.")
      assert has_element?(view, "#work-item-questions-question-1-answer-who", "You answered")
    end

    test "each answered question: the stage and the linked run that asked it", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_at_two_stages!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      for {n, id, stage} <- [{1, "q1", "Shape"}, {2, "q2", "Shape"}, {3, "q3", "Explore"}] do
        run = run_of(work_item, id)

        assert asked(view, n) == "Asked in #{stage}, Run #{run}"

        assert has_element?(
                 view,
                 ~s|#work-item-questions-question-#{n} a.q-link[href="#{run_path(scope, run)}"]|,
                 "Run #{run}"
               )
      end
    end

    test "a question that a later run reopened: in the group of that run's stage, with its number",
         %{conn: conn, scope: scope} do
      work_item = reopened_at_shape!(scope)

      # q1 was asked at Explore, and Shape's run reopened it.
      shape_run = run_of(work_item, "q1")
      explore_run = run_of(work_item, "q2")
      assert shape_run > explore_run

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      list = "#work-item-questions-answered-list"
      assert line(view, "#{list} > .q-xp-sec:nth-child(1) > h3") == "Explore"
      assert line(view, "#{list} > .q-xp-sec:nth-child(2) > h3") == "Shape"

      assert has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(1) #work-item-questions-question-2"
             )

      refute has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(1) #work-item-questions-question-1"
             )

      assert has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(2) #work-item-questions-question-1"
             )

      assert asked(view, 1) == "Asked in Shape, Run #{shape_run}"
      assert asked(view, 2) == "Asked in Explore, Run #{explore_run}"

      assert has_element?(
               view,
               ~s|#work-item-questions-question-1 a.q-link[href="#{run_path(scope, shape_run)}"]|
             )
    end

    test "open questions beside answered ones: both frames, the form only over the open", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_at_two_stages!(scope)

      # Explore's next run asks one more question.
      work_item = work_item |> end_run!(questions_result(["Which plan?"])) |> reload()
      assert work_item.stage_state == :waiting_answers

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert has_element?(view, "#{@open}-h", "Open questions")
      assert has_element?(view, "#{@form} #work-item-questions-question-4")
      refute has_element?(view, "#{@form} #work-item-questions-question-3")
      assert has_element?(view, "#work-item-questions-answered-h", "Answered questions")
      assert has_element?(view, "#work-item-questions-answered #work-item-questions-question-3")
    end

    test "the form lists the decisions of the stage that waits; an earlier stage's stay on its tab",
         %{conn: conn, scope: scope} do
      explore_decision = "Which store keeps the baskets?"
      shape_decision = "Which store keeps the orders?"

      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          push_decided!(run, registered, [decision(explore_decision)])
        end)

      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)
      work_item = reload(work_item)

      work_item =
        work_item
        |> end_run!(fn run, registered ->
          push!(run, work_item, "spec", "## The spec text")
          push_result!(run, registered, questions_result(["Which basket?"]))
          push_decided!(run, registered, [decision(shape_decision)])
        end)
        |> reload()

      assert work_item.stage_state == :waiting_answers

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      # Shape waits: its decision is in the form, Explore's is not.
      decisions = "#{@form} #{@open}-decisions"
      assert has_element?(view, decisions, shape_decision)
      refute has_element?(view, @open, explore_decision)
      assert has_element?(view, "#{@open}-decision-2", shape_decision)
      refute has_element?(view, "#{@open}-decision-1")

      # Explore's decision stays in the Decisions frame of Explore's tab, and only there.
      {:ok, explore_view, _html} = live(conn, stage(scope, work_item.number, @explore))
      assert has_element?(explore_view, "#work-item-explore-decisions", explore_decision)
      refute has_element?(explore_view, "#work-item-explore-decisions", shape_decision)

      listed = fn html, text -> length(String.split(html, text)) - 1 end
      assert listed.(render(view), explore_decision) == 0
      assert listed.(render(view), shape_decision) == 1
      assert listed.(render(explore_view), explore_decision) == 1
    end

    test "a withdrawn question: in the group of its stage, under Answered questions, with the Withdrawn badge",
         %{conn: conn, scope: scope} do
      work_item = waiting!(scope)
      withdraw!(newest_run(work_item), work_item, "q1")

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      answered = "#work-item-questions-answered"
      assert line(view, "#{answered} .q-xp-sec:nth-child(1) > h3") == "Shape"
      assert has_element?(view, "#{answered} #work-item-questions-question-1", "Which basket?")
      assert has_element?(view, "#{answered} #work-item-questions-question-1 .badge", "Withdrawn")

      # The other question stays open, with its field.
      assert has_element?(view, "#{@form} #work-item-questions-question-2")
      refute has_element?(view, "#{@form} #work-item-questions-question-1")
      refute has_element?(view, "#{@open}-answer-1")
      assert has_element?(view, "#{@open}-answer-2")
    end
  end

  describe "the open and answered questions of a work item with no stage card" do
    test "the group is Explore's, and each question names Explore and its run", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      run = run_of(work_item, "q1")

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert asked(view, 1) == "Asked in Explore, Run #{run}"

      assert has_element?(
               view,
               ~s|#work-item-questions-question-1 a.q-link[href="#{run_path(scope, run)}"]|,
               "Run #{run}"
             )

      # Answered, the questions are in one group, Explore's.
      {:ok, _answered} =
        WorkItems.answer(scope, work_item, 2, [
          %{"id" => "q1", "option" => nil, "note" => "The order's."},
          %{"id" => "q2", "option" => nil, "note" => "Yes."}
        ])

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      list = "#work-item-questions-answered-list"
      assert line(view, "#{list} > .q-xp-sec:nth-child(1) > h3") == "Explore"
      refute has_element?(view, "#{list} > .q-xp-sec:nth-child(2)")

      assert has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(1) .q-xp-closed > details:nth-child(1)#work-item-questions-question-1"
             )

      assert has_element?(
               view,
               "#{list} > .q-xp-sec:nth-child(1) .q-xp-closed > details:nth-child(2)#work-item-questions-question-2"
             )
    end

    test "a withdrawn question: in Explore's group with the Withdrawn badge", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      withdraw!(newest_run(work_item), work_item, "q1")

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      answered = "#work-item-questions-answered"
      assert line(view, "#{answered} .q-xp-sec:nth-child(1) > h3") == "Explore"
      assert has_element?(view, "#{answered} #work-item-questions-question-1 .badge", "Withdrawn")
      assert has_element?(view, "#{@form} #work-item-questions-question-2")
    end
  end

  describe "the tab bar" do
    test "the open questions are counted beside Questions, before the Thread", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))

      assert has_element?(view, "#work-item-tabs-questions", "Questions")
      assert line(view, "#work-item-tabs-questions .q-tabs-n") == "2"
      assert has_element?(view, "#work-item-tabs-questions .hero-question-mark-circle")

      assert has_element?(
               view,
               ~s|#work-item-tabs-questions[href="#{questions(scope, work_item.number)}"]|
             )

      tabs = view |> element("#work-item-tabs") |> render()
      [before_questions, after_questions] = String.split(tabs, ~s|id="work-item-tabs-questions"|)
      assert before_questions =~ ~s|id="work-item-tabs-ticket"|
      assert after_questions =~ ~s|id="work-item-tabs-thread"|
    end

    test "the count has no digit once no question is open, and the tab stays", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_at_two_stages!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))

      assert has_element?(view, "#work-item-tabs-questions", "Questions")
      refute has_element?(view, "#work-item-tabs-questions .q-tabs-n")
    end

    test "a work item with no question has no Questions tab", %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))

      refute has_element?(view, "#work-item-tabs-questions")
    end

    test "with no stage card: Ticket, Explore, Questions and Thread, as soon as a question exists",
         %{conn: conn, scope: scope} do
      proposed = work_item_fixture(scope)
      explore_run_fixture(proposed, result: understood_result(%{"message" => @proposal}))

      {:ok, view, _html} = live(conn, page(scope, proposed.number, "/ticket"))
      refute has_element?(view, "#work-item-tabs-questions")

      work_item = asked_first!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))

      tabs = view |> element("#work-item-tabs") |> render()

      assert Regex.scan(~r/id="work-item-tabs-([a-z]+)"/, tabs, capture: :all_but_first) ==
               [["ticket"], ["explore"], ["questions"], ["thread"]]

      assert line(view, "#work-item-tabs-questions .q-tabs-n") == "1"
    end
  end

  describe "the line on a stage's tab and on Explore's" do
    test "one question: the singular line, linked to the Questions tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope, ["Which basket?"])
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert sentence(view, "#work-item-tab-questions-line") ==
               "The agents of this stage asked 1 question. See it on the Questions tab."

      assert has_element?(
               view,
               ~s|#work-item-tab-questions-line a[href="#{questions(scope, work_item.number)}"]|,
               "Questions tab"
             )
    end

    test "the sentence ends with the link and a full stop, with no space before it", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope, ["Which basket?"])
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert line(view, "#work-item-tab-questions-line") ==
               "The agents of this stage asked 1 question. See it on the Questions tab."
    end

    test "three questions: the plural line", %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["Which basket?", "Which sale?", "Which store?"])
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert sentence(view, "#work-item-tab-questions-line") ==
               "The agents of this stage asked 3 questions. See them on the Questions tab."

      assert has_element?(
               view,
               ~s|#work-item-tab-questions-line a[href="#{questions(scope, work_item.number)}"]|
             )
    end

    test "a stage's tab counts only the questions of that stage", %{conn: conn, scope: scope} do
      work_item = asked_at_two_stages!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      assert sentence(view, "#work-item-tab-questions-line") =~ "asked 2 questions. See them"

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))
      assert sentence(view, "#work-item-explore-questions-line") =~ "asked 1 question. See it"
    end

    test "a move back to Explore leaves Shape's open questions on Shape's tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)
      work_item = reload(work_item)
      assert work_item.stage_id == @explore

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))
      refute has_element?(view, "#work-item-explore-questions-line")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      assert sentence(view, "#work-item-tab-questions-line") =~ "asked 2 questions. See them"
    end

    test "a stage with no question has no line", %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      refute has_element?(view, "#work-item-tab-questions-line")
    end

    test "Explore's tab at Explore: the line, with the link", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))

      assert sentence(view, "#work-item-explore-questions-line") ==
               "The agents of this stage asked 1 question. See it on the Questions tab."

      assert has_element?(
               view,
               ~s|#work-item-explore-questions-line a[href="#{questions(scope, work_item.number)}"]|
             )
    end

    test "Explore's tab with no stage card: the line, singular and plural", %{
      conn: conn,
      scope: scope
    } do
      one = asked_first!(scope)
      {:ok, view, _html} = live(conn, page(scope, one.number, "/explore"))

      assert sentence(view, "#work-item-explore-questions-line") ==
               "The agents of this stage asked 1 question. See it on the Questions tab."

      assert has_element?(
               view,
               ~s|#work-item-explore-questions-line a[href="#{questions(scope, one.number)}"]|,
               "Questions tab"
             )

      two = asked_after_proposal!(scope)
      {:ok, view, _html} = live(conn, page(scope, two.number, "/explore"))

      assert sentence(view, "#work-item-explore-questions-line") ==
               "The agents of this stage asked 2 questions. See them on the Questions tab."
    end

    test "the stage's tab and Explore's tab draw no questions frame", %{conn: conn, scope: scope} do
      work_item = waiting!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      refute has_element?(view, "#work-item-tab-questions")
      refute has_element?(view, "#work-item-tab-questions-form")
      refute has_element?(view, "#work-item-tab-questions-go")

      none = asked_first!(scope)
      {:ok, view, _html} = live(conn, page(scope, none.number, "/explore"))
      refute has_element?(view, "#work-item-explore-questions")
      refute has_element?(view, "#work-item-explore-questions-form")
    end
  end

  describe "the output frame and the version of the questions" do
    test "a stage's tab has no output frame Questions", %{conn: conn, scope: scope} do
      process!(scope, [
        %{"type" => "spec", "required" => true},
        %{"type" => "questions", "required" => false}
      ])

      work_item = waiting!(scope)
      assert "questions" in Enum.map(Stages.status(work_item).outputs, & &1.type)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-spec")
      refute has_element?(view, "#work-item-tab-output-questions")
      refute has_element?(view, "#work-item-tab-output-questions-fold")
    end

    test "the runs fold line has no questions vN, on the stage tab, Ticket, Thread and Explore's tab",
         %{conn: conn, scope: scope} do
      work_item = waiting!(scope)

      for {address, version} <- [
            {stage(scope, work_item.number), "spec v1"},
            {stage(scope, work_item.number, @explore), "proposal v1"},
            {page(scope, work_item.number, "/ticket"), "spec v1"},
            {page(scope, work_item.number, "/thread"), "spec v1"}
          ] do
        {:ok, view, _html} = live(conn, address)

        assert has_element?(view, "#work-item-record-fold > summary", version)
        refute has_element?(view, "#work-item-record-fold > summary", "questions v")
      end
    end

    test "Explore's runs fold line with no stage card has no questions vN", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(view, "#work-item-record-fold > summary", "2 runs")
      assert has_element?(view, "#work-item-record-fold > summary", "proposal v1")
      refute has_element?(view, "#work-item-record-fold > summary", "questions v")
    end

    test "the gate card's output list has no questions vN", %{conn: conn, scope: scope} do
      process!(scope, [
        %{"type" => "spec", "required" => true},
        %{"type" => "questions", "required" => false}
      ])

      work_item = answered_at_gate!(scope)
      assert work_item.stage_state == :at_gate
      assert "questions" in Enum.map(Stages.status(work_item).outputs, & &1.type)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-output-spec", "spec v")
      refute has_element?(view, "#work-item-stage-gate-output-questions")
      refute has_element?(view, "#work-item-stage-gate", "questions v")
    end

    test "the About list of Request changes has no questions vN", %{conn: conn, scope: scope} do
      process!(scope, [
        %{"type" => "spec", "required" => true},
        %{"type" => "questions", "required" => false}
      ])

      work_item = answered_at_gate!(scope)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      assert has_element?(view, "#work-item-stage-gate-changes-version option", "spec v")
      refute has_element?(view, "#work-item-stage-gate-changes-version option", "questions")
    end

    test "the Artifacts list still lists questions vN", %{conn: conn, scope: scope} do
      work_item = waiting!(scope)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-artifact-list", "questions v1")
    end
  end

  describe "the tab a work item opens on" do
    test "the Questions tab while Shape waits for answers", %{conn: conn, scope: scope} do
      work_item = waiting!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-questions[aria-current=page]")
      assert has_element?(view, @form)
    end

    test "Shape's tab once the questions are answered and Shape is at its gate", %{
      conn: conn,
      scope: scope
    } do
      work_item = answered_at_gate!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
      refute has_element?(view, "#work-item-tabs-questions[aria-current=page]")
    end

    test "Shape's tab with no question", %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
    end

    test "Explore's stage waiting for answers opens on the Questions tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-questions[aria-current=page]")
    end

    test "a work item whose run is closed over its questions opens on the usual tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope)
      {:ok, _closed} = WorkItems.close(scope, work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-ticket[aria-current=page]")
      refute has_element?(view, "#work-item-tabs-questions[aria-current=page]")
    end

    test "with no stage card: the Questions tab while the work item needs answers", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-questions[aria-current=page]")
      assert has_element?(view, @form)
    end

    test "with no stage card: the usual tab once the questions are answered", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)

      {:ok, _answered} =
        WorkItems.answer(scope, work_item, 2, [
          %{"id" => "q1", "option" => nil, "note" => "The order's."},
          %{"id" => "q2", "option" => nil, "note" => "Yes."}
        ])

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-tabs-questions[aria-current=page]")
      assert has_element?(view, "#work-item-tabs-questions")
    end

    test "with no stage card and no question: the usual tab", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-tabs-questions")
      assert has_element?(view, "#work-item-tabs [aria-current=page]")
    end
  end

  describe "/questions" do
    test "a work item with no question patches to the work item's address", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape!(scope)
      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, questions(scope, work_item.number))
    end

    test "with no stage card, a work item with no question patches to the work item's address",
         %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => @proposal}))
      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, questions(scope, work_item.number))
    end

    test "a work item whose only question is a decision of the run has no Questions tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, registered ->
          push!(run, work_item, "spec", "## The spec text")
          push_decided!(run, registered, [decision("Which store keeps the baskets?")])
          passed!(run)
        end)
        |> reload()

      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, questions(scope, work_item.number))

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))
      refute has_element?(view, "#work-item-tabs-questions")
    end
  end

  # The eight variants of the form's caption, by whether the form has the comment, whether a
  # decision of the run is open to change, and what the next run updates.
  @captions [
    {true, true, :outputs,
     "Run another round of Shape starts Shape's next run. That run reads your answers, your changed decisions and your comment, and updates Shape's outputs."},
    {true, false, :outputs,
     "Run another round of Shape starts Shape's next run. That run reads your answers and your comment, and updates Shape's outputs."},
    {false, true, :outputs,
     "Run another round of Shape starts Shape's next run. That run reads your answers and your changed decisions, and updates Shape's outputs."},
    {false, false, :outputs,
     "Run another round of Shape starts Shape's next run. That run reads your answers and updates Shape's outputs."},
    {true, true, :proposal,
     "Run another round of Explore starts Explore's next run. That run reads your answers, your changed decisions and your comment, and updates Explore's proposal."},
    {true, false, :proposal,
     "Run another round of Explore starts Explore's next run. That run reads your answers and your comment, and updates Explore's proposal."},
    {false, true, :proposal,
     "Run another round of Explore starts Explore's next run. That run reads your answers and your changed decisions, and updates Explore's proposal."},
    {false, false, :proposal,
     "Run another round of Explore starts Explore's next run. That run reads your answers and updates Explore's proposal."}
  ]

  describe "the form's texts name the stage" do
    for {commenting, change, updates, caption} <- @captions do
      test "the caption with commenting #{commenting}, changed decisions #{change}, #{updates}",
           %{conn: conn, scope: scope} do
        view = form_view(conn, scope, unquote(commenting), unquote(change), unquote(updates))

        assert line(view, "#{@open}-cap") == unquote(caption)
      end
    end

    test "the comment label and the button at a stage after Explore", %{conn: conn, scope: scope} do
      work_item = waiting!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert line(view, "#{@form} .q-xp-comment label") == "Comment on Shape's outputs"
      assert has_element?(view, "#{@open}-go[disabled]", "Run another round of Shape")
      refute has_element?(view, "#{@open}-go", "Run another round of Shape's")
    end

    test "the comment label and the button at Explore, over a proposal", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert line(view, "#{@form} .q-xp-comment label") == "Comment on the whole proposal"
      assert has_element?(view, "#{@open}-go[disabled]", "Run another round of Explore")
    end

    test "the button at Explore with a stage card, over no proposal", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert has_element?(view, "#{@open}-go", "Run another round of Explore")
      refute has_element?(view, "#{@form} .q-xp-comment")
    end

    test "the button and the caption name the stage after a move back to Explore", %{
      conn: conn,
      scope: scope
    } do
      work_item = answered_at_gate!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      work_item =
        work_item |> reload() |> end_run!(questions_result(["Which store?"])) |> reload()

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert has_element?(view, "#{@open}-go", "Run another round of Explore")

      assert line(view, "#{@open}-cap") =~
               "Run another round of Explore starts Explore's next run."
    end
  end

  # The Questions tab of a work item that waits for answers, as a view, with the form's
  # comment (`commenting`), a decision of the run that a reader may change (`change`), and
  # a next run that updates Shape's `:outputs` or Explore's `:proposal`.
  defp form_view(conn, scope, commenting, change, updates) do
    work_item =
      case {updates, change} do
        {:outputs, false} ->
          waiting!(scope, ["Which basket?"])

        {:outputs, true} ->
          waiting_with_decision!(scope)

        {:proposal, change} ->
          opts =
            if change, do: [decisions: [decision("Which store keeps the baskets?")]], else: []

          asked_after_proposal!(scope, opts)
      end

    if not commenting, do: :ok = Apiary.Edition.put_test_stub(NoSendRight)

    {:ok, view, _html} = live(conn, questions(scope, work_item.number))
    assert has_element?(view, @form)
    assert has_element?(view, "#{@open}-decisions") == change
    assert has_element?(view, "#{@form} .q-xp-comment") == commenting
    view
  end

  describe "answering from the Questions tab" do
    test "the answer asks to spend, then queues Shape's next run", %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["Which basket?"])
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      before = attempt(work_item)

      view
      |> element(@form)
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The cart."}}
      })

      assert has_element?(view, "#spend-dialog-title", "Run another round of Shape?")
      assert has_element?(view, "#spend-dialog-go", "Run another round of Shape")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-questions-open-go"]|)
      assert attempt(work_item) == before

      confirm_spend(view)

      assert %DispatchRun{state: :waiting, stage_id: @shape, attempt: attempt} =
               newest_run(work_item)

      assert attempt == before + 1
      assert has_element?(view, "#work-item-questions-question-1-answer", "The cart.")
      refute has_element?(view, @form)
    end

    test "cancel in the dialog starts nothing and keeps the draft", %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["Which basket?"])
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      before = attempt(work_item)

      drafted = %{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The cart."}},
        "comment" => "Name the field."
      }

      view |> element(@form) |> render_change(drafted)
      view |> element(@form) |> render_submit(drafted)
      assert has_element?(view, "#spend-dialog-title", "Run another round of Shape?")

      view |> element("#spend-dialog-cancel") |> render_click()
      refute has_element?(view, "#spend-dialog")
      assert attempt(work_item) == before
      assert has_element?(view, "#{@open}-comment", "Name the field.")
      assert has_element?(view, "#{@open}-answer-1", "The cart.")
    end

    test "with no stage card: the dialog names Explore, and Explore's next run is queued", %{
      conn: conn,
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      view
      |> element(@form)
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q2" => %{"note" => "Yes."}}
      })

      assert has_element?(view, "#spend-dialog-title", "Run another round of Explore?")
      assert has_element?(view, "#spend-dialog-go", "Run another round of Explore")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-questions-open-go"]|)

      confirm_spend(view)

      assert %DispatchRun{state: :waiting, attempt: 3} = newest_run(work_item)
      # The answered question is numbered before the one still open.
      assert has_element?(view, "#work-item-questions-question-1-answer", "Yes.")
    end

    test "Run another round at Explore after a move back runs Explore's next round", %{
      conn: conn,
      scope: scope
    } do
      work_item = answered_at_gate!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      work_item =
        work_item |> reload() |> end_run!(questions_result(["Which store?"])) |> reload()

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      view
      |> element(@form)
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q3" => %{"note" => "The spring sale."}}
      })

      assert has_element?(view, "#spend-dialog-title", "Run another round of Explore?")
      confirm_spend(view)

      assert %DispatchRun{state: :waiting, stage_id: @explore} = newest_run(work_item)
    end

    test "questions that changed after the page showed them: no answer, the error names the stage, the draft stays",
         %{conn: conn, scope: scope} do
      work_item = waiting!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      shown = :sys.get_state(view.pid).socket.assigns.questions
      before = attempt(work_item)

      # Another member's run withdraws q1. The click comes before the page reads the
      # questions again, so the page still has the questions it showed.
      withdraw!(newest_run(work_item), work_item, "q1")
      render(view)
      :sys.replace_state(view.pid, &put_in(&1.socket.assigns.questions, shown))

      view
      |> element(@form)
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{
          "q1" => %{"option" => nil, "note" => "The cart."},
          "q2" => %{"note" => "The spring sale."}
        }
      })

      confirm_spend(view)

      assert line(view, "#{@open}-error") ==
               "Check the questions and your answers, then click Run another round of Shape again. The questions changed after the page showed them, so no answer was sent."

      # The questions read again: q1 is withdrawn, q2 open with its draft.
      refute has_element?(view, "#{@open}-answer-1")
      assert has_element?(view, "#{@open}-answer-2", "The spring sale.")

      assert attempt(work_item) == before
      document = question_document(work_item)
      assert Enum.map(document["questions"], & &1["state"]) == ["withdrawn", "open"]
    end

    test "with no stage card: the error names Explore", %{conn: conn, scope: scope} do
      work_item = asked_after_proposal!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      shown = :sys.get_state(view.pid).socket.assigns.questions

      withdraw!(newest_run(work_item), work_item, "q1")
      render(view)
      :sys.replace_state(view.pid, &put_in(&1.socket.assigns.questions, shown))

      view
      |> element(@form)
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{
          "q1" => %{"option" => nil, "note" => "The order's."},
          "q2" => %{"note" => "Yes."}
        }
      })

      confirm_spend(view)

      assert line(view, "#{@open}-error") ==
               "Check the questions and your answers, then click Run another round of Explore again. The questions changed after the page showed them, so no answer was sent."
    end
  end

  describe "a reader who may not answer" do
    test "sees the questions as text, with no form, and the tab is listed", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope)
      :ok = Apiary.Edition.put_test_stub(NoAnswerRight)

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-questions[aria-current=page]")
      assert has_element?(view, "#{@open}-h", "Open questions")
      assert has_element?(view, "#work-item-questions-question-1", "Which basket?")
      assert has_element?(view, "#work-item-questions-question-2", "Which sale?")

      assert asked(view, 1) =~ "Asked in Shape, Run "

      refute has_element?(view, @form)
      refute has_element?(view, "#{@open}-go")
      refute has_element?(view, "#{@open}-cap")
      refute has_element?(view, "#{@open} textarea")
      refute has_element?(view, "#{@open} input[type=radio]")
    end

    test "with no stage card: the questions as text", %{conn: conn, scope: scope} do
      work_item = asked_after_proposal!(scope)
      :ok = Apiary.Edition.put_test_stub(NoAnswerRight)

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-questions")
      assert has_element?(view, "#work-item-questions-question-1", "Which currency?")
      refute has_element?(view, @form)
      refute has_element?(view, "#{@open} textarea")
    end
  end

  ## A new version of the questions pushed by the run of the queue `dispatch_run`, with the
  ## question `id` withdrawn.

  defp withdraw!(dispatch_run, work_item, id) do
    questions =
      Enum.map(question_document(work_item)["questions"], fn
        %{"id" => ^id} = question -> Map.put(question, "state", "withdrawn")
        question -> question
      end)

    {:ok, _version} =
      while_live(dispatch_run, fn ->
        Artifacts.push(
          {:run, dispatch_run},
          reload(work_item),
          "questions",
          [Apiary.Explore.Questions.file(%{"questions" => questions})],
          name: "main",
          stage_id: dispatch_run.stage_id
        )
      end)
  end

  describe "the decisions, the references and the refreshes of the tab" do
    @explore_decision "Which store keeps the baskets?"

    # Explore decided a question and its proposal is confirmed; Shape's run asked "Which
    # basket?" and Shape waits for answers.
    defp decided_then_asked!(scope) do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          push_decided!(run, registered, [decision(@explore_decision)])
        end)

      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)
      work_item = reload(work_item)

      work_item
      |> end_run!(fn run, registered ->
        push!(run, work_item, "spec", "## The spec text")
        push_result!(run, registered, questions_result(["Which basket?"]))
      end)
      |> reload()
    end

    test "a decision shows in one place when the current stage has no tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = decided_then_asked!(scope)

      build =
        Enum.find_value(
          Processes.default_document("software")["stages"],
          &(&1["name"] == "Build" && &1["id"])
        )

      # The work item moves on to Build, which runs no workflow and so has no tab; Shape's
      # question stays open.
      {:ok, _moved} = Stages.move(scope, work_item, build, nil, expect_stage: @shape)
      work_item = reload(work_item)
      assert work_item.stage_id == build

      {:ok, explore, _html} = live(conn, stage(scope, work_item.number, @explore))
      {:ok, tab, _html} = live(conn, questions(scope, work_item.number))

      listed = fn view -> length(String.split(render(view), @explore_decision)) - 1 end

      assert has_element?(explore, "#work-item-explore-decisions", @explore_decision)
      assert listed.(explore) == 1
      assert listed.(tab) == 0
    end

    test "Follows question is text where the tab draws no such question", %{
      conn: conn,
      scope: scope
    } do
      work_item = decided_then_asked!(scope)

      document = question_document(work_item)

      added = %{
        "id" => "q4",
        "question" => "Which shelf?",
        "options" => [],
        "state" => "open",
        "asked" => %{"run" => run_of(work_item, "q2"), "at" => "2026-11-04T10:00:00Z"},
        "follows" => ["q1"]
      }

      {:ok, _version} =
        while_live(newest_run(work_item), fn ->
          Artifacts.push(
            {:run, newest_run(work_item)},
            reload(work_item),
            "questions",
            [Apiary.Explore.Questions.file(%{"questions" => document["questions"] ++ [added]})],
            name: "main",
            stage_id: newest_run(work_item).stage_id
          )
        end)

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))

      follows = "#{@form} .q-xp-qs .q-xp-cm-m"
      assert has_element?(view, follows, "Follows question 1")
      refute has_element?(view, "#{follows} a", "Follows question")
    end

    test "a reader on the tab lands on the work item's address once no question is left", %{
      conn: conn,
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      work_item = work_item |> reload() |> end_run!(questions_result(["Which basket?"]))

      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      assert has_element?(view, "#work-item-questions")

      # A take in again starts a take in with no question.
      {:ok, _closed} = WorkItems.close(scope, reload(work_item))

      {:ok, _again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert_patch(view, page(scope, work_item.number))
      refute has_element?(view, "#work-item-questions")
      refute has_element?(view, "#work-item-tabs-questions")
    end
  end

  # Runs `push` with the run of the queue `dispatch_run` live, as a run pushes before it
  # ends (`Apiary.Artifacts.push/5` returns `{:error, :run_ended}` for a run that ended),
  # then sets the run back to its state, end and outcome.
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
end
