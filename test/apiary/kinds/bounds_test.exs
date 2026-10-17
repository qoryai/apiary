defmodule Apiary.Kinds.BoundsTest do
  # The walk of a decoded document against limits, and the schema check that walks first
  # (`Apiary.Kinds.Schema.validate/3`).
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

    test "nesting 200000 deep is read" do
      deep = Enum.reduce(1..200_000, [], fn _, inner -> [inner] end)
      assert Bounds.within?(deep, list: 1)
      refute Bounds.within?(deep, depth: 199_999)
      assert Bounds.within?(deep, depth: 200_001)
    end

    test "a long list is refused after reading one entry more than the limit" do
      # A million entries and a limit of two: the answer comes without a walk of them all.
      long = List.duplicate(%{}, 1_000_000)

      task =
        Task.async(fn ->
          {:reductions, before} = Process.info(self(), :reductions)
          false = Bounds.within?(long, list: 2)
          {:reductions, done} = Process.info(self(), :reductions)
          done - before
        end)

      # A walk of the million entries does a million reductions or more.
      assert Task.await(task, 60_000) < 1000
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

    test "gives the schema's refusal as validate/2 does, within the limits", %{root: root} do
      assert {:error, errors} = Schema.validate(["a", "b"], root, list: 2)
      assert {:error, errors} == Schema.validate(["a", "b"], root)
      refute Map.has_key?(errors, :limits)
    end
  end
end
