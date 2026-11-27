defmodule Apiary.Adapters.CredentialScopeTest do
  # How far one credential of an adapter reaches, as its description's source role says
  # (`credential_scope`, `Apiary.Nodes.Node.source_role_changeset/2`), held by the
  # database to the contract's two values, on adapters alone.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [ticket_connection_fixture: 1]

  alias Apiary.Integrations.Description
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  @moduletag needs: :factory

  @descriptions Path.expand("../../fixtures/integration-contract", __DIR__)

  defp described(adapter, scope) do
    document =
      @descriptions
      |> Path.join("example-tracker.json")
      |> File.read!()
      |> Jason.decode!()

    document =
      if scope,
        do: put_in(document, ["roles", "source", "credential_scope"], scope),
        else: document

    {:ok, description} = document |> Jason.encode!() |> Description.parse()
    adapter |> Node.source_role_changeset(description) |> Repo.update!()
  end

  test "is the description's, and resource where it says none" do
    %{scope: scope} = sign_up_fixture()
    adapter = Repo.get!(Node, ticket_connection_fixture(scope).adapter_id)

    assert described(adapter, "grant").credential_scope == :grant
    assert described(adapter, "resource").credential_scope == :resource
    assert described(adapter, nil).credential_scope == :resource
  end

  test "the database holds it to the two values, and to adapters" do
    %{scope: scope} = sign_up_fixture()
    adapter = Repo.get!(Node, ticket_connection_fixture(scope).adapter_id)
    gateway = gateway_fixture(scope)

    for {id, value} <- [{adapter.id, "other"}, {gateway.id, "grant"}] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(from(n in "nodes", where: n.id == type(^id, :binary_id)),
            set: [credential_scope: value]
          )
        end

      assert error.postgres.constraint == "nodes_credential_scope_check"
    end
  end
end
