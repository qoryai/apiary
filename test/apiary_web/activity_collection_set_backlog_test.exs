defmodule ApiaryWeb.ActivityCollectionSetBacklogTest do
  # The Activity line of `collection.set_backlog`: its label in the filter, its sentence
  # when a target's Backlog was turned on or off, in the software domain's words, and its
  # subject, the target by its name. Both name the items by their sources' word, else
  # tickets.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Audit, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Targets
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  defp entry(details, target_id),
    do: %Entry{
      action: "collection.set_backlog",
      actor_kind: :person,
      details: details,
      subject_kind: "target",
      subject_id: target_id
    }

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.sentence(:"collection.set_backlog", entry, %{})
      )

  test "the label, offered in the filter beside the assign" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"collection.set_backlog") ==
             "Taking tickets into the Backlog turned on or off"

    assert Core.offered?(scope, :"collection.set_backlog")
  end

  test "the sentence, turned on or off, and the target as its subject" do
    %{scope: scope} = sign_up_fixture()
    started_run(scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
    target = Targets.get(scope, "code.example.com", "acme/shop")

    on = entry(%{"backlog" => true, "count" => 1}, target.id)
    off = entry(%{"backlog" => false, "count" => 1}, target.id)

    assert shown(on) == "Turned on taking a repository's tickets into the Backlog"
    assert shown(off) == "Turned off taking a repository's tickets into the Backlog"

    names = %{targets: %{target.id => "acme/shop"}}

    assert Core.subject(off, :"collection.set_backlog", names, scope, nil) ==
             %{text: "acme/shop", mono: true, href: nil}
  end

  describe "the words of the sources' items" do
    @describetag needs: :factory

    test "the label: the organisation's sources' shared word, else tickets" do
      %{scope: scope} = sign_up_fixture()

      assert Core.label(:"collection.set_backlog", scope) ==
               "Taking tickets into the Backlog turned on or off"

      connection = ticket_connection_fixture(scope)
      name(connection.adapter_id, "story", "stories")

      assert Core.label(:"collection.set_backlog", scope) ==
               "Taking stories into the Backlog turned on or off"

      # Another action's words are its label's.
      assert Core.label(:"collection.assign", scope) == Core.label(:"collection.assign")
    end

    test "the sentence: the target's sources' word, from the names the page reads" do
      %{scope: scope} = sign_up_fixture()
      started_run(scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
      target = Targets.get(scope, "code.example.com", "acme/shop")
      connection = ticket_connection_fixture(scope)
      name(connection.adapter_id, "story", "stories")

      source_collection_fixture(scope, connection, %{
        target_system: "code.example.com",
        target_path: "acme/shop"
      })

      on = entry(%{"backlog" => true, "count" => 1}, target.id)
      off = entry(%{"backlog" => false, "count" => 1}, target.id)
      names = Audit.names(scope, [on, off])
      assert names.item_nouns == %{target.id => %{one: "story", other: "stories"}}

      assert Core.sentence(:"collection.set_backlog", on, names) ==
               "Turned on taking a repository's stories into the Backlog"

      assert Core.sentence(:"collection.set_backlog", off, names) ==
               "Turned off taking a repository's stories into the Backlog"

      # Only the Backlog switch's entries are looked up.
      assert Audit.names(scope, [%{on | action: "collection.assign"}]).item_nouns == %{}
    end
  end

  defp name(adapter_id, one, other) do
    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter_id),
      set: [item_noun_one: one, item_noun_other: other]
    )
  end
end
