defmodule ApiaryWeb.ActivityDispatchHandoverTest do
  # The Activity line of `dispatch.handover`, an action Qory Apiary no longer takes, for
  # the entries written while it did: its label, its sentence, and its subject, the run
  # registered, by its short `rn_` id and a link to its page.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  defp entry(run_id),
    do: %Entry{
      action: "dispatch.handover",
      actor_kind: :access_key,
      details: %{"dispatch_id" => "dp_0123456789abcdef", "step" => "build"},
      subject_kind: "run",
      subject_id: run_id
    }

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(:"dispatch.handover", entry, %{}))

  test "the label" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"dispatch.handover") == "Runs handed over"
    assert Core.label(:"dispatch.handover", scope) == "Runs handed over"
  end

  test "the sentence, and the run as its subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    public_id = "rn_0123456789abcdef"
    entry = entry(id)

    assert shown(entry) == "Handed a claimed run over to the machine that runs it"
    refute shown(entry) == "Made a change"

    assert %{text: "rn_01234567", mono: true, href: href} =
             Core.subject(
               entry,
               :"dispatch.handover",
               %{runs: %{id => public_id}},
               scope,
               scope.workspace
             )

    assert href == "/#{scope.organisation.slug}/#{scope.workspace.slug}/runs/#{public_id}"

    assert %{text: "A run"} =
             Core.subject(entry, :"dispatch.handover", %{runs: %{}}, scope, scope.workspace)
  end
end
