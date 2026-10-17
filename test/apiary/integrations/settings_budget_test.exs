defmodule Apiary.Integrations.SettingsBudgetTest do
  # The budget of the settings check (`Apiary.Integrations.Description.check_settings/2`).
  # The settings schema comes from the description, and a few of its references can make
  # the check's work grow exponentially, which no limit on the settings bounds. The check
  # runs in another process within 5000000 reductions and 16 MiB of heap, which count
  # the work and not the time; one over that budget is refused as invalid settings,
  # `budget: :exceeded`, and the warning it logs says which it ran out of. The reason is
  # asserted and the time is not: a check its time stopped, 10 s, would log `reason=time`.
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures
  import ExUnit.CaptureLog

  alias Apiary.Integrations.Description

  @fixtures Path.expand("../../fixtures/integration-contract", __DIR__)

  @refused {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}

  defp with_settings_schema(schema) do
    assert {:ok, description} =
             tracker_description(%{"settings" => schema}) |> encode() |> Description.parse()

    description
  end

  # A schema whose every level refers twice to the next, in `keyword`: 2^levels checks of
  # one value, which the last level takes as `last` says. The definitions are in
  # `defs`, `$defs`, or `definitions` under draft-07.
  defp doubling(levels, keyword \\ "allOf", last \\ "string", defs \\ "$defs") do
    chain =
      Map.new(1..levels, fn i ->
        next = %{"$ref" => "#/#{defs}/d#{i + 1}"}
        {"d#{i}", %{keyword => [next, next]}}
      end)

    schema = %{
      "type" => "object",
      "properties" => %{"a" => %{"$ref" => "#/#{defs}/d1"}},
      defs => Map.put(chain, "d#{levels + 1}", %{"type" => last})
    }

    if defs == "definitions",
      do:
        with_settings_schema(
          Map.put(schema, "$schema", "http://json-schema.org/draft-07/schema#")
        ),
      else: with_settings_schema(schema)
  end

  # The value of `fun` and the reductions it did, in a separate Task, its heap collected
  # first so that a collection of what came before falls outside the window.
  defp reductions(fun) do
    Task.async(fn ->
      :erlang.garbage_collect()
      {:reductions, before} = Process.info(self(), :reductions)
      result = fun.()
      {:reductions, done} = Process.info(self(), :reductions)
      {done - before, result}
    end)
    |> Task.await(60_000)
  end

  # The refusal, and the budget it ran out of, `reason`: "reductions" or "heap". The
  # caller does little of the work: the check runs in another process, stopped at the
  # budget. Measured: at most 82923 reductions in the caller.
  defp over_budget(description, settings, reason) do
    {{caller, result}, log} =
      with_log(fn -> reductions(fn -> Description.check_settings(description, settings) end) end)

    assert result == @refused
    assert log =~ "settings check was stopped name=acme-tracker"
    assert log =~ ~r/reason=(#{reason})$/m
    assert caller < 1_000_000, "#{caller} reductions in the caller"
  end

  # 1000 backtracking patterns, each spending the pattern budget of JSV on a value.
  defp backtracking, do: %{"anyOf" => for(_ <- 1..1000, do: %{"pattern" => "^(a+)+$"})}

  defp values(value) when is_map(value),
    do: 1 + (value |> Map.values() |> Enum.map(&values/1) |> Enum.sum())

  defp values(value) when is_list(value), do: 1 + (value |> Enum.map(&values/1) |> Enum.sum())
  defp values(_value), do: 1

  describe "the attack shapes" do
    # Measured without the budget: 20 levels of allOf did 157253942 reductions, 24 levels
    # 2519363535, and 40 levels and the two others below passed 2000000000 unfinished.

    test "a $ref chain that doubles at each level runs out of reductions, at 20 or 40 levels" do
      over_budget(doubling(20), %{"a" => "s"}, "reductions")
      over_budget(doubling(40), %{"a" => "s"}, "reductions")
    end

    test "a recursive anyOf of items against settings 64 deep runs out of heap" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"t" => %{"$ref" => "#/$defs/t"}},
          "$defs" => %{
            "t" => %{
              "type" => "array",
              "anyOf" => [
                %{"items" => %{"$ref" => "#/$defs/t"}},
                %{"items" => %{"$ref" => "#/$defs/t"}}
              ]
            }
          }
        })

      # The settings and 63 lists nested in them are 64 deep. The innermost holds 1, which
      # `t` refuses, so each level tries both branches.
      settings = %{"t" => Enum.reduce(1..62, [1], fn _, inner -> [inner] end)}
      over_budget(description, settings, "heap")
    end

    test "1000 backtracking patterns in items.oneOf against 1024 strings run out of reductions" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "type" => "array",
              "items" => %{"oneOf" => for(_ <- 1..1000, do: %{"pattern" => "^(a+)+$"})}
            }
          }
        })

      settings = %{"x" => List.duplicate(String.duplicate("a", 59) <> "!", 1024)}
      assert byte_size(Apiary.Kinds.CanonicalJSON.encode!(settings)) in 60_000..65_536
      over_budget(description, settings, "reductions")
    end
  end

  describe "the memory of the settings schema's patterns" do
    # A compiled pattern is memory outside the heap, which the budget does not count: each
    # `(?:a){7900}b<i>` compiles to about 64 KB. Measured on main before the estimate,
    # the build of 1950 of them took the node 126 MiB more memory.
    defp heavy(i), do: %{"pattern" => "(?:a){7900}b#{i}"}

    test "a schema of 1950 patterns of about 64 KB each is stopped before its build" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "allOf" =>
                for(c <- Enum.chunk_every(1..1950, 1000), do: %{"allOf" => Enum.map(c, &heavy/1)})
            }
          }
        })

      over_budget(description, %{"x" => "b"}, "patterns")
    end

    # JSV builds the target of each distinct reference: 26 pointers, each into the one
    # before, build the 30 patterns 26 times.
    test "so is a schema whose 30 such patterns 26 nested pointers build again" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" =>
            Map.new(
              0..25,
              &{"r#{&1}", %{"$ref" => "#/$defs/p" <> String.duplicate("/allOf/0", &1)}}
            ),
          "$defs" => %{
            "p" =>
              Enum.reduce(1..25, %{"allOf" => Enum.map(1..30, &heavy/1)}, fn _, inner ->
                %{"allOf" => [inner]}
              end)
          }
        })

      over_budget(description, Map.new(0..25, &{"r#{&1}", "b"}), "patterns")
    end

    # Each value checked against `"format": "regex"` is compiled once
    # (`Apiary.Kinds.RegexFormat`). Measured on main before the estimate, 1950 values of
    # `(?:a){7900}b<i>`, 35958 bytes of settings, passed and took the node 120 MiB more
    # memory.
    defp regex_lists do
      with_settings_schema(%{
        "type" => "object",
        "properties" => %{
          "l1" => %{"type" => "array", "items" => %{"type" => "string", "format" => "regex"}},
          "l2" => %{"type" => "array", "items" => %{"type" => "string", "format" => "regex"}}
        }
      })
    end

    test "settings of 1950 regular expressions of about 64 KB each are stopped before they compile" do
      {l1, l2} = Enum.split(for(i <- 1..1950, do: "(?:a){7900}b#{i}"), 1024)
      over_budget(regex_lists(), %{"l1" => l1, "l2" => l2}, "patterns")
    end

    test "settings of 2048 ordinary regular expressions are checked" do
      settings = %{
        "l1" => for(i <- 1..1024, do: "^v#{i}-[a-z0-9]{1,40}$"),
        "l2" => for(i <- 1..1024, do: "(?i)^w#{i}(-[0-9]+)*$")
      }

      assert Description.check_settings(regex_lists(), settings) == :ok
    end

    test "100 such patterns are built and checked" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"x" => %{"allOf" => Enum.map(1..100, &heavy/1)}}
        })

      assert {:error, {:integration_settings_invalid, %{valid: false, details: [_ | _]}}} =
               Description.check_settings(description, %{"x" => "b"})
    end
  end

  describe "the budget of the settings check" do
    test "a schema that doubles its work at each of 20 or 24 levels runs out of reductions" do
      over_budget(doubling(20), %{"a" => "s"}, "reductions")
      over_budget(doubling(24), %{"a" => "s"}, "reductions")
    end

    test "so does one in draft-07, its definitions in definitions" do
      over_budget(doubling(24, "allOf", "string", "definitions"), %{"a" => "s"}, "reductions")
      over_budget(doubling(24, "allOf", "string", "definitions"), %{"a" => 1}, "heap")
    end

    test "a doubling schema whose leaf refuses the value runs out of heap, the errors kept" do
      over_budget(doubling(20), %{"a" => 1}, "heap")
      over_budget(doubling(20, "anyOf", "integer"), %{"a" => "s"}, "heap")
      over_budget(doubling(20, "oneOf"), %{"a" => 1}, "heap")
    end

    test "an anyOf of 16 or 18 levels, each referring twice to the next, runs out of heap" do
      over_budget(doubling(16, "anyOf", "integer"), %{"a" => "s"}, "heap")
      over_budget(doubling(18, "anyOf", "integer"), %{"a" => "s"}, "heap")
    end

    test "a schema of 1000 patterns for each of 1024 strings runs out of heap" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "type" => "array",
              "items" => %{
                "anyOf" => for(i <- 1..1000, do: %{"type" => "string", "pattern" => "^z#{i}$"})
              }
            }
          }
        })

      over_budget(description, %{"x" => List.duplicate("a", 1024)}, "heap")
    end

    test "1000 backtracking patterns run out of reductions on a long setting, 128, a list" do
      one =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"s1" => %{"$ref" => "#/$defs/p"}},
          "$defs" => %{"p" => backtracking()}
        })

      over_budget(one, %{"s1" => String.duplicate("a", 60_000) <> "!"}, "reductions")

      many =
        with_settings_schema(%{
          "type" => "object",
          "properties" => Map.new(1..128, &{"s#{&1}", %{"$ref" => "#/$defs/p"}}),
          "$defs" => %{"p" => backtracking()}
        })

      over_budget(
        many,
        Map.new(1..128, &{"s#{&1}", String.duplicate("a", 60) <> "!"}),
        "reductions"
      )

      list =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"l" => %{"type" => "array", "items" => backtracking()}}
        })

      over_budget(
        list,
        %{"l" => List.duplicate(String.duplicate("a", 24) <> "!", 100)},
        "reductions"
      )
    end

    test "1000 email formats against a string of 60 KB run out of heap" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"e" => %{"allOf" => for(_ <- 1..1000, do: %{"format" => "email"})}}
        })

      over_budget(description, %{"e" => String.duplicate("a", 60_000) <> "@"}, "heap")
    end

    test "a schema that doubles its work at each of 10 levels passes, as do 1000 settings" do
      assert Description.check_settings(doubling(10), %{"a" => "s"}) == :ok

      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" =>
            Map.new(1..1000, &{"p#{&1}", %{"type" => "string", "pattern" => "^[a-z0-9]{1,40}$"}})
        })

      settings = Map.new(1..1000, &{"p#{&1}", "value#{&1}"})
      assert Description.check_settings(description, settings) == :ok
    end

    test "valid settings at the limits are accepted" do
      # A schema that bounds nothing: a list of any length, a list of any length whose
      # every entry is a string of one of 32 patterns, an object of any members, any
      # value, and a tree of lists of any depth.
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "list" => %{"type" => "array", "items" => %{"type" => "string"}},
            "choice" => %{
              "type" => "array",
              "items" => %{
                "anyOf" =>
                  for(i <- 1..32, do: %{"type" => "string", "pattern" => "^p#{i}-[0-9]+$"})
              }
            },
            "map" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
            "any" => %{},
            "tree" => %{"$ref" => "#/$defs/tree"}
          },
          "$defs" => %{"tree" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/tree"}}}
        })

      # Lists of 1024 entries, an object of 1024 members, and the settings and 63 lists
      # nested in them 64 deep; `any` fills them to 4096 values.
      settings = %{
        "list" => for(i <- 1..1024, do: "s#{i}"),
        "choice" => for(i <- 1..1024, do: "p32-#{i}"),
        "map" => Map.new(1..1024, &{"k#{&1}", "v"}),
        "tree" => Enum.reduce(1..62, [], fn _, inner -> [inner] end)
      }

      settings = Map.put(settings, "any", List.duplicate(1, 4096 - values(settings) - 1))
      assert values(settings) == 4096

      # Valid settings pass however slow or busy the machine: the budget decides by
      # reductions and heap, so the time is not asserted.
      assert Description.check_settings(description, settings) == :ok
    end

    test "every fixture with settings takes the settings it describes" do
      assert {:ok, fixture} =
               @fixtures |> Path.join("github.json") |> File.read!() |> Description.parse()

      assert Description.check_settings(fixture, %{
               "app_id" => 123_456,
               "installation_id" => 7,
               "permissions" => %{"contents" => "read"},
               "api_url" => "http://localhost:8080"
             }) == :ok

      assert {:ok, tracker} = tracker_description() |> encode() |> Description.parse()
      assert Description.check_settings(tracker, %{"url" => "https://tracker.example.com"}) == :ok
    end
  end
end
