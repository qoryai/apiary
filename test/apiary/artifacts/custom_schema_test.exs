defmodule Apiary.Artifacts.CustomSchemaTest do
  use ExUnit.Case, async: true

  alias Apiary.Artifacts.CustomSchema

  @bids %{
    "type" => "object",
    "required" => ["bids"],
    "properties" => %{
      "bids" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{"keyword" => %{"type" => "string", "pattern" => "^[a-z ]+$"}}
        }
      }
    }
  }

  describe "check/1" do
    test "takes a schema JSV builds" do
      assert :ok = CustomSchema.check(@bids)
      assert :ok = CustomSchema.check(%{})
    end

    test "refuses what is not an object, over the bounds, or not buildable" do
      assert {:error, :not_an_object} = CustomSchema.check([%{}])
      assert {:error, :not_an_object} = CustomSchema.check("{}")
      assert {:error, :limits} = CustomSchema.check(%{"enum" => Enum.to_list(1..1025)})

      assert {:error, :limits} =
               CustomSchema.check(%{"description" => String.duplicate("a", 16_385)})

      many = Map.new(1..700, &{"p#{&1}", %{"description" => String.duplicate("d", 90)}})
      assert {:error, :too_large} = CustomSchema.check(%{"properties" => many})

      assert {:error, :unbuildable} = CustomSchema.check(%{"type" => 5})
      assert {:error, :unbuildable} = CustomSchema.check(%{"pattern" => "("})

      assert {:error, :unbuildable} =
               CustomSchema.check(%{"$ref" => "https://example.com/remote.json"})
    end
  end

  describe "check_within/2" do
    @plenty [reductions: 10_000_000, ms: 30_000]

    test "takes a schema's reductions off what is left" do
      left = CustomSchema.total(@plenty)

      assert {:ok, after_one} = CustomSchema.check_within(@bids, left)
      assert after_one.reductions < left.reductions
      assert after_one.reductions > 0
      assert after_one.deadline == left.deadline
    end

    test "is the total's refusal once nothing is left" do
      for total <- [[reductions: 0, ms: 30_000], [reductions: 1_000_000, ms: 0]] do
        assert {:error, :total} = CustomSchema.check_within(@bids, CustomSchema.total(total))
      end
    end

    test "is the total's refusal for a run past what is left" do
      left = CustomSchema.total(reductions: 1, ms: 30_000)
      assert {:error, :total} = CustomSchema.check_within(@bids, left)
    end

    test "gives check/1's refusals, each bound kept" do
      left = CustomSchema.total(@plenty)

      assert {:error, :not_an_object} = CustomSchema.check_within([%{}], left)

      assert {:error, :limits} =
               CustomSchema.check_within(%{"enum" => Enum.to_list(1..1025)}, left)

      many = Map.new(1..700, &{"p#{&1}", %{"description" => String.duplicate("d", 90)}})
      assert {:error, :too_large} = CustomSchema.check_within(%{"properties" => many}, left)
      assert {:error, :unbuildable} = CustomSchema.check_within(%{"type" => 5}, left)
    end

    test "keeps a schema's refusal for a schema over the pattern budget" do
      properties = Map.new(1..210, &{"p#{&1}", %{"pattern" => "(?x)a#{&1}"}})

      assert {:error, :budget} =
               CustomSchema.check_within(
                 %{"properties" => properties},
                 CustomSchema.total(@plenty)
               )
    end
  end

  describe "validate/2" do
    test "is :ok for a document the schema takes, its first failing place for one it refuses" do
      assert :ok = CustomSchema.validate(%{"bids" => [%{"keyword" => "gift card"}]}, @bids)

      assert {:error, {:schema, %{path: "#/bids/0/keyword", error: _pattern}}} =
               CustomSchema.validate(%{"bids" => [%{"keyword" => "GIFT"}]}, @bids)

      assert {:error, {:schema, %{path: "#", error: "property 'bids' is required"}}} =
               CustomSchema.validate(%{}, @bids)
    end

    test "refuses a document over the bounds before JSV reads it" do
      assert {:error, :limits} = CustomSchema.validate(%{"bids" => Enum.to_list(1..10_001)}, %{})
      deep = Enum.reduce(1..33, 1, fn _n, acc -> [acc] end)
      assert {:error, :limits} = CustomSchema.validate(deep, %{})
    end

    test "drops a cast keyword and resolves a jsv: reference to a schema nothing passes" do
      cast = %{"type" => "string", "jsv-cast" => ["Elixir.JSV.Cast", "string_to_atom"]}

      assert :ok =
               CustomSchema.validate(
                 "not_an_atom_yet_#{System.unique_integer([:positive])}",
                 cast
               )

      assert {:error, {:schema, %{path: "#"}}} =
               CustomSchema.validate("a", %{"$ref" => "jsv:module:Elixir.String"})
    end
  end
end
