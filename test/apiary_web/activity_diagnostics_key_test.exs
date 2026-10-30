defmodule ApiaryWeb.ActivityDiagnosticsKeyTest do
  # The Activity page's sentences of a diagnostics key's code, key and revocation, told by
  # the diagnostics node's public id, `dg_`, in the entry's details; a node's say what
  # they said before.
  use Apiary.DataCase, async: true

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer

  defp shown(action, details),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.sentence(
          action,
          %Entry{action: to_string(action), actor_kind: :person, details: details},
          %{}
        )
      )

  test "the sentences" do
    diagnostics = %{"node_id" => "dg_0000000000000000"}
    node = %{"node_id" => "nd_0000000000000000"}

    assert shown(:"access_key.create_code", diagnostics) == "Made a code for a diagnostics key"
    assert shown(:"access_key.add", diagnostics) == "Added a diagnostics key"

    assert shown(:"access_key.revoke", Map.put(diagnostics, "reason", "revoked")) ==
             "Revoked a diagnostics key"

    assert shown(:"access_key.create_code", nil) == "Made a command to connect a node"
    assert shown(:"access_key.add", node) == "Added an access key to a node"

    assert shown(:"access_key.revoke", Map.put(node, "reason", "revoked")) ==
             "Revoked an access key"
  end
end
