defmodule ApiaryWeb.ActivityDispatchReleaseTest do
  # The Activity line of `dispatch.release`: its label in the filter, offered there, its
  # sentence before the handover and after it, chosen by `handed_over` in its details,
  # its subject, the pool before the handover and the run registered after it, and the
  # starter's reason, shown nowhere.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @reason "The job could not start: a secret reason."

  defp entry(handed_over, subject_kind, subject_id),
    do: %Entry{
      action: "dispatch.release",
      actor_kind: :access_key,
      details: %{
        "dispatch_id" => "dp_0123456789abcdef",
        "step" => "explore",
        "handed_over" => handed_over,
        "waits" => true,
        "reason" => @reason
      },
      subject_kind: subject_kind,
      subject_id: subject_id
    }

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(:"dispatch.release", entry, %{}))

  # The change the page shows: the first the describers give.
  defp changed(entry),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.change(:"dispatch.release", %{}, %{}, entry.details)
      )

  test "the label, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"dispatch.release") == "Runs given back"
    assert Core.label(:"dispatch.release", scope) == "Runs given back"
    assert Core.offered?(scope, :"dispatch.release")
  end

  test "before the handover: the sentence, and the pool as its subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    entry = entry(false, "node", id)

    assert shown(entry) == "Gave a claimed run back"
    assert changed(entry) == nil

    assert %{text: "build-pool"} =
             Core.subject(
               entry,
               :"dispatch.release",
               %{nodes: %{id => "build-pool"}},
               scope,
               scope.workspace
             )
  end

  test "after the handover: the sentence, and the run as its subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()
    public_id = "rn_0123456789abcdef"
    entry = entry(true, "run", id)

    assert shown(entry) == "Gave back a run handed over to its machine"
    assert changed(entry) == nil

    assert %{text: "rn_01234567", mono: true, href: href} =
             Core.subject(
               entry,
               :"dispatch.release",
               %{runs: %{id => public_id}},
               scope,
               scope.workspace
             )

    assert href == "/#{scope.organisation.slug}/#{scope.workspace.slug}/runs/#{public_id}"
  end

  test "the reason is in no sentence, subject or change" do
    %{scope: scope} = sign_up_fixture()

    for {handed_over, kind} <- [{false, "node"}, {true, "run"}] do
      entry = entry(handed_over, kind, Ecto.UUID.generate())
      names = %{nodes: %{}, runs: %{}}

      for shown <- [
            shown(entry),
            Core.subject(entry, :"dispatch.release", names, scope, scope.workspace),
            changed(entry)
          ] do
        refute inspect(shown) =~ "secret reason"
      end
    end
  end
end
