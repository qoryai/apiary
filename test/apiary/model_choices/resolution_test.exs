defmodule Apiary.ModelChoices.ResolutionTest do
  # The resolution reads no table: choices and providers go in, one answer comes out.
  use ExUnit.Case, async: true

  alias Apiary.ModelChoices.{ModelChoice, Resolution}

  @workspace "00000000-0000-0000-0000-0000000000a1"
  @other_workspace "00000000-0000-0000-0000-0000000000a2"
  @target "00000000-0000-0000-0000-0000000000b1"
  @other_target "00000000-0000-0000-0000-0000000000b2"
  @alpha "00000000-0000-0000-0000-0000000000c1"
  @beta "00000000-0000-0000-0000-0000000000c2"
  @gamma "00000000-0000-0000-0000-0000000000c3"

  @providers %{
    @alpha => %{
      default_value_id: "main",
      default_model_id: "big",
      models: [
        %{model_id: "big", effort: ["low", "high"]},
        %{model_id: "small", effort: nil},
        %{model_id: "mid", effort: ["high"]}
      ]
    },
    @beta => %{
      default_value_id: "team",
      default_model_id: "other",
      models: [%{model_id: "other", effort: nil}]
    },
    # A provider whose description lists no model.
    @gamma => %{default_value_id: "main", default_model_id: nil, models: []}
  }

  defp input(choices, opts \\ []) do
    %{
      choices: choices,
      workspace_id: @workspace,
      target_id: Keyword.get(opts, :target_id, @target),
      workflow: Keyword.get(opts, :workflow, "hello"),
      providers: @providers
    }
  end

  # A choice at `level`, of the workspace and target above; `attrs` are its columns.
  defp at(level, attrs \\ []) do
    place =
      case level do
        6 -> %{}
        5 -> %{workspace_id: @workspace}
        4 -> %{workspace_id: @workspace, workflow: "hello"}
        3 -> %{workspace_id: @workspace, target_id: @target}
        2 -> %{workspace_id: @workspace, target_id: @target, workflow: "hello"}
      end

    struct!(ModelChoice, Map.merge(%{connection_id: @alpha}, Map.merge(place, Map.new(attrs))))
  end

  defp resolved(input) do
    assert {:ok, %Resolution{} = resolution} = Resolution.resolve(input)
    resolution
  end

  describe "in_effect/1" do
    test "is the choice the resolution takes its provider from: locked first, then the most specific" do
      five = at(5, model_id: "big")
      four = at(4, model_id: "small")
      locked = %{five | locked: true}
      no_provider = at(2, connection_id: nil, tiers: %{"fast" => "small"})

      assert {4, ^four} = Resolution.in_effect(input([five, four, no_provider]))
      assert {5, ^locked} = Resolution.in_effect(input([locked, four]))
      assert {5, ^five} = Resolution.in_effect(input([five, four], workflow: nil))
      assert Resolution.in_effect(input([no_provider])) == nil

      # A choice whose provider is not among the providers is still the one in effect.
      gone = at(5, connection_id: "00000000-0000-0000-0000-0000000000c9")
      assert {5, ^gone} = Resolution.in_effect(input([gone]))
    end
  end

  describe "the provider, the key, the model and the effort" do
    test "come from the most specific level that chose a provider" do
      choices = for level <- 2..6, do: at(level, model_id: "level#{level}", value_id: "k#{level}")

      assert %{level: 2, model_id: "level2", value_id: "k2"} = resolved(input(choices))

      for level <- 2..6 do
        rest = Enum.filter(choices, &(ModelChoice.level(&1) >= level))
        assert %{level: ^level, model_id: model} = resolved(input(rest))
        assert model == "level#{level}"
      end
    end

    test "skip a level that sets only tiers" do
      only_tiers = at(2, connection_id: nil, tiers: %{"fast" => %{"model" => "small"}})

      assert %{level: 5, model_id: "mid"} =
               resolved(input([only_tiers, at(5, model_id: "mid")]))
    end

    test "take a choice without a key from the provider's default key" do
      assert %{value_id: "main"} = resolved(input([at(5)]))
      assert %{value_id: "spare"} = resolved(input([at(5, value_id: "spare")]))
    end

    test "take a choice without a model from the provider's default model, with no effort" do
      assert %{model_id: "big", effort: nil} = resolved(input([at(5)]))
    end

    test "leave the model unset for a provider with no default model" do
      assert %{model_id: nil, effort: nil} = resolved(input([at(5, connection_id: @gamma)]))

      assert %{model_id: "team-large"} =
               resolved(input([at(5, connection_id: @gamma, model_id: "team-large")]))
    end

    test "leave the effort unset when the winning level sets none, whatever a level below sets" do
      choices = [at(2, model_id: "mid"), at(5, model_id: "big", effort: "high")]
      assert %{level: 2, model_id: "mid", effort: nil} = resolved(input(choices))

      choices = [at(2, model_id: "mid", effort: "high"), at(5, model_id: "big", effort: "low")]
      assert %{level: 2, effort: "high"} = resolved(input(choices))
    end

    test "ignore a choice of another workspace, target or workflow" do
      others = [
        %{at(5, model_id: "no") | workspace_id: @other_workspace},
        %{at(4, model_id: "no") | workflow: "review"},
        %{at(3, model_id: "no") | target_id: @other_target},
        %{at(2, model_id: "no") | target_id: @other_target},
        %{at(2, model_id: "no") | workflow: "review"},
        %{at(2, model_id: "no") | workspace_id: @other_workspace}
      ]

      assert %{level: 6, model_id: "small"} = resolved(input([at(6, model_id: "small") | others]))
    end

    test "resolve a run with no workflow from levels 3, 5 and 6" do
      choices = for level <- 2..6, do: at(level, model_id: "level#{level}")
      assert %{level: 3, model_id: "level3"} = resolved(input(choices, workflow: nil))

      rest = Enum.filter(choices, &(ModelChoice.level(&1) in [2, 4, 5, 6]))
      assert %{level: 5, model_id: "level5"} = resolved(input(rest, workflow: nil))
    end

    test "resolve a run with no target from levels 4 to 6" do
      choices = for level <- 2..6, do: at(level, model_id: "level#{level}")
      no_target = input(choices, target_id: nil)

      assert %{level: 4, model_id: "level4"} = resolved(no_target)

      rest = Enum.filter(choices, &(ModelChoice.level(&1) in [2, 3, 5, 6]))
      assert %{level: 5, model_id: "level5"} = resolved(input(rest, target_id: nil))
    end

    test "resolve to none where no choice has a provider" do
      assert Resolution.resolve(input([])) == :none

      assert Resolution.resolve(input([at(5, connection_id: nil, tiers: %{"fast" => "small"})])) ==
               :none
    end

    test "end with the provider removed where the chosen provider is gone" do
      assert Resolution.resolve(input([at(5, connection_id: "missing")])) ==
               {:error, :provider_removed}
    end
  end

  describe "a workspace lock" do
    test "holds against the levels below it" do
      locked = at(5, model_id: "mid", locked: true)
      below = for level <- [2, 3, 4], do: at(level, model_id: "level#{level}")

      assert %{level: 5, model_id: "mid"} = resolved(input([locked | below]))
    end

    test "of the more specific workspace level wins among locks" do
      choices = [at(5, model_id: "mid", locked: true), at(4, model_id: "small", locked: true)]
      assert %{level: 4, model_id: "small"} = resolved(input(choices))
    end

    test "that sets no provider leaves the provider to the next level" do
      locked = at(5, connection_id: nil, locked: true, tiers: %{"fast" => "small"})
      assert %{level: 2, model_id: "mid"} = resolved(input([locked, at(2, model_id: "mid")]))
    end

    test "does not hold from level 6, which cannot be locked" do
      assert %{level: 2} = resolved(input([at(6), at(2)]))
    end
  end

  describe "the tiers" do
    test "are each the most specific entry that goes with the provider" do
      choices = [
        at(2, tiers: %{"light" => "small"}),
        at(3, tiers: %{"light" => "mid", "fast" => %{"model" => "big", "effort" => "low"}}),
        at(5, tiers: %{"thinking" => "big", "fast" => "small"})
      ]

      resolution = resolved(input(choices))

      assert resolution.tiers == %{
               "light" => %{"model" => "small"},
               "fast" => %{"model" => "big", "effort" => "low"},
               "thinking" => %{"model" => "big"}
             }

      assert resolution.tier_levels == %{"light" => 2, "fast" => 3, "thinking" => 5}
    end

    test "leave out a tier that no level maps" do
      assert %{tiers: tiers} = resolved(input([at(5, tiers: %{"fast" => "small"})]))
      assert tiers == %{"fast" => %{"model" => "small"}}
      assert %{tiers: %{}} = resolved(input([at(5)]))
    end

    test "take a model the provider does not list, with no effort" do
      choices = [at(2, tiers: %{"fast" => "not-listed", "light" => "small"})]
      assert %{tiers: tiers} = resolved(input(choices))
      assert tiers == %{"fast" => %{"model" => "not-listed"}, "light" => %{"model" => "small"}}

      choices = [at(5, connection_id: @gamma, tiers: %{"fast" => "team-small"})]
      assert %{tiers: %{"fast" => %{"model" => "team-small"}}} = resolved(input(choices))
    end

    test "skip a level whose effort does not go with its model, then read the next level" do
      choices = [
        at(2,
          tiers: %{
            "fast" => %{"model" => "not-listed", "effort" => "low"},
            "light" => %{"model" => "mid", "effort" => "low"}
          }
        ),
        at(5, tiers: %{"fast" => "small", "light" => "small"})
      ]

      assert %{tiers: tiers, tier_levels: levels} = resolved(input(choices))
      assert tiers == %{"fast" => %{"model" => "small"}, "light" => %{"model" => "small"}}
      assert levels == %{"fast" => 5, "light" => 5}
    end

    test "go with the resolved provider's models, whatever provider a level chose" do
      choices = [
        at(2, connection_id: @beta, tiers: %{"fast" => %{"model" => "big", "effort" => "low"}}),
        at(5, model_id: "mid")
      ]

      assert %{connection_id: @beta, tiers: %{}} = resolved(input(choices))

      choices = [at(2, connection_id: @beta, tiers: %{"fast" => "other"})]
      assert %{tiers: %{"fast" => %{"model" => "other"}}} = resolved(input(choices))
    end

    test "of a lock win over the levels below, tier by tier" do
      choices = [
        at(5, locked: true, tiers: %{"fast" => "mid"}),
        at(2, tiers: %{"fast" => "small", "light" => "small"}),
        at(3, tiers: %{"thinking" => "big"})
      ]

      assert %{tiers: tiers} = resolved(input(choices))

      assert tiers == %{
               "fast" => %{"model" => "mid"},
               "light" => %{"model" => "small"},
               "thinking" => %{"model" => "big"}
             }
    end

    test "leave out a tier whose effort the model does not list" do
      choices = [at(2, tiers: %{"light" => %{"model" => "mid", "effort" => "low"}})]
      assert %{tiers: %{}} = resolved(input(choices))
    end
  end

  test "calls no repo module and no query module" do
    {:ok, {_module, [imports: imports]}} =
      :beam_lib.chunks(:code.which(Resolution), [:imports])

    modules = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    refute Apiary.Repo in modules
    refute Ecto.Query in modules
    refute Ecto.Adapters.SQL in modules
  end
end
