defmodule ApiaryWeb.ActivityDispatchPrebuiltTest do
  # The Activity line of `dispatch.prebuilt`: its label in the filter, offered there, its
  # sentence, its subject, the run registered for the prebuild, and nothing of its details
  # shown as a change.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  defp entry(subject_id),
    do: %Entry{
      action: "dispatch.prebuilt",
      actor_kind: :access_key,
      details: %{
        "dispatch_id" => "dp_0123456789abcdef",
        "size" => 734_003_200,
        "commit" => "9c1e4a7b",
        "environment_ref" => "env-1"
      },
      subject_kind: "run",
      subject_id: subject_id
    }

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(:"dispatch.prebuilt", entry, %{}))

  # The change the page shows: the first the describers give.
  defp changed(entry),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.change(:"dispatch.prebuilt", %{}, %{}, entry.details)
      )

  test "the label, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"dispatch.prebuilt") == "Images recorded"
    assert Core.label(:"dispatch.prebuilt", scope) == "Images recorded"
    assert Core.offered?(scope, :"dispatch.prebuilt")
  end

  test "the sentence, and the run as its subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    public_id = "rn_0123456789abcdef"
    entry = entry(id)

    assert shown(entry) == "Recorded the image a prebuild built"
    assert changed(entry) == nil

    assert %{text: "rn_01234567", mono: true, href: href} =
             Core.subject(
               entry,
               :"dispatch.prebuilt",
               %{runs: %{id => public_id}},
               scope,
               scope.workspace
             )

    assert href == "/#{scope.organisation.slug}/#{scope.workspace.slug}/runs/#{public_id}"
  end
end
