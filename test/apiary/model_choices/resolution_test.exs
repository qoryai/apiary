defmodule Apiary.ModelChoices.ResolutionTest do
  # The resolution reads no table: choices and providers go in, one answer comes out.
  use ExUnit.Case, async: true

  alias Apiary.ModelChoices.{Fallback, ModelChoice, Resolution}

  @workspace "00000000-0000-0000-0000-0000000000a1"
  @other_workspace "00000000-0000-0000-0000-0000000000a2"
  @target "00000000-0000-0000-0000-0000000000b1"
  @other_target "00000000-0000-0000-0000-0000000000b2"
  @alpha "00000000-0000-0000-0000-0000000000c1"
  @beta "00000000-0000-0000-0000-0000000000c2"
  @gamma "00000000-0000-0000-0000-0000000000c3"
  @delta "00000000-0000-0000-0000-0000000000c4"

  @providers %{
    @alpha => %{
      default_model_id: "big",
      models: [
        %{model_id: "big", effort: ["low", "high"]},
        %{model_id: "small", effort: nil},
        %{model_id: "mid", effort: ["high"]}
      ],
      # A model the suggestions list beside the description's.
      suggested: ["suggested"]
    },
    @beta => %{
      default_model_id: "other",
      models: [%{model_id: "other", effort: nil}]
    },
    # A provider whose description lists no model.
    @gamma => %{default_model_id: nil, models: []},
    # A provider whose description lists no effort values.
    @delta => %{
      default_model_id: "plain",
      models: [%{model_id: "plain", effort: nil}]
    }
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

  defp fallback(position, connection_id, attrs \\ []),
    do: struct!(Fallback, [position: position, connection_id: connection_id] ++ attrs)

  # A tier map with `entry` on every tier.
  defp all_tiers(entry), do: Map.new(Resolution.tiers(), &{&1, entry})

  defp resolved(input) do
    assert {:ok, %Resolution{} = resolution} = Resolution.resolve(input)
    resolution
  end

  describe "in_effect/1" do
    test "is the choice the resolution takes its provider from: locked first, then the most specific" do
      five = at(5, model_id: "big")
      four = at(4, model_id: "small")
      locked = %{five | locked: true}
      no_provider = at(2, connection_id: nil, tiers: %{"balanced" => "small"})

      assert {4, ^four} = Resolution.in_effect(input([five, four, no_provider]))
      assert {5, ^locked} = Resolution.in_effect(input([locked, four]))
      assert {5, ^five} = Resolution.in_effect(input([five, four], workflow: nil))
      assert Resolution.in_effect(input([no_provider])) == nil

      # A choice whose provider is not among the providers is still the one in effect.
      gone = at(5, connection_id: "00000000-0000-0000-0000-0000000000c9")
      assert {5, ^gone} = Resolution.in_effect(input([gone]))
    end
  end

  describe "the provider, the model and the effort" do
    test "come from the most specific level that chose a provider" do
      choices = for level <- 2..6, do: at(level, model_id: "level#{level}")

      assert %{level: 2, model_id: "level2"} = resolved(input(choices))

      for level <- 2..6 do
        rest = Enum.filter(choices, &(ModelChoice.level(&1) >= level))
        assert %{level: ^level, model_id: model} = resolved(input(rest))
        assert model == "level#{level}"
      end
    end

    test "skip a level that sets only tiers" do
      only_tiers = at(2, connection_id: nil, tiers: %{"balanced" => %{"model" => "small"}})

      assert %{level: 5, model_id: "mid"} =
               resolved(input([only_tiers, at(5, model_id: "mid")]))
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

      assert Resolution.resolve(
               input([at(5, connection_id: nil, tiers: %{"balanced" => "small"})])
             ) ==
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
      locked = at(5, connection_id: nil, locked: true, tiers: %{"balanced" => "small"})
      assert %{level: 2, model_id: "mid"} = resolved(input([locked, at(2, model_id: "mid")]))
    end

    test "does not hold from level 6, which cannot be locked" do
      assert %{level: 2} = resolved(input([at(6), at(2)]))
    end
  end

  describe "the tiers" do
    # Changed: each tier came from the most specific level; now all come from one choice.
    test "come from the choice in effect alone, never from another level" do
      choices = [
        at(2, tiers: %{"light" => "small"}),
        at(3, tiers: %{"light" => "mid", "balanced" => %{"model" => "big", "effort" => "low"}}),
        at(5, tiers: %{"thinking" => "big", "balanced" => "small"})
      ]

      assert %{level: 2, tiers: tiers} = resolved(input(choices))
      assert tiers == %{"light" => %{"model" => "small"}}
    end

    # Changed: a tier the choice in effect leaves out no longer comes from a level below.
    test "leave out a tier that the choice in effect does not map" do
      assert %{tiers: tiers} = resolved(input([at(5, tiers: %{"balanced" => "small"})]))
      assert tiers == %{"balanced" => %{"model" => "small"}}
      assert %{tiers: %{}} = resolved(input([at(5)]))

      # A level below that maps the other tiers is not read.
      choices = [at(4, tiers: %{"light" => "small"}), at(5, tiers: %{"thinking" => "big"})]
      assert %{level: 4, tiers: tiers} = resolved(input(choices))
      assert tiers == %{"light" => %{"model" => "small"}}
    end

    # Changed: an unlisted model went with any provider; now only one with no models takes it.
    test "take a model of the description or the suggestions, and any model of a provider that lists none" do
      choices = [at(2, tiers: %{"balanced" => "suggested", "light" => "small"})]
      assert %{tiers: tiers} = resolved(input(choices))
      assert tiers == %{"balanced" => %{"model" => "suggested"}, "light" => %{"model" => "small"}}

      # A model neither list has is left out.
      assert %{tiers: %{}} = resolved(input([at(2, tiers: %{"balanced" => "not-listed"})]))

      choices = [at(5, connection_id: @gamma, tiers: %{"balanced" => "team-small"})]
      assert %{tiers: %{"balanced" => %{"model" => "team-small"}}} = resolved(input(choices))
    end

    # Changed: a refused entry fell to the next level; now the tier is left out.
    test "leave out an entry whose effort does not go with its model, and read no level below" do
      choices = [
        at(2,
          tiers: %{
            "balanced" => %{"model" => "suggested", "effort" => "low"},
            "light" => %{"model" => "mid", "effort" => "low"}
          }
        ),
        at(5, tiers: %{"balanced" => "small", "light" => "small"})
      ]

      assert %{level: 2, tiers: %{}} = resolved(input(choices))
    end

    # Changed: an entry with no effort went with any provider; now it must be the provider's.
    test "leave out a model of another provider, with an effort or with none" do
      choices = [
        at(2,
          connection_id: @beta,
          tiers: %{"balanced" => %{"model" => "big", "effort" => "low"}}
        ),
        at(5, model_id: "mid")
      ]

      assert %{connection_id: @beta, tiers: %{}} = resolved(input(choices))

      # No effort: the model is still not one of the provider's.
      choices = [
        at(2, connection_id: @delta, tiers: %{"light" => "small", "thinking" => "plain"})
      ]

      assert %{tiers: tiers} = resolved(input(choices))
      assert tiers == %{"thinking" => %{"model" => "plain"}}

      choices = [at(2, connection_id: @beta, tiers: %{"balanced" => "other"})]
      assert %{tiers: %{"balanced" => %{"model" => "other"}}} = resolved(input(choices))
    end

    # Changed: a lock won tier by tier and levels below filled the rest; now it sets all tiers.
    test "of a lock are the only tiers: none come from the levels below" do
      choices = [
        at(5, locked: true, tiers: %{"balanced" => "mid"}),
        at(2, tiers: %{"balanced" => "small", "light" => "small"}),
        at(3, tiers: %{"thinking" => "big"})
      ]

      assert %{level: 5, tiers: tiers} = resolved(input(choices))
      assert tiers == %{"balanced" => %{"model" => "mid"}}
    end

    test "leave out a tier whose effort the model does not list" do
      choices = [at(2, tiers: %{"light" => %{"model" => "mid", "effort" => "low"}})]
      assert %{tiers: %{}} = resolved(input(choices))
    end
  end

  describe "the run's model and effort" do
    test "are the thinking tier's, over the choice's model" do
      tiers = %{
        "thinking" => %{"model" => "big", "effort" => "high"},
        "light" => %{"model" => "small"}
      }

      assert %{model_id: "big", effort: "high"} =
               resolved(input([at(5, model_id: "mid", effort: "high", tiers: tiers)]))

      assert %{model_id: "small", effort: nil} =
               resolved(input([at(5, tiers: %{"thinking" => "small"})]))
    end

    test "are the choice's model, else the provider's default, where the choice maps no thinking tier" do
      assert %{model_id: "mid", effort: "high"} =
               resolved(
                 input([at(5, model_id: "mid", effort: "high", tiers: %{"light" => "small"})])
               )

      assert %{model_id: "big", effort: nil} =
               resolved(input([at(5, tiers: %{"light" => "small"})]))
    end

    test "are none where the thinking entry does not go with the provider, so the run ends model_gone" do
      # A model neither list has, and an effort the model does not list.
      for thinking <- ["not-listed", %{"model" => "mid", "effort" => "low"}] do
        tiers = %{"thinking" => thinking, "light" => "small"}

        assert %{model_id: nil, effort: nil, tiers: %{"light" => %{"model" => "small"}}} =
                 resolved(input([at(5, model_id: "mid", effort: "high", tiers: tiers)]))
      end
    end
  end

  describe "a lock and an override" do
    test "the lock beats the override: no default step, and the lock's fallbacks" do
      locked =
        at(5,
          locked: true,
          tiers: all_tiers("mid"),
          fallbacks: [fallback(0, @beta)]
        )

      override = at(4, connection_id: @beta, tiers: all_tiers("other"))

      assert %{
               level: 5,
               connection_id: @alpha,
               default: nil,
               fallbacks: [%{connection_id: @beta}]
             } =
               resolution = resolved(input([override, locked]))

      assert resolution.tiers == all_tiers(%{"model" => "mid"})
      assert Resolution.default(input([override, locked])) == nil
    end
  end

  describe "the default step" do
    test "is the workspace's choice under a workflow's override, with its runtime and tiers" do
      override = at(4, connection_id: @beta, runtime: "first", tiers: all_tiers("other"))

      workspace =
        at(5,
          runtime: "second",
          tiers: %{"thinking" => %{"model" => "big", "effort" => "low"}, "light" => "small"}
        )

      organisation = at(6, connection_id: @gamma)

      resolution = resolved(input([override, workspace, organisation]))

      assert %{level: 4, connection_id: @beta, runtime: "first", model_id: "other"} = resolution
      assert resolution.tiers == all_tiers(%{"model" => "other"})

      assert %Resolution{
               level: 5,
               connection_id: @alpha,
               runtime: "second",
               model_id: "big",
               effort: "low",
               default: nil
             } = default = resolution.default

      assert default.tiers == %{
               "thinking" => %{"model" => "big", "effort" => "low"},
               "light" => %{"model" => "small"}
             }

      assert {5, ^workspace} = Resolution.default(input([override, workspace, organisation]))
    end

    test "is the organisation's default where the workspace sets no provider" do
      override = at(4, connection_id: @beta)
      tiers_only = at(5, connection_id: nil, tiers: %{"light" => "small"})
      organisation = at(6, tiers: %{"light" => "mid"})

      assert %{default: %{level: 6, connection_id: @alpha, tiers: tiers}} =
               resolved(input([override, tiers_only, organisation]))

      assert tiers == %{"light" => %{"model" => "mid"}}
    end

    test "follows the order under an override of the target's workflow: the target's choice first" do
      override = at(2, connection_id: @beta)
      workspace_override = at(4, connection_id: @gamma)
      choices = [override, workspace_override, at(3, runtime: "third"), at(5, runtime: "fifth")]

      assert %{default: %{level: 3, runtime: "third"}} = resolved(input(choices))
      assert %{default: %{level: 5}} = resolved(input([override, at(5), at(6)]))
    end

    test "comes from a level below the override: a locked level 4 falls to 5, never to 3" do
      choices = [at(4, locked: true, connection_id: @beta), at(3), at(5)]
      assert %{level: 4, default: %{level: 5}} = resolved(input(choices))

      # An override at level 2 with a provider at level 4 and none at level 3.
      choices = [at(2, connection_id: @beta), at(4, connection_id: @gamma), at(5)]
      assert %{level: 2, default: %{level: 5}} = resolved(input(choices))
    end

    test "is none without an override, without a choice below it, or for a provider that is gone" do
      assert %{default: nil} = resolved(input([at(5), at(6)]))
      assert %{default: nil} = resolved(input([at(4)]))

      gone = at(5, connection_id: "00000000-0000-0000-0000-0000000000c9")
      assert %{level: 4, default: nil} = resolved(input([at(4), gone]))
    end

    test "has the fallbacks: fallbacks stored on the override are not read" do
      override =
        at(4,
          connection_id: @beta,
          fallbacks: [fallback(0, @gamma, runtime: "first", tiers: all_tiers("any"))]
        )

      workspace =
        at(5,
          fallbacks: [
            fallback(0, @delta, runtime: "first", tiers: all_tiers("plain")),
            fallback(1, @beta, runtime: "second", tiers: all_tiers("other"))
          ]
        )

      resolution = resolved(input([override, workspace]))
      assert resolution.fallbacks == []

      assert resolution.default.fallbacks == [
               %{
                 connection_id: @delta,
                 runtime: "first",
                 tiers: all_tiers(%{"model" => "plain"}),
                 model_id: "plain",
                 effort: nil
               },
               %{
                 connection_id: @beta,
                 runtime: "second",
                 tiers: all_tiers(%{"model" => "other"}),
                 model_id: "other",
                 effort: nil
               }
             ]

      # With no default step, an override has no fallbacks.
      assert %{fallbacks: [], default: nil} = resolved(input([override]))
    end
  end

  describe "walk/1" do
    test "is the choices a run tries and the choice whose fallbacks follow them" do
      override = at(4, connection_id: @beta)
      workspace = at(5)

      assert Resolution.walk(input([override, workspace])) == {[override, workspace], workspace}
      assert Resolution.walk(input([workspace])) == {[workspace], workspace}
      assert Resolution.walk(input([override])) == {[override], nil}
      assert Resolution.walk(input([])) == {[], nil}
    end
  end

  describe "tier_ok?/2" do
    test "takes a model of the description or the suggestions, and any model where the description lists none" do
      provider = %{models: [%{model_id: "big", effort: nil}], suggested: ["suggested"]}

      assert Resolution.tier_ok?(provider, "big")
      assert Resolution.tier_ok?(provider, "suggested")
      refute Resolution.tier_ok?(provider, "other")

      # No suggestions.
      big = %{models: [%{model_id: "big", effort: ["high"]}]}
      assert Resolution.tier_ok?(big, "big")
      refute Resolution.tier_ok?(big, "other")

      # A description with no models takes any id, suggestions or none.
      assert Resolution.tier_ok?(%{models: [], suggested: ["only"]}, "other")
      assert Resolution.tier_ok?(%{models: []}, "anything")
    end
  end

  describe "the fallbacks" do
    test "come from the choice in effect, in their order, each with its runtime and tiers" do
      choice =
        at(5,
          fallbacks: [
            fallback(1, @gamma, runtime: "second", tiers: all_tiers("custom")),
            fallback(0, @beta, runtime: "first", tiers: all_tiers("other"))
          ]
        )

      # A level below with other fallbacks is not read.
      below = at(6, fallbacks: [fallback(0, @gamma, runtime: "first", tiers: all_tiers("x"))])

      assert resolved(input([choice, below])).fallbacks == [
               %{
                 connection_id: @beta,
                 runtime: "first",
                 tiers: all_tiers(%{"model" => "other"}),
                 model_id: "other",
                 effort: nil
               },
               %{
                 connection_id: @gamma,
                 runtime: "second",
                 tiers: all_tiers(%{"model" => "custom"}),
                 model_id: "custom",
                 effort: nil
               }
             ]
    end

    test "leave out a tier that does not go with the fallback's provider, and have no model without a thinking tier" do
      tiers = %{"thinking" => "big", "balanced" => "other", "light" => "other"}
      choice = at(5, fallbacks: [fallback(0, @beta, runtime: "first", tiers: tiers)])

      assert [fallback] = resolved(input([choice])).fallbacks

      assert fallback == %{
               connection_id: @beta,
               runtime: "first",
               tiers: %{"balanced" => %{"model" => "other"}, "light" => %{"model" => "other"}},
               model_id: nil,
               effort: nil
             }
    end

    test "keep the effort values that the fallback's runtime offers" do
      tiers = all_tiers(%{"model" => "big", "effort" => "high"})

      choice =
        at(5,
          connection_id: @beta,
          runtime: "first",
          fallbacks: [
            fallback(0, @alpha, runtime: "second", tiers: tiers),
            fallback(1, @delta, runtime: "first", tiers: all_tiers("plain"))
          ]
        )

      efforts = %{"first" => ["high"], "second" => ["low", "high"]}
      in_put = Map.put(input([choice]), :effort_values, efforts)

      assert [%{connection_id: @alpha, tiers: kept, model_id: "big", effort: "high"}, _delta] =
               resolved(in_put).fallbacks

      assert kept == tiers

      # The fallback's runtime offers no "high": its tiers with "high" are left out.
      in_put = Map.put(input([choice]), :effort_values, %{efforts | "second" => ["low"]})

      assert [%{connection_id: @alpha, tiers: %{}, model_id: nil, effort: nil}, _delta] =
               resolved(in_put).fallbacks
    end

    test "leave out a fallback whose provider is gone, and fallbacks that were not read" do
      gone = "00000000-0000-0000-0000-0000000000c9"

      choice =
        at(5,
          fallbacks: [
            fallback(0, gone, runtime: "first", tiers: all_tiers("x")),
            fallback(1, @beta, runtime: "first", tiers: all_tiers("other"))
          ]
        )

      assert [%{connection_id: @beta}] = resolved(input([choice])).fallbacks
      assert resolved(input([at(5)])).fallbacks == []
    end
  end

  describe "fallback/3" do
    test "gives the step the fallback's provider, runtime and tiers, and its thinking tier as the run's model" do
      fallback_tiers = %{
        "thinking" => %{"model" => "big", "effort" => "high"},
        "balanced" => "mid",
        "light" => "small"
      }

      choice =
        at(5,
          connection_id: @beta,
          runtime: "first",
          tiers: all_tiers("other"),
          fallbacks: [fallback(0, @alpha, runtime: "second", tiers: fallback_tiers)]
        )

      in_put = input([choice])
      resolution = resolved(in_put)
      [first] = resolution.fallbacks

      assert %Resolution{
               runtime: "second",
               connection_id: @alpha,
               model_id: "big",
               effort: "high",
               level: 5,
               default: nil,
               fallbacks: []
             } = fallen = Resolution.fallback(in_put, resolution, first)

      assert fallen.tiers == %{
               "thinking" => %{"model" => "big", "effort" => "high"},
               "balanced" => %{"model" => "mid"},
               "light" => %{"model" => "small"}
             }
    end

    test "of the default step keeps the default step's level, with the fallback's runtime" do
      override = at(4, connection_id: @beta, runtime: "first")

      workspace =
        at(5,
          runtime: "second",
          fallbacks: [fallback(0, @delta, runtime: "third", tiers: all_tiers("plain"))]
        )

      in_put = input([override, workspace])
      %{default: default} = resolved(in_put)

      assert %Resolution{level: 5, runtime: "third", connection_id: @delta, model_id: "plain"} =
               fallen = Resolution.fallback(in_put, default, hd(default.fallbacks))

      assert fallen.tiers == all_tiers(%{"model" => "plain"})
    end

    test "has no model where the fallback's thinking tier does not go with its provider" do
      tiers = %{"thinking" => "not-listed", "balanced" => "other", "light" => "other"}

      choice =
        at(5,
          tiers: all_tiers("small"),
          fallbacks: [fallback(0, @beta, runtime: "first", tiers: tiers)]
        )

      in_put = input([choice])
      resolution = resolved(in_put)

      assert %{model_id: nil, effort: nil, tiers: fallen_tiers} =
               Resolution.fallback(in_put, resolution, hd(resolution.fallbacks))

      assert fallen_tiers == %{
               "balanced" => %{"model" => "other"},
               "light" => %{"model" => "other"}
             }
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
