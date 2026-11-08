defmodule Apiary.Artifacts.VerdictSchemaTest do
  # The schema of the type verdict, `priv/schemas/artifacts/verdict.schema.json`, is a copy
  # of qory's `contracts/harness/v1/verdict.schema.json` at qory commit
  # 17252003c21773cf6e5b767c6fbfc1dfc58f8382, byte for byte. Update the hash with the copy.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Bounds

  @path Path.expand("../../../priv/schemas/artifacts/verdict.schema.json", __DIR__)
  @sha256 "3ec2221bbf5cde341969a0197cf3ad16169c8d5b202b979233f775a6b775f762"

  test "is the bytes of qory's verdict schema at the pinned commit" do
    bytes = File.read!(@path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha256
  end

  test "limits a verdict to 20 points of at most 3 members each" do
    assert @path |> File.read!() |> Jason.decode!() |> Bounds.from_schema() ==
             [list: 20, members: 3]
  end
end
