defmodule ApiaryWeb.ActivityDispatchMachineEndTest do
  # The Activity line of `dispatch.machine_end`: its label, not offered in the filter, its
  # sentence for each state in its details, and its subject, the pool.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  defp entry(state, id),
    do: %Entry{
      action: "dispatch.machine_end",
      actor_kind: :access_key,
      details: %{"dispatch_id" => "dp_0123456789abcdef", "state" => state},
      subject_kind: "node",
      subject_id: id
    }

  # The sentence the page shows: the first the describers give.
  defp shown(entry),
    do:
      Enum.find_value(Describer.describers(), & &1.sentence(:"dispatch.machine_end", entry, %{}))

  test "the label, not offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"dispatch.machine_end") == "Machine removal reports"
    assert Core.label(:"dispatch.machine_end", scope) == "Machine removal reports"
    refute Core.offered?(scope, :"dispatch.machine_end")
  end

  test "the sentence of each state, and the pool as its subject" do
    %{scope: scope} = sign_up_fixture()
    id = Ecto.UUID.generate()

    for {state, words} <- [
          {"deleting", "Reported that the removal of a run's machine was requested"},
          {"gone", "Reported that a run's machine was removed"},
          {"delete_failed", "Reported that the removal of a run's machine failed"}
        ] do
      entry = entry(state, id)
      assert shown(entry) == words

      assert %{text: "build-pool"} =
               Core.subject(
                 entry,
                 :"dispatch.machine_end",
                 %{nodes: %{id => "build-pool"}},
                 scope,
                 scope.workspace
               )
    end
  end
end
