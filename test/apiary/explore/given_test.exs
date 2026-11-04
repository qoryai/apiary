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
end
