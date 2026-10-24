defmodule Apiary.Adapters.SecretNamesTest do
  # The names of the secrets an adapter stores in Qory Apiary, as the source role of its
  # latest description lists them (`secrets`, `Apiary.Nodes.Node.source_role_changeset/2`),
  # and what the database holds them to (`nodes_secret_names_check`).
  use Apiary.DataCase, async: true

  import Apiary.DescriptionFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Integrations.Description
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  @moduletag needs: :factory

  # example-tracker.json with `secrets` in its source role, put on the description as
  # read: the description schema Core has vendored lists no `secrets` yet, so a document
  # with them does not parse.
  defp with_secrets(names) do
    description = read_description("example-tracker.json")
    %{description | document: put_in(description.document, ["roles", "source", "secrets"], names)}
  end

  test "a description's names are kept sorted, and a later one without them clears them" do
    adapter = adapter_fixture()

    adapter =
      adapter
      |> Node.source_role_changeset(with_secrets(["signing-key", "event-secret"]))
      |> Repo.update!()

    assert adapter.secret_names == ["event-secret", "signing-key"]
    assert Description.source_secrets(with_secrets([])) == nil

    adapter =
      adapter
      |> Node.source_role_changeset(read_description("example-tracker.json"))
      |> Repo.update!()

    assert adapter.secret_names == nil
  end

  test "the vendored description schema refuses a source role with secrets" do
    document =
      "example-tracker.json"
      |> contract_description()
      |> put_in(["roles", "source", "secrets"], ["signing-key"])

    assert {:error, _reason} = document |> Jason.encode!() |> Description.parse()
  end

  test "the database keeps names only on an adapter, and only in their form" do
    adapter = adapter_fixture()
    %{scope: scope} = sign_up_fixture()
    node = node_fixture(scope)

    for {id, names} <- [
          {adapter.id, ["Signing-Key"]},
          {adapter.id, []},
          {adapter.id, [nil]},
          {adapter.id, for(n <- 0..16, do: "secret-#{n}")},
          {node.id, ["signing-key"]}
        ] do
      assert_raise Postgrex.Error, ~r/nodes_secret_names_check/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^id), set: [secret_names: names])
      end
    end
  end
end
