defmodule Apiary.Contract.GatewayDiscoveryTest do
  @moduledoc """
  The discovery documents of a node's, a pool's and a gateway's keys against
  `configuration.schema.json` of Forager's contract at the commit in
  `.forager-contract-ref`, and the contract's gateway fixtures: a gateway's document,
  which lists no workspaces, validates as a node's does.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.ContractSchema
  alias ApiaryWeb.Contract.Configuration

  @moduletag :contract

  defp schema, do: ContractSchema.schema!(contract_dir(), "configuration.schema.json")

  defp document(scope, node) do
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)

    build_conn()
    |> signed_get(key.key_id, secret, "/.well-known/qory-configuration")
    |> json_response(200)
  end

  test "a node's, a pool's and a gateway's documents validate" do
    %{scope: scope} = sign_up_fixture()

    assert :ok = ContractSchema.validate(schema(), document(scope, node_fixture(scope)))
    assert :ok = ContractSchema.validate(schema(), document(scope, pool_fixture(scope)))

    # A gateway's lists no workspaces, at a workspace or at an organisation.
    for gateway <- [gateway_fixture(scope), organisation_gateway_fixture(scope)] do
      document = document(scope, gateway)
      assert "ng_" <> _id = document["node_id"]
      refute Map.has_key?(document, "workspaces")
      assert :ok = ContractSchema.validate(schema(), document)
    end
  end

  test "only a gateway's document may list more than one workspace" do
    two = contract_json!("configuration/gateway.json")
    assert ["ng_" <> _id, [_, _]] = [two["node_id"], two["workspaces"]]
    assert :ok = ContractSchema.validate(schema(), two)

    assert {:error, _} =
             ContractSchema.validate(schema(), %{two | "node_id" => "np_f1xt0re000000000"})
  end

  test "known-answers/discovery-gateway.json is the document this server builds for the fixture gateway" do
    known = contract_file!("known-answers/discovery-gateway.json")
    document = Jason.decode!(known)
    assert :ok = ContractSchema.validate(schema(), document)

    built =
      Configuration.encode(%{
        node_id: document["node_id"],
        workspaces: document["workspaces"],
        url: "https://qory.example",
        apiary_public_key: document["apiary_public_key"]
      })

    assert built == String.trim(known)
  end
end
