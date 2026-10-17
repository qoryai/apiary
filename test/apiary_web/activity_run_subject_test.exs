defmodule ApiaryWeb.ActivityRunSubjectTest do
  # A run an Activity line names: by `rn_` and the first eight characters of its id, a link
  # to its page at its `rn_` id.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer.Core

  test "a run is named by its short `rn_` id and links to its page" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    public_id = "rn_0123456789abcdef"
    names = %{runs: %{id => public_id}}
    entry = %Entry{subject_kind: "run", subject_id: id}

    assert %{text: "rn_01234567", mono: true, href: href} =
             Core.subject(entry, :"run.read", names, scope, scope.workspace)

    assert href == "/#{scope.organisation.slug}/#{scope.workspace.slug}/runs/#{public_id}"

    assert %{text: "A run"} =
             Core.subject(entry, :"run.read", %{runs: %{}}, scope, scope.workspace)
  end
end
