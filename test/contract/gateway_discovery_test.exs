defmodule Apiary.Contract.GatewayDiscoveryTest do
  @moduledoc """
  The discovery documents of a node's, a pool's and a gateway's keys against
  `configuration.schema.json` of Forager's contract at the commit in
  `.forager-contract-ref`.

  A node's and a pool's documents validate. The contract at the pin knows no gateway yet:
  its schema takes a node id of `nd_` or `np_` alone. So the gateway's document is held to
  fail that schema for its `ng_` node id and nothing else; once the pin moves to a contract
  that knows a gateway, the assertion below fails, and the gateway's document is
  validated as the others are.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.ContractSchema

  @moduletag :contract

  defp schema, do: ContractSchema.schema!(contract_dir(), "configuration.schema.json")

  defp document(scope, node) do
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)

    build_conn()
    |> signed_get(key.key_id, secret, "/.well-known/qory-configuration")
    |> json_response(200)
  end

  test "a node's and a pool's documents validate; a gateway's fails for its ng_ id alone" do
    %{scope: scope} = sign_up_fixture()

    assert :ok = ContractSchema.validate(schema(), document(scope, node_fixture(scope)))
    assert :ok = ContractSchema.validate(schema(), document(scope, pool_fixture(scope)))

    gateway = document(scope, gateway_fixture(scope))
    assert "ng_" <> id = gateway["node_id"]

    # To validate as the others do once the pinned contract knows a gateway's id.
    assert {:error, _not_yet} = ContractSchema.validate(schema(), gateway)
    assert :ok = ContractSchema.validate(schema(), %{gateway | "node_id" => "np_" <> id})
  end
end
