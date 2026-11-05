defmodule ApiaryWeb.ActivityRunSubjectTest do
  # A run an Activity line names: "Run" and its number, a link to its page at its number.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer.Core

  test "a run is named by its number and links to its page" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    names = %{runs: %{id => 3}}
    entry = %Entry{subject_kind: "run", subject_id: id}

    assert %{text: "Run 3", mono: false, href: href} =
             Core.subject(entry, :"run.read", names, scope, scope.workspace)

    assert href == "/#{scope.organisation.slug}/#{scope.workspace.slug}/runs/3"

    assert %{text: "A run"} =
             Core.subject(entry, :"run.read", %{runs: %{}}, scope, scope.workspace)
  end
end
