defmodule Apiary.Explore.GivenTest do
  # What members gave Explore on a work item (`Apiary.Explore.Given`): read from the work
  # item, or from the events and the documents a caller already read.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Explore.{Given, Questions, ReviewComments}
  alias Apiary.WorkItems.{Explore, WorkItem}

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp document({_version, document}), do: document

  describe "from_events/3" do
    @describetag needs: :factory

    test "gives what from_events/2 gives, from the documents the caller read" do
      %{scope: scope} = sign_up_fixture()

      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(understood_result(%{"message" => "## What this is"}))

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Offer a replacement first.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
      work_item = end_run!(work_item, questions_result(["Which refund?"]))
      {:ok, _} = WorkItems.reply(scope, work_item, 2, "c1", "And name the rule.")
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The full one."})

      work_item = reload(work_item)
      events = Explore.events(work_item.id)
      questions = document(Questions.newest(work_item))
      comments = document(ReviewComments.newest(work_item))

      given = Given.from_events(events, questions, comments)
      assert Enum.map(given, & &1.kind) == [:comment, :reply, :answer]
      assert given == Given.from_events(work_item, events)
      assert given == Given.all(work_item)
    end
  end

  describe "answers through the moves and Artifacts.push/5" do
    @describetag needs: :factory

    # Pushes, as the run of the queue `run`, whose registered run is `registered`, the
    # newest questions with `change` applied to each and the questions `added` after them,
    # with `Apiary.Artifacts.push/5`, the call the run API makes, which checks the version
    # (`Questions.check_run/3`).
    defp push_questions!(run, registered, change, added \\ []) do
      work_item = reload(%{id: run.work_item_id})
      {_version, document} = Questions.newest(work_item)
      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      added =
        for {text, n} <- Enum.with_index(added, length(document["questions"]) + 1) do
          %{
            "id" => "q#{n}",
            "question" => text,
            "options" => [],
            "state" => "open",
            "asked" => %{"run" => registered.number, "at" => at}
          }
        end

      questions = Enum.map(document["questions"], &change.(&1, registered.number, at))

      assert {:ok, _version} =
               Apiary.Artifacts.push(
                 {:run, run},
                 work_item,
                 "questions",
                 [Questions.file(%{"questions" => questions ++ added})],
                 name: "main",
                 stage_id: run.stage_id
               )
    end

    # A run's change: the answered questions `ids` reopened, each answer moved, unchanged,
    # to the end of the question's history.
    defp reopen(ids) do
      fn
        %{"id" => id, "answer" => answer} = question, run, at ->
          if id in ids do
            reopened = Map.put(answer, "reopened", %{"run" => run, "at" => at})

            question
            |> Map.delete("answer")
            |> Map.put("state", "open")
            |> Map.put("history", (question["history"] || []) ++ [reopened])
          else
            question
          end

        question, _run, _at ->
          question
      end
    end

    # A run's change: the open questions `ids` withdrawn.
    defp withdraw(ids) do
      fn
        %{"id" => id, "state" => "open"} = question, _run, _at ->
          if id in ids, do: Map.put(question, "state", "withdrawn"), else: question

        question, _run, _at ->
          question
      end
    end

    test "pairs each answer with its move, by id, across reopens, withdrawals and take ins" do
      %{scope: scope} = sign_up_fixture()
      %{scope: member} = member_fixture(scope)
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      # Take in 1. Run 1 asks q1, q2 and q3. The owner answers q1 and q2 by id in one
      # move; q3 stays open.
      work_item =
        work_item
        |> reload()
        |> end_run!(questions_result(["Which basket?", "Which sale?", "Which refund?"]))

      {:ok, _} =
        WorkItems.answer(scope, work_item, 1, [
          %{"id" => "q1", "note" => "The main one."},
          %{"id" => "q2", "note" => "The spring sale."}
        ])

      # Run 2 reopens q1 and q2, and the member answers q1 again.
      work_item = end_run!(reload(work_item), &push_questions!(&1, &2, reopen(["q1", "q2"])))

      {:ok, _} =
        WorkItems.answer(member, work_item, 2, [%{"id" => "q1", "note" => "The other one."}])

      # Run 3 withdraws q2, whose earlier answer is in its history, and q3, never answered.
      work_item = end_run!(reload(work_item), &push_questions!(&1, &2, withdraw(["q2", "q3"])))

      # Take in 2. Its run 1 reopens q1 again and asks q4, and the owner answers both.
      {:ok, _closed} = WorkItems.close(scope, work_item)
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      work_item =
        end_run!(reload(again), &push_questions!(&1, &2, reopen(["q1"]), ["Which shop?"]))

      {:ok, _} =
        WorkItems.answer(scope, work_item, 1, [
          %{"id" => "q1", "note" => "The third one."},
          %{"id" => "q4", "note" => "The north shop."}
        ])

      work_item = reload(work_item)
      {_version, document} = Questions.newest(work_item)

      assert [
               %{"id" => "q1", "state" => "answered", "history" => [_, _]},
               %{"id" => "q2", "state" => "withdrawn", "history" => [_]},
               %{"id" => "q3", "state" => "withdrawn"},
               %{"id" => "q4", "state" => "answered"}
             ] = document["questions"]

      assert [first, second, third] =
               for(%{kind: :answered} = event <- Explore.events(work_item.id), do: event)

      {owner_id, member_id} = {scope.user.id, member.user.id}

      # Each entry: the move's event, its member, its take in and run, the question, the
      # answer. The withdrawn q2 keeps its answer; q3, never answered, has none.
      assert for(
               entry <- Given.all(work_item),
               do:
                 {entry.event_id, entry.by_id, entry.take_in, entry.attempt, entry.id, entry.text}
             ) == [
               {first.id, owner_id, 1, 1, "q1", "The main one."},
               {first.id, owner_id, 1, 1, "q2", "The spring sale."},
               {second.id, member_id, 1, 2, "q1", "The other one."},
               {third.id, owner_id, 2, 1, "q1", "The third one."},
               {third.id, owner_id, 2, 1, "q4", "The north shop."}
             ]
    end
  end

  describe "an answer" do
    @at "2026-11-04T10:00:00Z"

    defp given(note, run \\ nil) do
      answer = %{"option" => nil, "note" => note, "by" => %{"name" => "ann"}, "at" => @at}
      if run, do: Map.put(answer, "reopened", %{"run" => run, "at" => @at}), else: answer
    end

    # A move that answered the question q1, in the second of `@at`, `micro` microseconds
    # into it.
    defp answered(micro) do
      {:ok, at, 0} = DateTime.from_iso8601(@at)

      %{
        kind: :answered,
        id: Ecto.UUID.generate(),
        actor_id: Ecto.UUID.generate(),
        at: DateTime.add(at, micro, :microsecond),
        data: %{"take_in" => 1, "attempt" => micro, "questions" => ["q1"]}
      }
    end

    defp questions(question),
      do: %{
        "questions" => [
          Map.merge(
            %{"id" => "q1", "question" => "Which basket?", "options" => []},
            question
          )
        ]
      }

    test "two answers to one question in the same second each pair with their move" do
      questions =
        questions(%{
          "state" => "answered",
          "history" => [given("The main one.", 2)],
          "answer" => given("The other one.")
        })

      [first, second] = events = [answered(1), answered(2)]

      assert [
               %{event_id: first_id, text: "The main one.", custom: true},
               %{event_id: second_id, text: "The other one."}
             ] = Given.from_events(events, questions, nil)

      assert {first_id, second_id} == {first.id, second.id}
    end

    # A move adds one answer to each question it answers, and a run's version keeps them
    # all (`Questions.check_run/3`), so no writer leaves a question with fewer answers than
    # the moves that answered it. The documents here are built by hand to test that case,
    # which `Given` handles as a defensive branch.
    test "a move with no answer at its place has no entry, not the question's answer" do
      reopened =
        questions(%{
          "state" => "open",
          "history" => [given("The main one.", 2), given("The other one.", 3)]
        })

      events = [answered(1), answered(2), answered(3)]

      assert Enum.map(Given.from_events(events, reopened, nil), & &1.text) ==
               ["The main one.", "The other one."]

      once = questions(%{"state" => "answered", "answer" => given("The main one.")})

      assert [%{attempt: 1, text: "The main one."}] =
               Given.from_events(events, once, nil)
    end
  end
end
