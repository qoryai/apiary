defmodule Apiary.Processes.SharedModelsTest do
  # The check that the model choices of a stage with shared_run fit one run: at most 6
  # model providers, fallbacks included, and no workflow with no model choice whose
  # runtime cannot use a provider the stage's runs can start on.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Providers
  alias Apiary.Processes

  defp stage(workflows) do
    %{
      "id" => "st_b0000000r1",
      "name" => "Build",
      "shared_run" => true,
      "sequence" => Enum.map(workflows, &%{"workflow" => &1}),
      "gate" => %{"kind" => "none"}
    }
  end

  defp provider(kind, name) do
    {:ok, description} = Providers.fetch(kind)
    {Ecto.UUID.generate(), %{name: name, description: {:ok, description}}}
  end

  defp choice(id, fallback_ids \\ []),
    do: {:ok, %{connection_id: id, fallbacks: Enum.map(fallback_ids, &%{connection_id: &1})}}

  defp models(choices, providers),
    do: %{choices: choices, providers: Map.new(providers)}

  test "six providers fit; a seventh, from a fallback alone, does not" do
    providers = for n <- 1..7, do: provider("anthropic", "Northwind #{n}")
    [p1, p2, p3, p4, p5, p6, p7] = Enum.map(providers, &elem(&1, 0))

    six = %{
      "plan" => choice(p1, [p2]),
      "build" => choice(p3, [p4, p5]),
      "review" => choice(p6, [p1])
    }

    stage = stage(["plan", "build", "review"])
    assert Processes.shared_models(stage, models(six, providers)) == :ok

    seven = Map.put(six, "review", choice(p6, [p7]))

    assert Processes.shared_models(stage, models(seven, providers)) ==
             {:error,
              {:too_many_providers, 7, for(n <- [1, 2, 3, 4, 5, 6, 7], do: "Northwind #{n}")}}
  end

  test "a workflow with no model choice fails where the runs can start on a provider its runtime cannot use" do
    {openai, _} = openai_entry = provider("openai", "Checkout models")
    {anthropic, _} = anthropic_entry = provider("anthropic", "Northwind")
    runtime = Apiary.ModelChoices.default_runtime().title

    stage = stage(["plan", "review"])
    on_openai = models(%{"plan" => choice(openai), "review" => :none}, [openai_entry])

    assert Processes.shared_models(stage, on_openai) ==
             {:error, {:model_choice_missing, "review", runtime, "Checkout models"}}

    on_anthropic = models(%{"plan" => choice(anthropic), "review" => :none}, [anthropic_entry])
    assert Processes.shared_models(stage, on_anthropic) == :ok

    # A fallback the runs can start on counts as a start provider too.
    with_fallback =
      models(%{"plan" => choice(anthropic, [openai]), "review" => :none}, [
        anthropic_entry,
        openai_entry
      ])

    assert {:error, {:model_choice_missing, "review", ^runtime, "Checkout models"}} =
             Processes.shared_models(stage, with_fallback)

    # A continuation starts on the provider of the session that paused, whose name and
    # description the claim reads with the stage's providers.
    both = &Map.put(&1, :providers, Map.new([anthropic_entry, openai_entry]))
    assert Processes.shared_models(stage, both.(on_openai), [anthropic]) == :ok

    assert {:error, {:model_choice_missing, "review", ^runtime, "Checkout models"}} =
             Processes.shared_models(stage, both.(on_anthropic), [openai])
  end

  test "the providers are checked before a missing choice" do
    providers = for n <- 1..6, do: provider("anthropic", "Northwind #{n}")
    {openai, _} = openai_entry = provider("openai", "Checkout models")
    [p1, p2, p3, p4, p5, p6] = Enum.map(providers, &elem(&1, 0))

    choices = %{
      "plan" => choice(openai, [p1, p2]),
      "build" => choice(p3, [p4, p5, p6]),
      "review" => :none
    }

    assert {:error, {:too_many_providers, 7, _names}} =
             Processes.shared_models(
               stage(["plan", "build", "review"]),
               models(choices, [openai_entry | providers])
             )
  end

  test "a default choice serves every workflow not listed" do
    {openai, _} = openai_entry = provider("openai", "Checkout models")

    models = %{choices: %{}, default: choice(openai), providers: Map.new([openai_entry])}
    assert Processes.shared_models(stage(["plan", "review"]), models) == :ok

    models = %{choices: %{}, default: :none, providers: %{}}
    assert Processes.shared_models(stage(["plan", "review"]), models) == :ok
  end
end
