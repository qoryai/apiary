defmodule ApiaryWeb.ActivityWorkItemCommentsTest do
  # The Activity lines of people's comments on a work item's Thread: a comment and a
  # comment's deletion, by their labels in the filter and their sentences, made by
  # `Apiary.WorkItems` and read back from the trail. Neither has a subject yet: the page a
  # work item's stable address opens is not there.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.WorkItems
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  @actions [:"work_item.comment", :"work_item.comment_delete"]

  test "the labels, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Enum.map(@actions, &Core.label/1) == [
             "Work item comment added",
             "Work item comment deleted"
           ]

    for action <- @actions, do: assert(Core.offered?(scope, action), "#{action}")
  end

  test "the sentences of the entries a comment and its deletion write, and no subject" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    {:ok, comment} = WorkItems.comment(scope, work_item, "Seen on staging")
    {:ok, _deleted} = WorkItems.delete_comment(scope, comment.public_id)

    entry = fn action ->
      Repo.one!(from e in Entry, where: e.action == ^Atom.to_string(action))
    end

    assert Core.sentence(:"work_item.comment", entry.(:"work_item.comment"), %{}) ==
             "Commented on a work item"

    assert Core.sentence(:"work_item.comment_delete", entry.(:"work_item.comment_delete"), %{}) ==
             "Deleted a comment on a work item"

    for action <- @actions do
      assert Core.subject(entry.(action), action, %{}, scope, scope.workspace) == nil
    end
  end
end
