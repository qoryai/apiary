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

  # example-tracker.json with `secrets` in its source role, `names`.
  defp with_secrets(names) do
    "example-tracker.json"
    |> contract_description()
    |> put_in(["roles", "source", "secrets"], names)
    |> read_description()
  end

  test "a description's names are kept sorted, and a later one without them clears them" do
    adapter = adapter_fixture()

    adapter =
      adapter
      |> Node.source_role_changeset(with_secrets(["signing-key", "event-secret"]))
      |> Repo.update!()

    assert adapter.secret_names == ["event-secret", "signing-key"]

    adapter =
      adapter
      |> Node.source_role_changeset(read_description("example-tracker.json"))
      |> Repo.update!()

    assert adapter.secret_names == nil
  end

  test "the description schema takes 1 to 16 names, each once, in their form" do
    for names <- [
          [],
          ["Signing-Key"],
          ["signing-key", "signing-key"],
          for(n <- 0..16, do: "s-#{n}")
        ] do
      document =
        "example-tracker.json"
        |> contract_description()
        |> put_in(["roles", "source", "secrets"], names)

      assert {:error, _reason} = document |> Jason.encode!() |> Description.parse(),
             inspect(names)
    end
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
