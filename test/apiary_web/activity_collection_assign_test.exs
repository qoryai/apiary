defmodule ApiaryWeb.ActivityCollectionAssignTest do
  # The Activity line of `collection.assign`: its label in the filter, its sentence by the
  # count of repositories assigned to a workspace, or unassigned from theirs, and its
  # subject, the workspace's name, or the organisation's for an unassign.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

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
    assert Core.label(:"collection.assign") == "Repositories assigned"

    one = entry(%{"count" => 1, "workspace_id" => workspace_id}, "workspace", workspace_id)
    many = entry(%{"count" => 12, "workspace_id" => workspace_id}, "workspace", workspace_id)

    assert Core.sentence(:"collection.assign", one, %{}) ==
             "Assigned 1 repository to a workspace"

    assert Core.sentence(:"collection.assign", many, %{}) ==
             "Assigned 12 repositories to a workspace"

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
             "Unassigned 1 repository from its workspace"

    assert Core.sentence(:"collection.assign", many, %{}) ==
             "Unassigned 2 repositories from their workspaces"

    assert shown(one) == "Unassigned 1 repository from its workspace"
    assert shown(many) == "Unassigned 2 repositories from their workspaces"
    refute shown(many) == "Made a change"

    assert %{text: name} = Core.subject(many, :"collection.assign", %{}, scope, nil)
    assert name == scope.organisation.name
  end

  test "the assign sentence stays as it was beside the unassign one" do
    %{scope: scope} = sign_up_fixture()
    workspace_id = scope.workspace.id
    assign = entry(%{"count" => 3, "workspace_id" => workspace_id}, "workspace", workspace_id)

    assert shown(assign) == "Assigned 3 repositories to a workspace"
  end
end
