defmodule Apiary.ModelChoices.Resolution do
  # What the model choices of a run's chain come to: one runtime, one model provider, one of
  # its keys, one model, one effort value or none, a tier map, the default step under a
  # workflow's override, and the fallbacks. Pure: choices and providers in, a resolution
  # out. `Apiary.ModelChoices` reads what it takes.
  #
  # The levels, from the most specific: 2, the target and the workflow; 3, the target;
  # 4, the workspace and the workflow; 5, the workspace; 6, the organisation's default
  # (`Apiary.ModelChoices.ModelChoice`). A run with no target has no levels 2 and 3, and
  # a run with no workflow no levels 2 and 4. A choice at level 2 or 4 is a workflow's
  # override.
  #
  # **The order.** A locked choice of the workspace (levels 4 and 5) comes first, the
  # more specific first; then levels 2 to 6, each once. A lock therefore comes before an
  # override.
  #
  # **The choice in effect** is the first in the order that chose a provider. The
  # runtime, the provider, the key and the tiers come from it alone. A choice without a
  # runtime takes the input's `default_runtime`, and a choice without a key the
  # provider's default key. No choice with a provider resolves to `:none`: the run uses
  # the gateway's key. A choice whose provider is not among `providers` resolves to
  # `{:error, :provider_removed}`.
  #
  # **The tiers**, each of `tiers/0`, come from the tier map of the choice in effect: an
  # entry is kept where its model goes with the choice's provider (`tier_ok?/2`), with no
  # effort or one of that model's effort values in the provider's description. Where the
  # input has `effort_values`, the effort values of each runtime by its name, a model's
  # effort values are those its runtime has too. A model that only the suggestions list,
  # and any model of a provider whose description lists none, takes no effort: an entry
  # of such a model with an effort is left out. No tier comes from another level, so one
  # run never mixes the tiers of two providers. A tier the choice leaves out or whose
  # entry does not go with the provider is left out.
  #
  # **The model and the effort** of the run are those of the `thinking` tier. A choice
  # whose `thinking` entry does not go with the provider has no model, and the claim ends
  # the run `model_gone` (`Apiary.Dispatches.RunSettings`). A choice that maps no
  # `thinking` tier gives its `model_id` and `effort`; without a model, the provider's
  # default model, the first of its description's, with no effort, so the runtime uses
  # its default effort. A provider whose description lists no model has no default: the
  # resolution then has no model.
  #
  # **The default step.** Where the choice in effect is a workflow's override, the
  # resolution has a `default`: the next choice in the order at a level without a
  # workflow (3, 5 or 6) below the override's level that chose a provider, resolved as
  # above, with its runtime, key and tiers. Under an override at level 4, that is level
  # 5, then 6; at level 2, level 3, then 5, then 6. A run uses it while every key of the
  # override's provider is in cooldown.
  # Its provider not among `providers`, or no such choice, gives no default step.
  #
  # **The fallbacks** come from the default step under an override, else from the choice
  # in effect; fallbacks stored on an override are not read.
  # They keep their order: each its provider's row id, its model, the provider's default
  # model where it names none, and its effort, none with the default model. A fallback
  # whose provider is not among `providers` is left out, and so are a choice's fallbacks
  # that were not read (`Ecto.Association.NotLoaded`). `fallback/3` is the resolution of
  # one of them: its model and effort on the run and on every tier.
  @moduledoc false

  alias Apiary.ModelChoices.{Fallback, ModelChoice}

  @tiers ~w(light fast thinking)
  # The tier whose model and effort are the run's (767 (a)).
  @run_tier "thinking"
  # The levels of a workflow's override.
  @override_levels [2, 4]

  @typedoc """
  A provider as the resolution reads it: the value id of its default key, the id of its
  default model (nil for none), its description's models, each with its `model_id` and
  its `effort` values (nil for none), and the ids of the models suggested for its kind
  (`suggested`, from `priv/models/suggestions.json`; none where the map leaves it out).
  """
  @type provider :: %{
          required(:default_value_id) => String.t() | nil,
          required(:default_model_id) => String.t() | nil,
          required(:models) => [
            %{required(:model_id) => String.t(), required(:effort) => [String.t()] | nil}
          ],
          optional(:suggested) => [String.t()]
        }

  @typedoc """
  What a resolution reads: the model choices of the organisation's chain at levels 2 to 6
  (rows of other places are left out here), the run's workspace, target (nil for none) and
  workflow (nil for none), and the providers the choices name, by their row id; and,
  where given, the runtime of a choice that names none (`default_runtime`) and the effort
  values of each runtime by its name (`effort_values`).
  """
  @type input :: %{
          required(:choices) => [ModelChoice.t()],
          required(:workspace_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t() | nil,
          required(:workflow) => String.t() | nil,
          required(:providers) => %{Ecto.UUID.t() => provider},
          optional(:default_runtime) => String.t(),
          optional(:effort_values) => %{String.t() => [String.t()]}
        }

  @typedoc """
  A fallback of a resolution: its provider's row id (`connection_id`), its `model_id`, nil
  where the provider has no default model, and its `effort` value or nil.
  """
  @type fallback :: %{
          connection_id: Ecto.UUID.t(),
          model_id: String.t() | nil,
          effort: String.t() | nil
        }

  @typedoc """
  A resolution: the `runtime`'s name, nil where the choice names none and the input has
  no default, the provider's row id (`connection_id`), the key's `value_id`, the
  `model_id`, the `effort` value or nil, the `tiers`, each an object of `model` and, when
  it has one, `effort`, the `level` of the choice they came from, the `default` step
  under a workflow's override (nil for none), and the `fallbacks`, in their order.
  """
  @type t :: %__MODULE__{
          runtime: String.t() | nil,
          connection_id: Ecto.UUID.t(),
          value_id: String.t() | nil,
          model_id: String.t() | nil,
          effort: String.t() | nil,
          tiers: %{optional(String.t()) => %{required(String.t()) => String.t()}},
          level: ModelChoice.level(),
          default: t | nil,
          fallbacks: [fallback]
        }

  @enforce_keys [:connection_id, :level]
  defstruct runtime: nil,
            connection_id: nil,
            value_id: nil,
            model_id: nil,
            effort: nil,
            tiers: %{},
            level: nil,
            default: nil,
            fallbacks: []

  @doc false
  # tiers/0 is the tiers a tier map may set.
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc false
  # tier_ok?/2 is whether a tier may use the model `model_id` of `provider`: a model of
  # its description or of its suggestions; any id for a provider whose description lists
  # no model. A save of a choice checks its tiers with it. The effort is checked apart.
  @spec tier_ok?(provider, String.t()) :: boolean
  def tier_ok?(%{models: []}, model_id) when is_binary(model_id), do: true

  def tier_ok?(%{models: models} = provider, model_id) when is_binary(model_id),
    do:
      Enum.any?(models, &(&1.model_id == model_id)) or
        model_id in Map.get(provider, :suggested, [])

  @doc false
  # resolve/1 is what `input` comes to: `{:ok, resolution}`, `:none` where no choice has a
  # provider, or `{:error, :provider_removed}`.
  @spec resolve(input) :: {:ok, t} | :none | {:error, :provider_removed}
  def resolve(%{} = input) do
    case in_effect(input) do
      nil ->
        :none

      {level, choice} ->
        with {:ok, provider} <- provider(choice, input.providers) do
          {:ok, resolved(level, choice, provider, input)}
        end
    end
  end

  @doc false
  # in_effect/1 is the choice of `input` that a resolution takes its provider, key, model,
  # effort and tiers from, as `{level, choice}`: the first in the order that chose a
  # provider, or nil for none. It reads only `input.choices` and the run's places.
  @spec in_effect(map) :: {ModelChoice.level(), ModelChoice.t()} | nil
  def in_effect(%{} = input), do: Enum.find(order(input), &chose_provider?/1)

  @doc false
  # default/1 is the choice of `input` that the default step comes from, as
  # `{level, choice}`: where the choice in effect is a workflow's override, the next in
  # the order at a level without a workflow, below the override's level, that chose a
  # provider; nil for none, and where the choice in effect is no override. It reads
  # only `input.choices` and the run's places.
  @spec default(map) :: {ModelChoice.level(), ModelChoice.t()} | nil
  def default(%{} = input) do
    order = order(input)

    case Enum.find(order, &chose_provider?/1) do
      {override_level, _override} when override_level in @override_levels ->
        Enum.find(order, fn {level, _choice} = placed ->
          level > override_level and level not in @override_levels and
            chose_provider?(placed)
        end)

      _no_override ->
        nil
    end
  end

  @doc false
  # walk/1 is the choices whose providers a run of `input` tries, in order: the choice in
  # effect, then the default step's choice where there is one; and the choice whose
  # fallbacks follow them, nil for none: the default step's under an override, else the
  # choice in effect's. An override with no default step has no fallbacks. It reads only
  # `input.choices` and the run's places.
  @spec walk(map) :: {[ModelChoice.t()], ModelChoice.t() | nil}
  def walk(%{} = input) do
    case {in_effect(input), default(input)} do
      {nil, _default} -> {[], nil}
      {{level, choice}, nil} when level in @override_levels -> {[choice], nil}
      {{_level, choice}, nil} -> {[choice], choice}
      {{_level, choice}, {_default_level, default}} -> {[choice, default], default}
    end
  end

  @doc false
  # fallback/3 is the step `step` of `input`, a resolution or its default step, with its
  # fallback `fallback` in place of its provider: the fallback's provider, the provider's
  # default key, and the fallback's model and effort as the run's and on every tier; the
  # same runtime and level, no default step and no fallbacks. The provider is among
  # `input.providers`, as each of the fallbacks is. A fallback with no model has no tiers.
  @spec fallback(input, t, fallback) :: t
  def fallback(%{} = input, %__MODULE__{} = step, %{connection_id: id} = fallback) do
    provider = Map.fetch!(input.providers, id)

    tiers =
      case fallback.model_id do
        nil ->
          %{}

        model_id ->
          entry = if fallback.effort, do: %{"effort" => fallback.effort}, else: %{}
          Map.new(@tiers, &{&1, Map.put(entry, "model", model_id)})
      end

    %{
      step
      | connection_id: id,
        value_id: provider.default_value_id,
        model_id: fallback.model_id,
        effort: fallback.effort,
        tiers: tiers,
        default: nil,
        fallbacks: []
    }
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
    same_workflow = is_binary(input.workflow) and choice.workflow == input.workflow

    same_target =
      not is_nil(input.target_id) and choice.target_id == input.target_id and same_workspace

    cond do
      level == 6 -> 6
      level == 5 and same_workspace -> 5
      level == 4 and same_workspace and same_workflow -> 4
      level == 3 and same_target -> 3
      level == 2 and same_target and same_workflow -> 2
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

  # The provider with each model's effort values those its runtime has too, where the
  # input has the runtimes' effort values.
  defp effort_of(provider, %{effort_values: values} = input, choice) do
    runtime_values = Map.get(values, choice.runtime || input[:default_runtime], [])

    models =
      for model <- provider.models do
        case Enum.filter(model.effort || [], &(&1 in runtime_values)) do
          [] -> %{model | effort: nil}
          effort -> %{model | effort: effort}
        end
      end

    %{provider | models: models}
  end

  defp effort_of(provider, _input, _choice), do: provider

  # The resolution of `choice` at `level` with its provider `provider`: under an override,
  # with the default step and the default step's fallbacks.
  defp resolved(level, choice, provider, input) do
    resolution = step(level, choice, provider, input)

    if level in @override_levels do
      %{resolution | fallbacks: [], default: default_step(input)}
    else
      resolution
    end
  end

  # The default step of `input`, nil for none or for a provider not among `providers`.
  defp default_step(input) do
    with {level, choice} <- default(input),
         {:ok, provider} <- provider(choice, input.providers) do
      step(level, choice, provider, input)
    else
      _none -> nil
    end
  end

  # One choice resolved alone: its runtime, provider, key, tiers, model, effort and
  # fallbacks.
  defp step(level, choice, provider, input) do
    provider = effort_of(provider, input, choice)

    tiers =
      for tier <- @tiers,
          entry = entry((choice.tiers || %{})[tier]),
          goes_with?(provider, entry),
          into: %{},
          do: {tier, entry}

    {model_id, effort} =
      cond do
        entry = tiers[@run_tier] -> {entry["model"], entry["effort"]}
        entry((choice.tiers || %{})[@run_tier]) -> {nil, nil}
        choice.model_id -> {choice.model_id, choice.effort}
        true -> {provider.default_model_id, nil}
      end

    %__MODULE__{
      runtime: choice.runtime || input[:default_runtime],
      connection_id: choice.connection_id,
      value_id: choice.value_id || provider.default_value_id,
      model_id: model_id,
      effort: effort,
      level: level,
      tiers: tiers,
      fallbacks: fallbacks(choice, input.providers)
    }
  end

  # The choice's fallbacks in their order, each whose provider is among `providers`.
  defp fallbacks(%ModelChoice{fallbacks: fallbacks}, providers) when is_list(fallbacks) do
    for %Fallback{connection_id: id} = fallback <- Enum.sort_by(fallbacks, & &1.position),
        {:ok, provider} <- [Map.fetch(providers, id)] do
      {model_id, effort} =
        case fallback.model_id do
          nil -> {provider.default_model_id, nil}
          model_id -> {model_id, fallback.effort}
        end

      %{connection_id: id, model_id: model_id, effort: effort}
    end
  end

  defp fallbacks(_choice, _providers), do: []

  defp entry(model) when is_binary(model), do: %{"model" => model}

  defp entry(%{"model" => model} = entry) when is_binary(model),
    do: Map.take(entry, ~w(model effort))

  defp entry(_other), do: nil

  # A tier model that goes with the provider (`tier_ok?/2`), with no effort, or a model of
  # the description with one of its effort values.
  defp goes_with?(provider, %{"model" => model} = entry) do
    tier_ok?(provider, model) and
      case entry["effort"] do
        nil ->
          true

        effort ->
          case Enum.find(provider.models, &(&1.model_id == model)) do
            nil -> false
            listed -> effort in (listed.effort || [])
          end
      end
  end
end
