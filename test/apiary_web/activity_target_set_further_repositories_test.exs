defmodule ApiaryWeb.ActivityTargetSetFurtherRepositoriesTest do
  # The Activity line of `target.set_further_repositories`: its label, offered in the
  # filter; its sentence, the list as it is after the change, or that its runs read no
  # other, in the software domain's words, read from the entry the change wrote; and its
  # subject, the target by its name.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Targets
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.sentence(:"target.set_further_repositories", entry, %{})
      )

  defp last_entry(target) do
    Repo.one!(
      from e in Entry,
        where: e.action == "target.set_further_repositories" and e.subject_id == ^target.id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  test "the label, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"target.set_further_repositories") == "Also read"
    assert Core.offered?(scope, :"target.set_further_repositories")
  end

  test "the sentence names the list after the change, or that its runs read no other" do
    %{scope: scope} = sign_up_fixture()
    started_run(scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
    target = Targets.get(scope, "code.example.com", "acme/shop")

    {:ok, target} = Targets.set_further_repositories(scope, target, "acme/docs\nacme/api")
    assert shown(last_entry(target)) == "Changed what its runs read: acme/docs, acme/api"

    {:ok, target} = Targets.set_further_repositories(scope, target, "")
    assert shown(last_entry(target)) == "Set its runs to read no other repository"

    names = %{targets: %{target.id => "acme/shop"}}

    assert Core.subject(last_entry(target), :"target.set_further_repositories", names, scope, nil) ==
             %{text: "acme/shop", mono: true, href: nil}
  end
end
