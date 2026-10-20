defmodule ApiaryWeb.ActivityCollectionSetBacklogTest do
  # The Activity line of `collection.set_backlog`: its label in the filter, its sentence
  # when a target's Backlog was turned on or off, in the software domain's words, and its
  # subject, the target by its name. Both name the items by their sources' word, else
  # tickets. And when a collection's Backlog was turned on or off by the collection: its
  # sentence, naming the title the entry recorded, and its subject, the collection by its
  # title now, or the source's word once its row is gone, in the words of the source
  # behind the connection the entry names.
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

  describe "a collection's Backlog, turned by the collection" do
    @describetag needs: :factory

    # A collection "Shop board", with no target, assigned to the scope's workspace, and
    # the entry of its Backlog turned `on`: on again after it was turned off.
    defp pressed(on) do
      %{scope: scope} = sign_up_fixture()
      connection = ticket_connection_fixture(scope)
      collection = source_collection_fixture(scope, connection, %{title: "Shop board"})

      if on do
        {:ok, 1} =
          Apiary.Adapters.Collections.set_collection_backlog(
            scope,
            connection,
            collection.id,
            false
          )
      end

      {:ok, 1} =
        Apiary.Adapters.Collections.set_collection_backlog(scope, connection, collection.id, on)

      entry =
        Repo.one!(
          from e in Entry,
            where: e.action == "collection.set_backlog",
            order_by: [desc: e.inserted_at, desc: e.id],
            limit: 1
        )

      %{scope: scope, connection: connection, collection: collection, entry: entry}
    end

    test "the sentence names the title it had, collection where the source names none" do
      %{scope: scope, entry: off} = pressed(false)
      names = Audit.names(scope, [off])

      assert Core.sentence(:"collection.set_backlog", off, names) ==
               "Turned off taking tickets into the Backlog from collection Shop board"

      on = %{off | details: %{off.details | "backlog" => true}}

      assert Core.sentence(:"collection.set_backlog", on, names) ==
               "Turned on taking tickets into the Backlog from collection Shop board"

      # The page asks the edition's describer first.
      assert shown(off) ==
               "Turned off taking tickets into the Backlog from collection Shop board"
    end

    test "the sentence names the title as a page shows an external system's text" do
      %{scope: scope, entry: off} = pressed(false)
      # A bidirectional override, a zero-width space and a control character.
      sent = %{off | details: %{off.details | "name" => "\u202EShop board\u200B\a"}}

      assert Core.sentence(:"collection.set_backlog", sent, Audit.names(scope, [sent])) ==
               "Turned off taking tickets into the Backlog from collection Shop board\uFFFD"
    end

    test "the sentence and the subject in the source's words, from its connection" do
      %{scope: scope, connection: connection, collection: collection, entry: on} = pressed(true)
      name(connection.adapter_id, "story", "stories")
      collection_name(connection.adapter_id, "project", "projects")

      names = Audit.names(scope, [on])
      assert names.item_nouns == %{collection.id => %{one: "story", other: "stories"}}
      assert names.collection_nouns == %{collection.id => %{one: "project", other: "projects"}}

      assert Core.sentence(:"collection.set_backlog", on, names) ==
               "Turned on taking stories into the Backlog from project Shop board"

      assert Core.subject(on, :"collection.set_backlog", names, scope, nil) ==
               %{text: "Shop board", mono: true, href: nil}

      # Renamed at its source: the subject is the title now, the sentence the title then.
      Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
        set: [title: "Shop roadmap"]
      )

      names = Audit.names(scope, [on])

      assert Core.subject(on, :"collection.set_backlog", names, scope, nil) ==
               %{text: "Shop roadmap", mono: true, href: nil}

      assert Core.sentence(:"collection.set_backlog", on, names) ==
               "Turned on taking stories into the Backlog from project Shop board"

      # Its row gone: the source's word, from the connection the entry names.
      Repo.delete!(collection)
      names = Audit.names(scope, [on])
      assert names.collections == %{}

      assert Core.subject(on, :"collection.set_backlog", names, scope, nil) ==
               %{text: "Deleted project", mono: false, href: nil}

      assert Core.sentence(:"collection.set_backlog", on, names) ==
               "Turned on taking stories into the Backlog from project Shop board"
    end

    test "with its row gone and a source that names none, collection" do
      %{scope: scope, collection: collection, entry: on} = pressed(true)
      Repo.delete!(collection)

      assert Core.subject(on, :"collection.set_backlog", Audit.names(scope, [on]), scope, nil) ==
               %{text: "Deleted collection", mono: false, href: nil}

      # An entry naming no connection it can find has no nouns.
      lost = %{on | details: %{on.details | "connection_id" => "ac_0000000000000000"}}
      names = Audit.names(scope, [lost])
      assert {names.item_nouns, names.collection_nouns} == {%{}, %{}}
    end

    test "a target's entry keeps its sentence, beside the collection's" do
      %{scope: scope, entry: on} = pressed(true)
      target_entry = %{on | subject_kind: "target", details: %{"backlog" => true, "count" => 1}}

      assert Core.sentence(:"collection.set_backlog", target_entry, Audit.names(scope, [])) ==
               "Turned on taking a repository's tickets into the Backlog"
    end
  end

  defp collection_name(adapter_id, one, other) do
    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter_id),
      set: [collection_noun_one: one, collection_noun_other: other]
    )
  end

  defp name(adapter_id, one, other) do
    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter_id),
      set: [item_noun_one: one, item_noun_other: other]
    )
  end
end
