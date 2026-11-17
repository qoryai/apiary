defmodule Apiary.ModelChoicesFixtures do
  # Tier maps for saves of model choices: a save at levels 4, 5 and 6 needs every tier of
  # `Apiary.ModelChoices.Resolution.tiers/0`, read here so no test names the tiers.
  @moduledoc false

  alias Apiary.{Connections, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.ModelChoices.Resolution

  @doc """
  every_tier/2 is a tier map with every tier on `model`, a model id, or on the default
  model of the provider `model` (`Connections.default_model/1`), `any-model` for a
  provider whose description lists none; with `effort` on each tier where it is not nil.
  """
  def every_tier(model, effort \\ nil)

  def every_tier(%Connection{} = provider, effort),
    do: every_tier(Connections.default_model(provider) || "any-model", effort)

  def every_tier(model, effort) when is_binary(model) do
    entry = if effort, do: %{"model" => model, "effort" => effort}, else: %{"model" => model}
    Map.new(Resolution.tiers(), &{&1, entry})
  end

  @doc """
  tiered/2 is `attrs`, a save of `Apiary.ModelChoices.put_choice/4` at `place`, with every
  tier on one model where the place is at level 4, 5 or 6 and `attrs` sends a provider and
  no tiers: the model `attrs` sends where a tier takes it (`Resolution.tier_ok?/2`), else
  the provider's default model (`every_tier/2`). Any other `attrs` is as given.
  """
  def tiered(attrs, place) do
    attrs = Map.new(attrs)
    string_keys? = Map.has_key?(attrs, "provider")
    provider_id = attrs[:provider] || attrs["provider"]
    sends_tiers? = Map.has_key?(attrs, :tiers) or Map.has_key?(attrs, "tiers")

    cond do
      not needs_every_tier?(place) or sends_tiers? or is_nil(provider_id) ->
        attrs

      provider = Repo.get_by(Connection, public_id: provider_id) ->
        model = attrs[:model] || attrs["model"]

        tiers =
          if is_binary(model) and
               Resolution.tier_ok?(Apiary.ModelChoices.resolution_provider(provider), model),
             do: every_tier(model),
             else: every_tier(provider)

        Map.put(attrs, if(string_keys?, do: "tiers", else: :tiers), tiers)

      true ->
        attrs
    end
  end

  @doc """
  put_choice/4 is `Apiary.ModelChoices.put_choice/4` with `attrs` as `tiered/2` gives them.
  """
  def put_choice(scope, place, attrs, chain \\ "organisation"),
    do: Apiary.ModelChoices.put_choice(scope, place, tiered(attrs, place), chain)

  defp needs_every_tier?(place),
    do: place in [:organisation, :workspace] or match?({:workspace, _workflow}, place)
end
