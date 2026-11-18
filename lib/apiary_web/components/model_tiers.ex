defmodule ApiaryWeb.ModelTiers do
  # One key and the three tiers of a model choice (`Apiary.ModelChoices`), as a form sets
  # them: the state of the form, and `tiers/1`, the one component that draws the tiers.
  # Workspace settings › Model (`ApiaryWeb.ModelChoiceLive`) and each workflow's fold on
  # the Workflows page (`ApiaryWeb.StagesLive.ModelPart`) use both, and every other form
  # that sets tiers is to use them too, so a change of the tiers' look is made here.
  #
  # The state:
  #
  #   * `keys/2` the keys a form offers, each a key entry: `value`, the provider's public
  #     id, a slash and the key's value id; `label`, "<Provider> · <key>"; the `provider`;
  #     its `value_id`; the provider's `models`, as `Apiary.ModelChoices.suggestions/2`
  #     lists them; and `free`, true for a provider whose description lists no models,
  #     whose tiers take any model id as text;
  #   * `chosen/2` the entry of a stored choice's key, `params/2` and `stored/1` the
  #     tiers of a stored choice, `sent/5` the tiers a form sent, fitted to the key;
  #   * `complete?/2` whether every tier has a model, as a save at levels 4, 5 and 6
  #     needs (`Apiary.ModelChoices.put_choice/4`), and `attrs/2` what a save sends;
  #   * `field_errors/2` each refusal of a save on the field it is about.
  #
  # The tiers' values are a map of each tier of `Apiary.ModelChoices.Resolution.tiers/0`
  # to its `model` and `effort`, each "" for none.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.ModelChoices
  alias Apiary.ModelChoices.{ModelChoice, Resolution}
  alias Apiary.Connections.Connection

  @doc "The tiers in the order a form shows them: the most capable first."
  @spec shown() :: [String.t()]
  def shown, do: Enum.reverse(Resolution.tiers())

  @doc "The tiers' values with no model and no effort."
  @spec blank() :: map
  def blank, do: Map.new(shown(), &{&1, blank_tier()})

  defp blank_tier, do: %{"model" => "", "effort" => ""}

  ## Keys

  @doc """
  The keys of `providers`, each a map of `provider`, `models`, `free` and `offered` as a
  page lists its providers, in their order, each provider's keys by value id; and the
  key of `stored`, a stored choice, where its provider is among them and the list lacks
  the key, so a save does not change it unseen. A provider that is not offered
  (`offered: false`, `Apiary.Kinds.Providers.offered?/1`) gives only that key.
  """
  @spec keys([map], ModelChoice.t() | nil) :: [map]
  def keys(providers, stored) do
    listed =
      for %{provider: provider} = entry <- providers,
          Map.get(entry, :offered, true),
          value_id <- value_ids(provider),
          do: key_entry(provider, value_id, entry.models, entry.free)

    with %ModelChoice{connection_id: id} = choice <- stored,
         nil <- chosen(listed, choice),
         %{provider: provider} = entry <- Enum.find(providers, &(&1.provider.id == id)) do
      value_id = choice.value_id || provider.default_value_id
      listed ++ [key_entry(provider, value_id, entry.models, entry.free)]
    else
      _listed -> listed
    end
  end

  defp value_ids(%Connection{secret: %{values: values}}) when is_list(values),
    do: Enum.map(values, & &1.value_id)

  defp value_ids(_provider), do: []

  defp key_entry(%Connection{} = provider, value_id, models, free) do
    %{
      value: if(value_id, do: provider.public_id <> "/" <> value_id, else: provider.public_id),
      label:
        if(value_id,
          do: gettext("%{provider} · %{key}", provider: provider.name, key: value_id),
          else: provider.name
        ),
      provider: provider,
      value_id: value_id,
      models: models,
      free: free
    }
  end

  @doc "The options of a Key `choice` input for `keys`."
  @spec key_options([map]) :: [map]
  def key_options(keys), do: for(key <- keys, do: %{value: key.value, title: key.label})

  @doc "The entry of `keys` whose value is `value`, nil for none."
  @spec find([map], term) :: map | nil
  def find(keys, value), do: Enum.find(keys, &(&1.value == value))

  @doc """
  The entry of `keys` that is the key of `choice`: its provider's default key for a
  choice that names none. nil for none.
  """
  @spec chosen([map], ModelChoice.t() | nil) :: map | nil
  def chosen(_keys, nil), do: nil

  def chosen(keys, %ModelChoice{connection_id: id, value_id: value_id}) do
    Enum.find(keys, fn key ->
      key.provider.id == id and key.value_id == (value_id || key.provider.default_value_id)
    end)
  end

  ## Values

  @doc """
  The tiers' values of `choice` while `key` is its key's entry; else `blank/0`. A tier
  the choice leaves out is blank.
  """
  @spec params(ModelChoice.t() | nil, map | nil) :: map
  def params(%ModelChoice{} = choice, %{} = key) do
    if chosen([key], choice), do: tier_values(choice.tiers), else: blank()
  end

  def params(_choice, _key), do: blank()

  defp tier_values(tiers) do
    tiers = tiers || %{}

    Map.new(shown(), fn tier ->
      case tiers[tier] do
        model when is_binary(model) ->
          {tier, %{"model" => model, "effort" => ""}}

        %{"model" => model} = entry when is_binary(model) ->
          {tier, %{"model" => model, "effort" => entry["effort"] || ""}}

        _none ->
          {tier, blank_tier()}
      end
    end)
  end

  @doc """
  What `sent/5` reads of a stored choice: its provider's row id and its tiers' values;
  nil for none.
  """
  @spec stored(ModelChoice.t() | nil) :: map | nil
  def stored(%ModelChoice{connection_id: id} = choice) when is_binary(id),
    do: %{provider_id: id, tiers: tier_values(choice.tiers)}

  def stored(_choice), do: nil

  @doc """
  The tiers' values a form sent, for the key `key`, after the key `before`, with `old`
  the values before. While the provider stays the same, a tier keeps a model of its list,
  or its model as it was, and an effort of that model (`efforts/3`); a field the form did
  not send is as it was, so a disabled Effort keeps its effort while its model stays.
  Another provider's key, or none, leaves every tier blank. A provider whose description
  lists no models takes any model id, and no effort.
  """
  @spec sent(map | nil, map | nil, map, term, map | nil) :: map
  def sent(key, before, old, values, stored) do
    if key != nil and before != nil and key.provider.id == before.provider.id do
      values = if is_map(values), do: values, else: %{}

      Map.new(shown(), fn tier ->
        was = old[tier] || blank_tier()
        sent = if is_map(values[tier]), do: values[tier], else: %{}
        model = string(sent["model"], was["model"])
        kept? = model == was["model"]
        effort = string(sent["effort"], if(kept?, do: was["effort"], else: ""))

        {tier, fit(key, tier, String.trim(model), effort, kept?, stored)}
      end)
    else
      blank()
    end
  end

  defp string(value, _default) when is_binary(value), do: value
  defp string(_value, default), do: default

  defp fit(_key, _tier, "", _effort, _kept?, _stored), do: blank_tier()

  defp fit(%{free: true}, _tier, model, _effort, _kept?, _stored),
    do: %{"model" => model, "effort" => ""}

  defp fit(key, tier, model, effort, kept?, stored) do
    if kept? or Enum.any?(key.models, &(&1.id == model)) do
      efforts = efforts(key, model, stored_effort(key, tier, model, stored))
      %{"model" => model, "effort" => if(effort in efforts, do: effort, else: "")}
    else
      blank_tier()
    end
  end

  # The effort the stored choice has for `tier`, while `key` is of its provider and the
  # tier keeps its model; else "".
  defp stored_effort(key, tier, model, %{provider_id: id, tiers: tiers}) do
    if key.provider.id == id and tiers[tier]["model"] == model,
      do: tiers[tier]["effort"],
      else: ""
  end

  defp stored_effort(_key, _tier, _model, _stored), do: ""

  # The effort values a tier offers for `model`: the model's offered effort values, and
  # `stored`, the stored choice's effort for it, where they lack it.
  defp efforts(nil, _model, _stored), do: []

  defp efforts(key, model, stored) do
    offered =
      case Enum.find(key.models, &(&1.id == model)) do
        %{effort: effort} when is_list(effort) -> effort
        _none -> []
      end

    if stored in ["", nil] or stored in offered, do: offered, else: offered ++ [stored]
  end

  # The models a tier offers: the provider's, by title, and the tier's model where the
  # list lacks it, by its id.
  defp models(key, model) do
    listed = for m <- key.models, do: {m.title || m.id, m.id}

    if model == "" or Enum.any?(key.models, &(&1.id == model)),
      do: listed,
      else: listed ++ [{model, model}]
  end

  @doc "Whether `key` is chosen and every tier has a model."
  @spec complete?(map | nil, map) :: boolean
  def complete?(nil, _tiers), do: false

  def complete?(_key, tiers),
    do: Enum.all?(shown(), &(String.trim((tiers[&1] || %{})["model"] || "") != ""))

  @doc """
  What a save of `key` and `tiers` sends to `Apiary.ModelChoices.put_choice/4`:
  `provider`, `key` and `tiers`, each tier with a model, its effort where it has one;
  and `model` and `effort`, those of the `thinking` tier, as the run's model and effort
  are (`Apiary.ModelChoices.Resolution`), so a page that reads the choice's model shows
  the run's.
  """
  @spec attrs(map, map) :: map
  def attrs(key, tiers) do
    sent =
      for {tier, %{"model" => model} = set} <- tiers, model != "", into: %{} do
        if set["effort"] in ["", nil],
          do: {tier, %{"model" => model}},
          else: {tier, %{"model" => model, "effort" => set["effort"]}}
      end

    thinking = sent["thinking"] || %{}

    %{
      provider: key.provider.public_id,
      key: key.value_id,
      tiers: sent,
      model: thinking["model"],
      effort: thinking["effort"]
    }
  end

  ## Refusals

  @doc """
  Each refusal of a save, a changeset error, on the field it is about: `:key` for the
  provider, the key and any field the form does not have, `:runtime` for the runtime,
  `{tier, :model}` or `{tier, :effort}` for a tier's, and `:tiers` for a refusal of the
  tiers that names neither a tier nor a model, which shows above them. `model` and
  `effort` are the `thinking` tier's (`attrs/2`), so their refusals are its; a refusal
  on the same field with the same text is shown once.
  """
  @spec field_errors(keyword, map) :: [{atom | {String.t(), atom}, {String.t(), keyword}}]
  def field_errors(errors, tiers) do
    placed =
      for {field, {_message, opts} = error} <- errors do
        case field do
          field when field in [:provider, :key] -> {:key, error}
          :model -> {{"thinking", :model}, error}
          :effort -> {{"thinking", :effort}, error}
          :tiers -> {tier_field(opts, tiers), error}
          :runtime -> {:runtime, error}
          _other -> {:key, error}
        end
      end

    Enum.uniq_by(placed, fn {field, {message, _opts}} -> {field, message} end)
  end

  # The field of a refusal of the tiers: the tier it names (`tier`) and the field it is
  # about (`field`, Model where it names none); for a refusal with no tier, the first tier
  # with the model it names; else none.
  defp tier_field(opts, tiers) do
    by_name = Enum.find(shown(), &(opts[:tier] == ModelChoices.tier_name(&1)))
    model = opts[:model]

    cond do
      by_name ->
        {by_name, if(opts[:field] == :effort, do: :effort, else: :model)}

      is_binary(model) and opts[:provider] ->
        with_model(tiers, model, :model, fn _set -> true end)

      is_binary(model) ->
        with_model(tiers, model, :effort, &(&1["effort"] not in ["", nil]))

      true ->
        :tiers
    end
  end

  defp with_model(tiers, model, field, also) do
    case Enum.find(shown(), &(tiers[&1]["model"] == model and also.(tiers[&1]))) do
      nil -> :tiers
      tier -> {tier, field}
    end
  end

  ## Drawing

  @doc "The line under a tier's name."
  @spec line(String.t()) :: String.t()
  def line("thinking"), do: gettext("Plans and reviews: the most capable model.")
  def line("balanced"), do: gettext("Writes and runs most steps.")
  def line("light"), do: gettext("Simple, scripted steps: the cheapest model.")

  attr :id, :string, required: true, doc: "the id of the section; each tier's id starts with it"
  attr :name, :string, required: true, doc: "the name the tiers' fields start with"
  attr :key, :map, default: nil, doc: "the chosen key's entry (`keys/2`)"
  attr :tiers, :map, required: true, doc: "the tiers' values"
  attr :stored, :map, default: nil, doc: "the stored choice, as `stored/1` gives it"
  attr :errors, :list, default: [], doc: "the refusals, as `field_errors/2` places them"
  attr :disabled, :boolean, default: false

  attr :form, :string,
    default: nil,
    doc: "the id of the form the fields belong to, where it is not the form they are in"

  attr :field_id, :string,
    default: nil,
    doc: "what each field's id starts with; by default `name` with its brackets as `_`"

  attr :stacked, :boolean,
    default: false,
    doc: "whether each tier's name and line stay above its fields at every width"

  @doc """
  The tiers of `key`: one section, "Model and effort per tier", with a group per tier,
  its name and line as the group's legend, then its Model and Effort. Model lists the
  provider's models; Effort the effort values of the tier's model, disabled where it has
  none. For a provider whose description lists no models, the section is "Model per
  tier", and each tier has a text field Model and no Effort. A refusal shows under its
  field, and one that names no tier above the tiers.
  """
  def tiers(assigns) do
    key = assigns.key

    base =
      assigns.field_id ||
        assigns.name |> String.replace(~r/[\[\]]+/, "_") |> String.trim("_")

    errors = assigns.errors

    rows =
      for tier <- shown() do
        values = assigns.tiers[tier] || blank_tier()
        model = values["model"] || ""

        %{
          tier: tier,
          id: "#{assigns.id}-#{tier}",
          name: "#{assigns.name}[#{tier}]",
          field_id: "#{base}_#{tier}",
          model: model,
          effort: values["effort"] || "",
          models: if(key, do: models(key, model), else: []),
          efforts: efforts(key, model, stored_effort(key, tier, model, assigns.stored)),
          model_errors: messages(errors, {tier, :model}),
          effort_errors: messages(errors, {tier, :effort})
        }
      end

    assigns =
      assign(assigns,
        free: key != nil and key.free,
        rows: rows,
        head_errors: messages(errors, :tiers)
      )

    ~H"""
    <section id={@id} class="q-sect" aria-labelledby={"#{@id}-h"}>
      <header>
        <h3 id={"#{@id}-h"}>
          {if @free, do: gettext("Model per tier"), else: gettext("Model and effort per tier")}
        </h3>
      </header>
      <div :if={@head_errors != []} class="grid gap-1 px-4 pt-3">
        <.tier_error :for={{message, i} <- Enum.with_index(@head_errors)} id={"#{@id}-error-#{i}"}>
          {message}
        </.tier_error>
      </div>
      <ul class="q-rows">
        <li :for={row <- @rows} class="px-4 py-3">
          <fieldset
            id={row.id}
            class={[
              "grid min-w-0 gap-3",
              !@stacked && "lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]"
            ]}
            aria-describedby={"#{row.id}-line"}
          >
            <legend class="contents">
              <span class="grid gap-0.5">
                <span class="text-[14px]/5 font-medium">{ModelChoices.tier_name(row.tier)}</span>
                <span id={"#{row.id}-line"} class="text-[12.5px]/[18px] text-muted">
                  {line(row.tier)}
                </span>
              </span>
            </legend>
            <fieldset :if={@free} class="fieldset min-w-0">
              <label for={"#{row.field_id}_model"} class="text-[12px]/4 font-medium text-muted">
                {gettext("Model")}
              </label>
              <input
                type="text"
                id={"#{row.field_id}_model"}
                name={"#{row.name}[model]"}
                form={@form}
                value={row.model}
                class={["input input-sm w-full font-mono", row.model_errors != [] && "input-error"]}
                autocomplete="off"
                spellcheck="false"
                phx-debounce="300"
                aria-invalid={row.model_errors != [] && "true"}
                aria-describedby={error_ids("#{row.field_id}_model", row.model_errors)}
                disabled={@disabled}
              />
              <.tier_error
                :for={{message, i} <- Enum.with_index(row.model_errors)}
                id={error_id("#{row.field_id}_model", i)}
              >
                {message}
              </.tier_error>
            </fieldset>
            <div :if={!@free} class="grid gap-3 lg:flex">
              <fieldset class="fieldset min-w-0 flex-1">
                <label for={"#{row.field_id}_model"} class="text-[12px]/4 font-medium text-muted">
                  {gettext("Model")}
                </label>
                <select
                  id={"#{row.field_id}_model"}
                  name={"#{row.name}[model]"}
                  form={@form}
                  class={["select select-sm w-full", row.model_errors != [] && "select-error"]}
                  aria-invalid={row.model_errors != [] && "true"}
                  aria-describedby={error_ids("#{row.field_id}_model", row.model_errors)}
                  disabled={@disabled}
                >
                  <option value="" selected={row.model == ""}>{gettext("Choose a model")}</option>
                  {Phoenix.HTML.Form.options_for_select(row.models, row.model)}
                </select>
                <.tier_error
                  :for={{message, i} <- Enum.with_index(row.model_errors)}
                  id={error_id("#{row.field_id}_model", i)}
                >
                  {message}
                </.tier_error>
              </fieldset>
              <fieldset class="fieldset shrink-0">
                <label for={"#{row.field_id}_effort"} class="text-[12px]/4 font-medium text-muted">
                  {gettext("Effort")}
                </label>
                <select
                  id={"#{row.field_id}_effort"}
                  name={"#{row.name}[effort]"}
                  form={@form}
                  class={["select select-sm w-full", row.effort_errors != [] && "select-error"]}
                  aria-invalid={row.effort_errors != [] && "true"}
                  aria-describedby={error_ids("#{row.field_id}_effort", row.effort_errors)}
                  disabled={@disabled or row.efforts == []}
                >
                  <option value="" selected={row.effort == ""}>{gettext("Not set")}</option>
                  {Phoenix.HTML.Form.options_for_select(row.efforts, row.effort)}
                </select>
                <.tier_error
                  :for={{message, i} <- Enum.with_index(row.effort_errors)}
                  id={error_id("#{row.field_id}_effort", i)}
                >
                  {message}
                </.tier_error>
              </fieldset>
            </div>
          </fieldset>
        </li>
      </ul>
    </section>
    """
  end

  defp messages(errors, field),
    do: for({^field, error} <- errors, do: translate_error(error))

  # The ids of a field's refusals, as `ApiaryWeb.CoreComponents.input/1` gives them.
  defp error_id(id, 0), do: "#{id}-error"
  defp error_id(id, i), do: "#{id}-error-#{i + 1}"

  defp error_ids(_id, []), do: nil

  defp error_ids(id, errors),
    do: errors |> Enum.with_index() |> Enum.map_join(" ", fn {_, i} -> error_id(id, i) end)

  attr :id, :string, required: true
  slot :inner_block, required: true

  # A refusal's line, as `ApiaryWeb.CoreComponents.input/1` draws one.
  defp tier_error(assigns) do
    ~H"""
    <p id={@id} class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error">
      <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end
end
