defmodule Apiary.Kinds.BoundsTest do
  # The walk of a decoded document against limits, the limits read from a schema, and the
  # schema check that walks first (`Apiary.Kinds.Schema.validate/3`) with its summary of
  # JSV's errors.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{Bounds, Schema}

  describe "within?/2" do
    test "a list over :list entries, at any depth, is refused" do
      assert Bounds.within?(List.duplicate(1, 3), list: 3)
      refute Bounds.within?(List.duplicate(1, 4), list: 3)
      assert Bounds.within?(%{"a" => [[1, 2, 3]]}, list: 3)
      refute Bounds.within?(%{"a" => [[1, 2, 3, 4]]}, list: 3)
    end

    test "an object over :members members, at any depth, is refused" do
      three = %{"a" => 1, "b" => 2, "c" => 3}
      assert Bounds.within?(three, members: 3)
      refute Bounds.within?(Map.put(three, "d", 4), members: 3)
      assert Bounds.within?([[three]], members: 3)
      refute Bounds.within?([[Map.put(three, "d", 4)]], members: 3)
    end

    test ":nodes counts the document, every entry and every member's value" do
      # The list, the map and its two values; then the list, its two entries and the map.
      assert Bounds.within?([%{"a" => 1, "b" => 2}], nodes: 4)
      refute Bounds.within?([%{"a" => 1, "b" => 2}], nodes: 3)
      assert Bounds.within?([1, 2, %{}], nodes: 4)
      refute Bounds.within?([1, 2, %{}], nodes: 3)
      assert Bounds.within?("scalar", nodes: 1)
      refute Bounds.within?("scalar", nodes: 0)
    end

    test ":string counts the bytes of a string, a member's name included" do
      assert Bounds.within?(["éé"], string: 4)
      refute Bounds.within?(["ééé"], string: 4)
      assert Bounds.within?(%{"abcd" => "x"}, string: 4)
      refute Bounds.within?(%{"abcde" => "x"}, string: 4)
      refute Bounds.within?([%{"a" => [String.duplicate("a", 5)]}], string: 4)
    end

    test ":depth counts the lists and objects nested in one another" do
      assert Bounds.within?(1, depth: 0)
      refute Bounds.within?([], depth: 0)
      assert Bounds.within?([%{"a" => []}], depth: 3)
      refute Bounds.within?([%{"a" => [[]]}], depth: 3)
      assert Bounds.within?(%{"a" => 1, "b" => [2]}, depth: 2)
    end

    test "a struct is refused anywhere, and a limit left out is not checked" do
      refute Bounds.within?(Decimal.new("1.5"), [])
      refute Bounds.within?(%{"a" => [Decimal.new("1.5")]}, list: 10)
      assert Bounds.within?(List.duplicate(%{"a" => "b"}, 10_000), [])
    end

    test "an unknown limit raises" do
      assert_raise ArgumentError, fn -> Bounds.within?([], items: 3) end
    end

    test "nesting of any depth runs in constant stack" do
      deep = Enum.reduce(1..200_000, [], fn _, inner -> [inner] end)
      assert Bounds.within?(deep, list: 1)
      refute Bounds.within?(deep, depth: 199_999)
      assert Bounds.within?(deep, depth: 200_001)
    end

    test "a long list is refused after reading one entry more than the limit" do
      # A million entries and a limit of two: the answer comes without a walk of them all.
      long = List.duplicate(%{}, 1_000_000)
      {microseconds, false} = :timer.tc(fn -> Bounds.within?(long, list: 2) end)
      assert microseconds < 50_000
    end
  end

  describe "from_schema/2" do
    test "a schema whose arrays and objects are all bounded gives the largest" do
      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "a" => %{
            "type" => "array",
            "maxItems" => 3,
            "uniqueItems" => true,
            "items" => %{"$ref" => "#/$defs/b"}
          },
          "c" => %{"type" => "array", "maxItems" => 7, "items" => %{"const" => 1}}
        },
        "$defs" => %{"b" => %{"type" => "string"}},
        "anyOf" => [%{"required" => ["a"]}, %{"required" => ["c"]}],
        "oneOf" => [%{"properties" => %{"a" => %{"const" => 1}}}, true],
        "not" => %{"required" => ["d"]}
      }

      assert Bounds.from_schema(schema) == [list: 7, members: 2]
    end

    test "a $ref into another document is followed, and that document is read as a schema" do
      url = "https://example.com/other.schema.json"

      other = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "name" => %{"type" => "string"},
          "tags" => %{"type" => "array", "maxItems" => 9, "items" => %{"type" => "string"}}
        },
        "allOf" => [%{"if" => %{"required" => ["name"]}, "then" => %{"required" => ["tags"]}}]
      }

      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "name" => %{"$ref" => url <> "#/properties/name", "maxLength" => 10},
          "tags" => %{"$ref" => url <> "#/properties/tags"}
        },
        "allOf" => [%{"$ref" => url <> "#/allOf/0"}]
      }

      assert Bounds.from_schema(schema, %{url => other}) == [list: 9, members: 2]
    end

    test "the service definition's schema gives lists of 32 and objects of 8 members" do
      assert Apiary.Kinds.ServiceDefinition.bounds() == [list: 32, members: 8]
    end

    test "a schema whose bounds cannot be told raises" do
      object = &%{"type" => "object", "additionalProperties" => false, "properties" => &1}
      url = "https://example.com/other.schema.json"

      for {schema, documents} <- [
            {%{"type" => "array"}, %{}},
            {%{"type" => "object", "additionalProperties" => %{"type" => "string"}}, %{}},
            {%{"type" => "object", "additionalProperties" => false, "patternProperties" => %{}},
             %{}},
            {object.(%{"a" => %{"$ref" => url <> "#/properties/a"}}), %{}},
            {object.(%{"a" => %{"$ref" => url}}), %{url => %{"type" => "string"}}},
            {object.(%{"a" => %{"$ref" => url <> "#/properties/b"}}),
             %{url => object.(%{"a" => %{"type" => "string"}})}},
            {object.(%{"a" => %{"$ref" => url <> "#/$defs/a"}}),
             %{url => %{"type" => "string", "$defs" => %{"a" => %{"type" => "array"}}}}},
            {object.(%{"a" => %{"$ref" => url <> "#/$defs/a"}}),
             %{
               url => %{
                 "type" => "string",
                 "$defs" => %{"a" => %{"$ref" => "https://example.com/third.schema.json#/a"}}
               }
             }},
            {object.(%{"a" => %{"$ref" => 1}}), %{}},
            {object.(%{"a" => %{"type" => "string", "anyOf" => [%{"type" => "array"}]}}), %{}},
            {object.(%{"a" => %{"type" => "string", "oneOf" => %{}}}), %{}},
            {object.(%{"a" => %{"type" => "string", "not" => %{"type" => "object"}}}), %{}},
            {%{"type" => "string"}, %{url => %{"type" => "array"}}}
          ] do
        assert_raise ArgumentError, fn -> Bounds.from_schema(schema, documents) end
      end
    end
  end

  describe "Schema.validate/3" do
    setup do
      {:ok, root} =
        Schema.build(%{"type" => "array", "items" => %{"type" => "string", "pattern" => "^a$"}})

      %{root: root}
    end

    test "is :ok for a value within the limits that the schema accepts", %{root: root} do
      assert Schema.validate(["a", "a"], root, list: 2) == :ok
    end

    test "refuses a value outside the limits before JSV, with the limits", %{root: root} do
      assert Schema.validate(["a", "a", "a"], root, list: 2, depth: 4) ==
               {:error, %{valid: false, limits: %{list: 2, depth: 4}}}
    end

    test "sums up the schema's refusal: the count and the first 8 errors", %{root: root} do
      assert {:error, %{valid: false, count: count, errors: errors}} =
               Schema.validate(List.duplicate(1, 20), root, list: 20)

      # Two errors for each entry: one at the list, `#`, for its items, and one at the entry.
      assert count == 40
      assert length(errors) == 8

      for %{kind: kind, instanceLocation: location} <- errors do
        assert is_atom(kind)
        assert location =~ ~r{\A#(/[0-9]+)?\z}
      end

      assert {:error, %{count: 2, errors: [%{kind: :items, instanceLocation: "#"}, second]}} =
               Schema.validate(["a", "b"], root, [])

      assert second == %{kind: :pattern, instanceLocation: "#/1"}
    end
  end
end
