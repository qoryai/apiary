defmodule ApiaryWeb.ActivityCollectionAssignTest do
  # The Activity line of `collection.assign`: its label in the filter, its sentence by the
  # count of repositories assigned to a workspace, and its subject, the workspace's name;
  # an unassign says no more than any change.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
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

  test "an unassign, linked to no workspace, has no sentence, so the page says what it says of any change" do
    %{scope: scope} = sign_up_fixture()
    organisation_id = scope.organisation.id
    none = entry(%{"count" => 2, "workspace_id" => nil}, "organisation", organisation_id)

    assert Core.sentence(:"collection.assign", none, %{}) == nil
    assert %{text: name} = Core.subject(none, :"collection.assign", %{}, scope, nil)
    assert name == scope.organisation.name
  end
end
