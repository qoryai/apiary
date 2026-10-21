defmodule ApiaryWeb.ActivityCollectionAssignTest do
  # The Activity line of `collection.assign`: its label in the filter, its sentence by the
  # count of collections assigned to a workspace, or unassigned from theirs, and its
  # subject, the workspace's name, or the organisation's for an unassign. Both name the
  # collections by their sources' word, else collections.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Audit, Repo}
  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  defp entry(details, subject_kind, subject_id),
    do: %Entry{
      action: "collection.assign",
      actor_kind: :person,
      details: details,
      subject_kind: subject_kind,
      subject_id: subject_id
    }

  test "the label, the sentence by the count, and the workspace as its subject" do
    %{scope: scope} = sign_up_fixture()
    workspace_id = scope.workspace.id
    assert Core.label(:"collection.assign") == "Assigned collections"

    one = entry(%{"count" => 1, "workspace_id" => workspace_id}, "workspace", workspace_id)
    many = entry(%{"count" => 12, "workspace_id" => workspace_id}, "workspace", workspace_id)

    assert Core.sentence(:"collection.assign", one, %{}) ==
             "Assigned 1 collection to a workspace"

    assert Core.sentence(:"collection.assign", many, %{}) ==
             "Assigned 12 collections to a workspace"

    names = %{workspaces: %{workspace_id => scope.workspace.name}}

    assert %{text: name} =
             Core.subject(many, :"collection.assign", names, scope, nil)

    assert name == scope.workspace.name
  end

  # The sentence the page shows: the first the describers give, the edition's first, then
  # the core's. The page says "Made a change" only when none gives one.
  defp shown(entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(:"collection.assign", entry, %{}))

  test "an unassign, linked to no workspace, says how many were unassigned, and names the organisation" do
    %{scope: scope} = sign_up_fixture()
    organisation_id = scope.organisation.id
    one = entry(%{"count" => 1, "workspace_id" => nil}, "organisation", organisation_id)
    many = entry(%{"count" => 2, "workspace_id" => nil}, "organisation", organisation_id)

    assert Core.sentence(:"collection.assign", one, %{}) ==
             "Unassigned 1 collection from its workspace"

    assert Core.sentence(:"collection.assign", many, %{}) ==
             "Unassigned 2 collections from their workspaces"

    assert shown(one) == "Unassigned 1 collection from its workspace"
    assert shown(many) == "Unassigned 2 collections from their workspaces"
    refute shown(many) == "Made a change"

    assert %{text: name} = Core.subject(many, :"collection.assign", %{}, scope, nil)
    assert name == scope.organisation.name
  end

  test "the assign sentence stays as it was beside the unassign one" do
    %{scope: scope} = sign_up_fixture()
    workspace_id = scope.workspace.id
    assign = entry(%{"count" => 3, "workspace_id" => workspace_id}, "workspace", workspace_id)

    assert shown(assign) == "Assigned 3 collections to a workspace"
  end

  describe "the words of the sources' collections" do
    @describetag needs: :factory

    test "the label: the organisation's sources' shared word, else collections" do
      %{scope: scope} = sign_up_fixture()
      assert Core.label(:"collection.assign", scope) == "Assigned collections"

      connection = ticket_connection_fixture(scope)
      assert Core.label(:"collection.assign", scope) == "Assigned collections"

      collection_name(connection.adapter_id, "project", "projects")
      assert Core.label(:"collection.assign", scope) == "Assigned projects"
    end

    test "the sentence: the word of the source behind the connection the entry names" do
      %{scope: scope} = sign_up_fixture()
      connection = ticket_connection_fixture(scope)
      collection_name(connection.adapter_id, "project", "projects")
      workspace_id = scope.workspace.id
      organisation_id = scope.organisation.id

      assign = fn count ->
        entry(
          %{
            "count" => count,
            "connection_id" => connection.public_id,
            "workspace_id" => workspace_id
          },
          "workspace",
          workspace_id
        )
      end

      unassign = fn count ->
        entry(
          %{"count" => count, "connection_id" => connection.public_id, "workspace_id" => nil},
          "organisation",
          organisation_id
        )
      end

      entries = [assign.(1), assign.(3), unassign.(1), unassign.(2)]
      names = Audit.names(scope, entries)

      assert names.connection_collection_nouns ==
               %{connection.public_id => %{one: "project", other: "projects"}}

      assert for(entry <- entries, do: Core.sentence(:"collection.assign", entry, names)) == [
               "Assigned 1 project to a workspace",
               "Assigned 3 projects to a workspace",
               "Unassigned 1 project from its workspace",
               "Unassigned 2 projects from their workspaces"
             ]

      # A connection it cannot find, or none: collections.
      lost = %{
        assign.(3)
        | details: %{assign.(3).details | "connection_id" => "ac_0000000000000000"}
      }

      none = %{assign.(1) | details: Map.delete(assign.(1).details, "connection_id")}
      names = Audit.names(scope, [lost, none])
      assert names.connection_collection_nouns == %{}

      assert Core.sentence(:"collection.assign", lost, names) ==
               "Assigned 3 collections to a workspace"

      assert Core.sentence(:"collection.assign", none, names) ==
               "Assigned 1 collection to a workspace"
    end

    test "a source that names none: collection and collections" do
      %{scope: scope} = sign_up_fixture()
      connection = ticket_connection_fixture(scope)
      organisation_id = scope.organisation.id

      unassign =
        entry(
          %{"count" => 2, "connection_id" => connection.public_id, "workspace_id" => nil},
          "organisation",
          organisation_id
        )

      names = Audit.names(scope, [unassign])
      assert names.connection_collection_nouns == %{}

      assert Core.sentence(:"collection.assign", unassign, names) ==
               "Unassigned 2 collections from their workspaces"
    end
  end

  defp collection_name(adapter_id, one, other) do
    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter_id),
      set: [collection_noun_one: one, collection_noun_other: other]
    )
  end
end
