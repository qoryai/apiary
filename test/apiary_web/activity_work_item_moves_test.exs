defmodule ApiaryWeb.ActivityWorkItemMovesTest do
  # The Activity lines of what a person does to the work items: a take in, a take in
  # again, an undo, a decline and a close, by their labels in the filter and their
  # sentences. A take in names the items of the work item's source, else tickets; a take
  # in of a test is a test run. None has a subject yet: the page a work item's stable
  # address opens is not there.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Audit, Repo, WorkItems}
  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  @moves [:"work_item.take_in", :"work_item.undo", :"work_item.decline", :"work_item.close"]

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

    assert Enum.map(@moves, &Core.label/1) == [
             "Work item taken in",
             "Take in undone",
             "Work item declined",
             "Work item closed"
           ]

    for action <- @moves, do: assert(Core.offered?(scope, action), "#{action}")
  end

  test "the sentences, and no subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()

    assert Core.sentence(
             :"work_item.take_in",
             entry(:"work_item.take_in", %{"take_in" => 1}, id),
             %{}
           ) ==
             "Took in one of the Backlog's tickets as a work item"

    again = entry(:"work_item.take_in", %{"again" => true, "take_in" => 2}, id)
    assert Core.sentence(:"work_item.take_in", again, %{}) == "Took a work item in again"

    test = entry(:"work_item.take_in", %{"take_in" => 1, "test" => true}, id)
    assert Core.sentence(:"work_item.take_in", test, %{}) == "Started a test run"

    assert Core.sentence(:"work_item.undo", entry(:"work_item.undo", %{"take_in" => 1}, id), %{}) ==
             "Undid a take in, before a run started"

    assert Core.sentence(:"work_item.decline", entry(:"work_item.decline", %{}, id), %{}) ==
             "Declined a work item"

    assert Core.sentence(:"work_item.close", entry(:"work_item.close", %{}, id), %{}) ==
             "Closed a work item"

    for action <- @moves do
      assert Core.subject(entry(action, %{}, id), action, %{}, scope, scope.workspace) == nil
    end
  end

  test "a take in names the items of the work item's source, from the names the page reads" do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)

    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^connection.adapter_id),
      set: [item_noun_one: "story", item_noun_other: "stories"]
    )

    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    [taken_in] = Repo.all(from e in Entry, where: e.action == "work_item.take_in")

    names = Audit.names(scope, [taken_in])
    assert names.item_nouns == %{work_item.id => %{one: "story", other: "stories"}}

    assert Core.sentence(:"work_item.take_in", taken_in, names) ==
             "Took in one of the Backlog's stories as a work item"

    # Only a take in's entries are looked up.
    assert Audit.names(scope, [%{taken_in | action: "work_item.close"}]).item_nouns == %{}
  end

  test "a take in of a test is a test run, with no items of a source" do
    %{scope: scope} = sign_up_fixture()
    {:ok, _work_item} = WorkItems.take_in_test(scope, "Hello! Where are you running?")
    [taken_in] = Repo.all(from e in Entry, where: e.action == "work_item.take_in")

    names = Audit.names(scope, [taken_in])
    assert names.item_nouns == %{}
    assert Core.sentence(:"work_item.take_in", taken_in, names) == "Started a test run"
  end
end
