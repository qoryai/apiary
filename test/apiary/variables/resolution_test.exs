defmodule Apiary.Variables.ResolutionTest do
  use ExUnit.Case, async: true

  alias Apiary.Variables.{Denied, Resolution, Variable}

  defp v(name, value, locked \\ false), do: %Variable{name: name, value: value, locked: locked}

  test "a lower level overrides a higher one, name by name" do
    resolution =
      Resolution.resolve([
        {:above, [v("A", "above"), v("B", "above")]},
        {:workspace, [v("B", "workspace"), v("C", "workspace")]},
        {:target, [v("C", "target"), v("D", "target")]}
      ])

    assert Resolution.values(resolution) == %{
             "A" => "above",
             "B" => "workspace",
             "C" => "target",
             "D" => "target"
           }

    assert Enum.map(resolution.entries, &{&1.name, &1.set_by}) == [
             {"A", :above},
             {"B", :workspace},
             {"C", :target},
             {"D", :target}
           ]
  end

  test "a lock holds against every level below it, which is set aside" do
    resolution =
      Resolution.resolve([
        {:above, [v("REGION", "eu", true)]},
        {:workspace, [v("REGION", "us"), v("LEVEL", "info", true)]},
        {:target, [v("REGION", "ap"), v("LEVEL", "debug")]}
      ])

    assert Resolution.values(resolution) == %{"REGION" => "eu", "LEVEL" => "info"}

    assert Resolution.entry(resolution, "REGION") == %{
             name: "REGION",
             value: "eu",
             set_by: :above,
             locked_by: :above,
             ignored: [:workspace, :target]
           }

    assert %{locked_by: :workspace, ignored: [:target]} = Resolution.entry(resolution, "LEVEL")
  end

  test "a lower level's lock replaces what is above it and holds below it" do
    resolution =
      Resolution.resolve([
        {:above, [v("A", "above")]},
        {:workspace, [v("A", "workspace", true)]},
        {:target, [v("A", "target")]}
      ])

    assert %{value: "workspace", set_by: :workspace, locked_by: :workspace, ignored: [:target]} =
             Resolution.entry(resolution, "A")
  end

  test "names are one whatever their case, spelled as the highest level spells them" do
    resolution =
      Resolution.resolve([{:workspace, [v("Node_Env", "a")]}, {:target, [v("NODE_ENV", "b")]}])

    assert Resolution.values(resolution) == %{"Node_Env" => "b"}
    assert Resolution.entry(resolution, "node_env").set_by == :target
  end

  test "a name the runner keeps, or that breaks the rule, is left out from any level" do
    resolution =
      Resolution.resolve([
        {:above, [v("QORY_TOKEN", "x"), v("qory_other", "x"), v("BAD-NAME", "x"), v("OK", "x")]},
        {:workspace, [%{name: nil, value: "x"}, %{name: "NO_VALUE", value: nil}]}
      ])

    assert Resolution.values(resolution) == %{"OK" => "x"}
  end

  test "the limits are 128 names and 65536 bytes of names and values" do
    full = Resolution.resolve([{:workspace, for(i <- 1..128, do: v("N#{i}", ""))}])
    assert Resolution.check_limits(full) == :ok

    over = Resolution.resolve([{:workspace, for(i <- 1..129, do: v("N#{i}", ""))}])
    assert Resolution.check_limits(over) == {:error, :too_many_names}

    exact = Resolution.resolve([{:workspace, [v("A", String.duplicate("x", 65_535))]}])
    assert Resolution.size(exact) == %{names: 1, bytes: 65_536}
    assert Resolution.check_limits(exact) == :ok

    large = Resolution.resolve([{:workspace, [v("AB", String.duplicate("x", 65_535))]}])
    assert Resolution.check_limits(large) == {:error, :too_large}

    # Bytes, not characters.
    assert Resolution.size(Resolution.resolve([{:workspace, [v("E", "é")]}])).bytes == 3
  end

  test "an empty chain resolves to nothing" do
    assert Resolution.values(Resolution.resolve([])) == %{}
    assert Resolution.entry(Resolution.resolve([]), "A") == nil
  end

  describe "the deny list" do
    test "QORY_* is on it and refused, whatever the case" do
      assert Denied.patterns() == ["QORY_*"]
      assert Denied.names() == []

      for name <- ["QORY_", "QORY_TOKEN", "qory_token", "Qory_Run_Id"] do
        assert Denied.refused?(name)
        assert Denied.denied?(name)
      end

      for name <- ["QORY", "QORYX", "MY_QORY_TOKEN", "_QORY_"] do
        refute Denied.refused?(name)
        refute Denied.denied?(name)
      end
    end

    test "a pattern matches a whole name, * any run of characters, the empty one included" do
      assert Denied.matches?("*_PROXY", "HTTP_PROXY")
      assert Denied.matches?("*_PROXY", "_PROXY")
      assert Denied.matches?("*_PROXY", "no_proxy")
      refute Denied.matches?("*_PROXY", "HTTP_PROXY_X")
      assert Denied.matches?("A*B*C", "ABC")
      assert Denied.matches?("A*B*C", "AxxBxxC")
      refute Denied.matches?("A*B", "AxxBx")
      assert Denied.matches?("PATH", "path")
      refute Denied.matches?("PATH", "PATHS")
      # Only * is special.
      refute Denied.matches?("A.B", "AxB")
    end
  end
end
