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
    @describetag needs: [:factory, :workflow_model]

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

    test "a move with no answer at its place gives none, not the question's answer" do
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
