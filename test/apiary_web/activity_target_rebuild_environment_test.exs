defmodule ApiaryWeb.ActivityTargetRebuildEnvironmentTest do
  # The Activity line of `target.rebuild_environment`: its label, offered in the filter;
  # its sentence; its subject, the target by its name; and nothing of its details shown as
  # a change.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  defp entry(subject_id),
    do: %Entry{
      action: "target.rebuild_environment",
      actor_kind: :person,
      details: %{"count" => 2},
      subject_kind: "target",
      subject_id: subject_id
    }

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.sentence(:"target.rebuild_environment", entry, %{})
      )

  # The change the page shows: the first the describers give.
  defp changed(entry),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.change(:"target.rebuild_environment", %{}, %{}, entry.details)
      )

  test "the label, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"target.rebuild_environment") == "Builds asked for"
    assert Core.label(:"target.rebuild_environment", scope) == "Builds asked for"
    assert Core.offered?(scope, :"target.rebuild_environment")
  end

  test "the sentence, and the target as its subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    entry = entry(id)

    assert shown(entry) == "Asked for a build of its environment"
    assert changed(entry) == nil

    assert Core.subject(
             entry,
             :"target.rebuild_environment",
             %{targets: %{id => "acme/shop"}},
             scope,
             nil
           ) ==
             %{text: "acme/shop", mono: true, href: nil}
  end
end
