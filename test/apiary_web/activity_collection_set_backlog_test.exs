defmodule ApiaryWeb.ActivityCollectionSetBacklogTest do
  # The Activity line of `collection.set_backlog`: its label in the filter, its sentence
  # when a target's Backlog was turned on or off, in the software domain's words, and its
  # subject, the target by its name.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

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
end
