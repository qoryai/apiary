defmodule Apiary.Dispatches.ExploreInputsFixturesTest do
  # The explore contract's fixtures, vendored under `test/fixtures/contract/explore/v1/`,
  # against the vendored `inputs.schema.json` (`Apiary.ExploreInputsSchema`): each input
  # under `inputs/` is valid, and each under `invalid/` is refused.
  use ExUnit.Case, async: true

  alias Apiary.ExploreInputsSchema

  @dir Path.expand("../../fixtures/contract/explore/v1", __DIR__)

  defp read(file), do: file |> File.read!() |> Jason.decode!()

  test "each input is valid, and each invalid one refused" do
    valid = Path.wildcard(Path.join(@dir, "inputs/*.json"))
    invalid = Path.wildcard(Path.join(@dir, "invalid/*.json"))
    assert length(valid) == 7 and length(invalid) == 41

    for file <- valid do
      assert ExploreInputsSchema.validate(read(file)) == :ok, file
    end

    for file <- invalid do
      assert {:error, _} = ExploreInputsSchema.validate(read(file)), file
    end
  end
end
