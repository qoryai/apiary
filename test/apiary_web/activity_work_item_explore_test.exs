defmodule ApiaryWeb.ActivityWorkItemExploreTest do
  # The Activity lines of what a member gives Explore: an answer to Qory's questions, a
  # review comment on its proposal, a reply to one, a send of the review comments (Run
  # with comments), a confirmation of its proposal, changed or not, and a run of Explore
  # again, by their labels in the filter and their sentences. None has a subject yet: the page a work
  # item's stable address opens is not there.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  @actions [:"work_item.answer", :"work_item.confirm", :"work_item.explore_again"]

  defp entry(action, details, subject_id),
    do: %Entry{
      action: Atom.to_string(action),
      actor_kind: :person,
      details: details,
      subject_kind: "work_item",
      subject_id: subject_id
    }

  test "the labels, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Enum.map(@actions, &Core.label/1) == [
             "Work item questions answered",
             "Work item proposal confirmed",
             "Work item explored again"
           ]

    for action <- @actions, do: assert(Core.offered?(scope, action), "#{action}")
  end

  test "the sentences, and no subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    answer = &entry(:"work_item.answer", %{"take_in" => 1, "attempt" => 1, "count" => &1}, id)

    assert Core.sentence(:"work_item.answer", answer.(1), %{}) ==
             "Answered 1 question on a work item"

    assert Core.sentence(:"work_item.answer", answer.(3), %{}) ==
             "Answered 3 questions on a work item"

    assert Core.sentence(:"work_item.answer", entry(:"work_item.answer", %{}, id), %{}) ==
             "Answered 1 question on a work item"

    comment = entry(:"work_item.answer", %{"take_in" => 1, "attempt" => 1, "comment" => true}, id)

    assert Core.sentence(:"work_item.answer", comment, %{}) ==
             "Wrote a review comment on a work item's proposal"

    # A reply has what a review comment has, and the reply's position.
    reply = %{comment | details: Map.put(comment.details, "reply", 2)}

    assert Core.sentence(:"work_item.answer", reply, %{}) ==
             "Replied to a review comment on a work item's proposal"

    # Run with comments: the count and the ids of the open review comments sent.
    sent =
      &entry(
        :"work_item.answer",
        %{"take_in" => 1, "attempt" => 1, "count" => length(&1), "review_comments" => &1},
        id
      )

    assert Core.sentence(:"work_item.answer", sent.(["c1"]), %{}) ==
             "Sent 1 review comment on a work item's proposal"

    assert Core.sentence(:"work_item.answer", sent.(["c1", "c2", "c3"]), %{}) ==
             "Sent 3 review comments on a work item's proposal"

    confirmed =
      entry(:"work_item.confirm", %{"take_in" => 1, "attempt" => 1, "changed" => []}, id)

    assert Core.sentence(:"work_item.confirm", confirmed, %{}) ==
             "Confirmed a work item's proposal"

    changed = %{confirmed | details: %{confirmed.details | "changed" => ["approach"]}}

    assert Core.sentence(:"work_item.confirm", changed, %{}) ==
             "Changed a work item's proposal and confirmed it"

    again = entry(:"work_item.explore_again", %{"take_in" => 1, "attempt" => 2}, id)

    assert Core.sentence(:"work_item.explore_again", again, %{}) ==
             "Ran Explore again on a work item"

    for action <- @actions do
      assert Core.subject(entry(action, %{}, id), action, %{}, scope, scope.workspace) == nil
    end
  end
end
