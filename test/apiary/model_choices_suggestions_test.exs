defmodule Apiary.ModelChoicesSuggestionsTest do
  # `Apiary.ModelChoices.suggestions/2` against the committed
  # `priv/models/suggestions.json`: each provider's models of the file, the description's
  # default model first, effort values from the description alone. The expectations are
  # read from the file and the descriptions, so a release that writes the file again
  # changes no test.
  use ExUnit.Case, async: true

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.Providers

  @file_models "priv/models/suggestions.json" |> File.read!() |> Jason.decode!()

  defp connection(kind) do
    {:ok, description} = Providers.fetch(kind)
    %Connection{provider_kind: kind, description_sha256: description.sha256}
  end

  defp file_ids(kind), do: for(%{"id" => id} <- @file_models[kind], do: id)

  test "the file has every provider of the catalogue, its models in the order of the id" do
    assert Enum.sort(Map.keys(@file_models)) == Enum.map(Providers.list(), & &1.name)

    for {_kind, models} <- @file_models do
      ids = Enum.map(models, & &1["id"])
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
    end
  end

  test "each provider gets the file's models, the default first, the rest in file order" do
    runtime = ModelChoices.default_runtime()

    for %{name: kind} <- Providers.list() do
      provider = connection(kind)
      ids = Enum.map(ModelChoices.suggestions(provider, runtime), & &1.id)

      case Connections.default_model(provider) do
        nil ->
          assert ids == file_ids(kind)

        default ->
          assert ids == [default | List.delete(file_ids(kind), default)]
      end
    end
  end

  test "a title comes from the file, effort values only from the description's model" do
    runtime = %{ModelChoices.default_runtime() | effort_values: ["low", "high"]}
    provider = connection("anthropic")
    described = Map.new(Connections.provider_models(provider), &{&1["id"], &1})
    titles = Map.new(@file_models["anthropic"], &{&1["id"], &1["title"]})

    for model <- ModelChoices.suggestions(provider, runtime) do
      assert model.title == (titles[model.id] || described[model.id]["title"])

      case described[model.id] do
        nil -> assert model.effort == []
        entry -> assert model.effort == Enum.filter(entry["effort"], &(&1 in ["low", "high"]))
      end
    end

    assert Enum.any?(ModelChoices.suggestions(provider, runtime), &(&1.effort != []))
  end

  test "a provider whose description lists no model gets the file's models, here none" do
    assert ModelChoices.suggestions(connection("litellm"), ModelChoices.default_runtime()) ==
             for(
               %{"id" => id, "title" => title} <- @file_models["litellm"],
               do: %{id: id, title: title, effort: []}
             )
  end
end
