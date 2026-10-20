defmodule Apiary.ModelChoices.Resolution do
  # What the model choices of a run's chain come to: one model provider, one of its keys,
  # one model, one effort value or none, and a tier map. Pure: choices and providers in,
  # a resolution out. `Apiary.ModelChoices` reads what it takes.
  #
  # The levels, from the most specific: 2, the target and the run kind; 3, the target;
  # 4, the workspace and the run kind; 5, the workspace; 6, the organisation's default
  # (`Apiary.ModelChoices.ModelChoice`). A run with no target has no levels 2 and 3.
  #
  # **The order.** A locked choice of the workspace (levels 4 and 5) comes first, the
  # more specific first; then levels 2 to 6, each once.
  #
  # **The provider, the key, the model and the effort** come from one choice: the first in
  # the order that chose a provider. A choice without a key takes the provider's default
  # key; without a model, the provider's default model, and then no effort, so the runtime
  # uses its default effort. No choice with a provider resolves to `:none`: the run uses
  # the gateway's key. A choice whose provider is not among `providers` resolves to
  # `{:error, :provider_removed}`.
  #
  # **The tiers**, each of `light`, `fast` and `thinking` by itself: the first choice in the
  # order whose tier map maps the tier to a model on the resolved provider's list, with an
  # effort value of that model's or none. A tier no choice maps so is left out: the run's
  # program fills it, or runs the agent on the run's model.
  @moduledoc false

  alias Apiary.ModelChoices.ModelChoice

  @tiers ~w(light fast thinking)

  @typedoc """
  A provider as the resolution reads it: the value id of its default key, and its models,
  each with its `model_id`, its `effort` values (nil for none) and whether it is the
  default.
  """
  @type provider :: %{
          required(:default_value_id) => String.t() | nil,
          required(:models) => [
            %{
              required(:model_id) => String.t(),
              required(:effort) => [String.t()] | nil,
              required(:is_default) => boolean
            }
          ]
        }

  @typedoc """
  What a resolution reads: the model choices of the organisation's chain at levels 2 to 6
  (rows of other places are left out here), the run's workspace, target (nil for none) and run kind, and the providers the choices name,
  by their row id.
  """
  @type input :: %{
          required(:choices) => [ModelChoice.t()],
          required(:workspace_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t() | nil,
          required(:run_kind) => String.t(),
          required(:providers) => %{Ecto.UUID.t() => provider}
        }

  @typedoc """
  A resolution: the provider's row id (`connection_id`), the key's `value_id`, the
  `model_id`, the `effort` value or nil, the `tiers`, each an object of `model` and, when
  it has one, `effort`, and the level each came from: `level` for the provider, the key,
  the model and the effort, and `tier_levels` for each tier.
  """
  @type t :: %__MODULE__{
          connection_id: Ecto.UUID.t(),
          value_id: String.t() | nil,
          model_id: String.t() | nil,
          effort: String.t() | nil,
          tiers: %{optional(String.t()) => %{required(String.t()) => String.t()}},
          level: ModelChoice.level(),
          tier_levels: %{optional(String.t()) => ModelChoice.level()}
        }

  @enforce_keys [:connection_id, :level]
  defstruct connection_id: nil,
            value_id: nil,
            model_id: nil,
            effort: nil,
            tiers: %{},
            level: nil,
            tier_levels: %{}

  @doc false
  # tiers/0 is the tiers a tier map may set.
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc false
  # resolve/1 is what `input` comes to: `{:ok, resolution}`, `:none` where no choice has a
  # provider, or `{:error, :provider_removed}`.
  @spec resolve(input) :: {:ok, t} | :none | {:error, :provider_removed}
  def resolve(%{} = input) do
    order = order(input)

    case Enum.find(order, &chose_provider?/1) do
      nil ->
        :none

      {level, choice} ->
        with {:ok, provider} <- provider(choice, input.providers) do
          {:ok, resolved(level, choice, provider, order)}
        end
    end
  end

  # The choices in the order of the moduledoc, each `{level, choice}`.
  defp order(input) do
    placed =
      for choice <- input.choices,
          level = place(choice, input),
          level != nil,
          do: {level, choice}

    by_level = Enum.sort_by(placed, &elem(&1, 0))
    {locked, rest} = Enum.split_with(by_level, fn {_level, choice} -> locked?(choice) end)
    locked ++ rest
  end

  # The level of `choice` for the run, or nil for a choice of another place.
  defp place(%ModelChoice{} = choice, input) do
    level = ModelChoice.level(choice)
    same_workspace = choice.workspace_id == input.workspace_id
    same_kind = choice.run_kind == input.run_kind

    same_target =
      not is_nil(input.target_id) and choice.target_id == input.target_id and same_workspace

    cond do
      level == 6 -> 6
      level == 5 and same_workspace -> 5
      level == 4 and same_workspace and same_kind -> 4
      level == 3 and same_target -> 3
      level == 2 and same_target and same_kind -> 2
      true -> nil
    end
  end

  defp locked?(%ModelChoice{locked: true}), do: true
  defp locked?(_choice), do: false

  defp chose_provider?({_level, %ModelChoice{connection_id: id}}), do: not is_nil(id)

  defp provider(%ModelChoice{connection_id: id}, providers) do
    case Map.fetch(providers, id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :provider_removed}
    end
  end

  defp resolved(level, choice, provider, order) do
    {model_id, effort} =
      case choice.model_id do
        nil -> {default_model(provider), nil}
        model_id -> {model_id, choice.effort}
      end

    tiers =
      for tier <- @tiers,
          {tier_level, entry} <- [tier(order, tier, provider)],
          entry != nil,
          do: {tier, tier_level, entry}

    %__MODULE__{
      connection_id: choice.connection_id,
      value_id: choice.value_id || provider.default_value_id,
      model_id: model_id,
      effort: effort,
      level: level,
      tiers: Map.new(tiers, fn {tier, _level, entry} -> {tier, entry} end),
      tier_levels: Map.new(tiers, fn {tier, tier_level, _entry} -> {tier, tier_level} end)
    }
  end

  defp default_model(%{models: models}),
    do: Enum.find_value(models, fn model -> model.is_default && model.model_id end)

  # The first entry for `tier` in the order whose model and effort the provider lists:
  # `{level, entry}`, or `{nil, nil}` for none.
  defp tier(order, tier, provider) do
    Enum.find_value(order, {nil, nil}, fn {level, choice} ->
      with %{} = tiers <- choice.tiers,
           %{"model" => _model} = entry <- entry(tiers[tier]),
           true <- listed?(provider, entry) do
        {level, entry}
      else
        _other -> nil
      end
    end)
  end

  defp entry(model) when is_binary(model), do: %{"model" => model}

  defp entry(%{"model" => model} = entry) when is_binary(model),
    do: Map.take(entry, ~w(model effort))

  defp entry(_other), do: nil

  defp listed?(%{models: models}, entry) do
    Enum.any?(models, fn model ->
      model.model_id == entry["model"] and
        (is_nil(entry["effort"]) or entry["effort"] in (model.effort || []))
    end)
  end
end
