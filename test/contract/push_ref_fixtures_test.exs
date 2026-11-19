defmodule Apiary.Contract.PushRefFixturesTest do
  # The Forager contract's fixtures of an apply item with `push_ref` and of a push
  # credential, vendored at the commit in `.forager-contract-ref`: each valid fixture passes
  # the run configuration schema as Forager and Qory Apiary read it, and each invalid one is
  # refused by both.
  use ExUnit.Case, async: true

  alias Apiary.ForagerSchemas
  alias Apiary.Policy.Schema

  @moduletag :contract

  @root Path.expand("../..", __DIR__)
  @fixtures "test/fixtures/forager-contract/"

  defp fixture(path) do
    assert (@fixtures <> path) in Apiary.ContractFixtures.vendored(), path
    File.read!(Path.join([@root, @fixtures, path]))
  end

  test "the push_ref fixture passes the run configuration schema" do
    bytes = fixture("run-configuration/credentials-forge-push.json")
    assert ForagerSchemas.validate("run-configuration.schema.json", bytes) == :ok
    assert Schema.validate(bytes) == :ok
  end

  test "each invalid push_ref fixture fails the run configuration schema" do
    for file <- ~w(run-configuration-credentials-push-ref-branch-name.json
                   run-configuration-credentials-push-ref-tag.json) do
      bytes = fixture("invalid/" <> file)
      assert {:error, _} = ForagerSchemas.validate("run-configuration.schema.json", bytes), file
      assert {:error, _} = Schema.validate(bytes), file
    end
  end

  test "the push credential fixture passes the run configuration schema" do
    bytes = fixture("run-configuration/push.json")
    assert ForagerSchemas.validate("run-configuration.schema.json", bytes) == :ok
    assert Schema.validate(bytes) == :ok
  end

  test "a credential purpose other than harness, work and push fails the schema" do
    document = "run-configuration/push.json" |> fixture() |> Jason.decode!()

    bytes =
      update_in(document, ["credentials", Access.at(1), "purpose"], fn _push -> "merge" end)
      |> Jason.encode!()

    assert {:error, _} = ForagerSchemas.validate("run-configuration.schema.json", bytes)
    assert {:error, _} = Schema.validate(bytes)
  end
end
