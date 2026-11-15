defmodule Apiary.Artifacts.VerdictSchemaTest do
  # The schema of the type verdict, `priv/schemas/artifacts/verdict.schema.json`, revision
  # 1, is the source of the schema; qory keeps a byte copy of it at
  # `contracts/harness/v1/verdict.schema.json`. The test pins the file's SHA-256: update
  # the hash with the file, and name qory's commit here once that commit has these bytes.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Bounds

  @path Path.expand("../../../priv/schemas/artifacts/verdict.schema.json", __DIR__)
  @sha256 "068fe7d7035991c8f977ee8b79f632eb4faab35b408345757d7784a3cb3a98e4"

  test "is the bytes of the verdict schema the hash pins" do
    bytes = File.read!(@path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha256
  end

  test "limits a verdict to 20 points of at most 3 members each" do
    assert @path |> File.read!() |> Jason.decode!() |> Bounds.from_schema() ==
             [list: 20, members: 3]
  end
end
