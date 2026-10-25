defmodule ApiaryWeb.ActivityGrantEndTest do
  # The Activity line of an adapter's key ending a grant (`adapter.end_grant`): its label
  # in the filter, offered there, and its sentence.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  test "the label of a grant end, offered in the filter, and its sentence" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"adapter.end_grant") == "Ended a grant"
    assert Core.label(:"adapter.end_grant", scope) == "Ended a grant"
    assert Core.offered?(scope, :"adapter.end_grant")

    entry = %Entry{
      action: "adapter.end_grant",
      actor_kind: :access_key,
      details: %{
        "connection_id" => "ac_0123456789abcdef",
        "grant_id" => "ag_0123456789abcdef",
        "collections" => 2
      }
    }

    assert Enum.find_value(
             Describer.describers(),
             & &1.sentence(:"adapter.end_grant", entry, %{})
           ) == "Ended a grant"
  end
end
