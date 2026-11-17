defmodule Apiary.Artifacts.VerdictSchemaTest do
  # The schema of the type verdict, `priv/schemas/artifacts/verdict.schema.json`, revision
  # 1, is the source of the schema; qory keeps a byte copy of it at
  # `contracts/harness/v1/verdict.schema.json`. The test pins the file's SHA-256: update
  # the hash with the file, and name qory's commit here once that commit has these bytes.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Bounds

  @path Path.expand("../../../priv/schemas/artifacts/verdict.schema.json", __DIR__)
  @sha256 "e85da6db7067ba2d3253241d09910422ae812d9950a661b2155bc5f47ee100f7"

  test "is the bytes of the verdict schema the hash pins" do
    bytes = File.read!(@path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha256
  end

  test "limits a verdict to 20 points of at most 4 members each" do
    assert @path |> File.read!() |> Jason.decode!() |> Bounds.from_schema() ==
             [list: 20, members: 4]
  end

  describe "track kind" do
    defp with_kind(kind) do
      %{
        "verdict" => "passed",
        "track" => %{"id" => "small-change", "reason" => "One file changes.", "kind" => kind}
      }
    end

    test "is one line of 1 to 80 characters with something other than spaces" do
      for kind <- ["a", "A text that the product shows", String.duplicate("x", 80), "ä<b>"] do
        assert valid?(with_kind(kind))
      end

      for kind <- [
            String.duplicate("x", 81),
            "",
            "   ",
            7,
            nil,
            ["a"],
            "two\nlines",
            "one\rtwo",
            "tab\there"
          ] do
        refute valid?(with_kind(kind))
      end
    end

    test "is optional" do
      assert valid?(%{
               "verdict" => "passed",
               "track" => %{"id" => "small-change", "reason" => "One file changes."}
             })
    end
  end

  describe "track" do
    defp valid?(document) do
      root = Apiary.Kinds.Schema.file!(["schemas", "artifacts", "verdict.schema.json"])
      match?({:ok, _}, JSV.validate(document, root, cast: false))
    end

    test "is an id and a reason of one line, and nothing else" do
      track = %{"id" => "small-change", "reason" => "One file changes."}
      assert valid?(%{"verdict" => "passed", "track" => track})
      assert valid?(%{"verdict" => "changes-requested", "track" => track})

      for bad <- [
            %{"id" => "small-change"},
            %{"reason" => "One file changes."},
            %{"id" => "Small", "reason" => "x"},
            %{"id" => String.duplicate("a", 41), "reason" => "x"},
            %{"id" => "a", "reason" => ""},
            %{"id" => "a", "reason" => String.duplicate("x", 301)},
            %{"id" => "a", "reason" => "two\nlines"},
            %{"id" => "a", "reason" => "x", "more" => 1},
            "a",
            nil
          ] do
        refute valid?(%{"verdict" => "passed", "track" => bad})
      end
    end
  end
end
