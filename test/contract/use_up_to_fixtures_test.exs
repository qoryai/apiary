defmodule Apiary.Contract.UseUpToFixturesTest do
  # The Forager contract's fixtures of an API credential with `use_up_to_percent` and
  # `use_up_to_windows`, vendored at the commit in `.forager-contract-ref`: the valid
  # fixture passes the run configuration schema as Forager and Qory Apiary read it, and
  # each invalid one is refused by both.
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

  test "the Use up to fixture passes the run configuration schema" do
    bytes = fixture("run-configuration/model-keys-use-up-to.json")
    assert ForagerSchemas.validate("run-configuration.schema.json", bytes) == :ok
    assert Schema.validate(bytes) == :ok
  end

  test "each invalid Use up to fixture fails the run configuration schema" do
    for file <- ~w(run-configuration-credentials-api-use-up-to-hundred.json
                   run-configuration-credentials-api-use-up-to-no-windows.json
                   run-configuration-credentials-api-use-up-to-twelve-windows.json
                   run-configuration-credentials-api-use-up-to-window-twice.json
                   run-configuration-credentials-api-use-up-to-window-upper-case.json
                   run-configuration-credentials-api-use-up-to-windows-alone.json
                   run-configuration-credentials-api-use-up-to-windows-empty.json
                   run-configuration-credentials-api-use-up-to-zero.json
                   run-configuration-credentials-host-use-up-to.json) do
      bytes = fixture("invalid/" <> file)
      assert {:error, _} = ForagerSchemas.validate("run-configuration.schema.json", bytes), file
      assert {:error, _} = Schema.validate(bytes), file
    end
  end
end
