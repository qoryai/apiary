defmodule ApiaryWeb.ModelTiers do
  # One model provider, the three tiers and the runtime of a model choice
  # (`Apiary.ModelChoices`), as a form sets them: the state of the form, and `tiers/1` and `runtime_part/1`, the
  # components that draw the tiers and Runtime.
  # Workspace settings › Model (`ApiaryWeb.ModelChoiceLive`), each workflow's fold on
  # the Workflows page (`ApiaryWeb.StagesLive.ModelPart`) and the Model step of a
  # workspace's set-up (`ApiaryWeb.WorkspaceSetupLive`) use both, and every other form
  # that sets tiers is to use them too, so a change of the tiers' look is made here.
  #
  # The state:
  #
  #   * `key_groups/1` the providers a form offers of those that serve a workspace, one per
  #     key group, each named by its group's label;
  #   * `entries/2` the providers a form offers, each a provider entry: `value`, the
  #     provider's public id; `label`, the provider's name; the `provider`;
  #     `provider_ref`, the provider's row id; the provider's `models`, as
  #     `Apiary.ModelChoices.suggestions/2` lists them; and `free`, true for a provider
  #     whose description lists no models, whose tiers take any model id as text.
  #     `entry/3` makes one provider entry, also of a catalogue provider not added yet
  #     (`Apiary.Kinds.Provider`), whose `provider_ref` is `{:kind, name}`;
  #   * `chosen/2` the entry of a stored choice's provider, `params/2` and `stored/1` the
  #     tiers of a stored choice, `sent/5` the tiers a form sent, fitted to the provider;
  #   * `complete?/2` whether every tier has a model, as a save at levels 4, 5 and 6
  #     needs (`Apiary.ModelChoices.put_choice/4`), and `attrs/2` what a save sends;
  #   * `field_errors/2` each refusal of a save on the field it is about;
  #   * `runtime/2` the runtime a form shows for a provider that serves a list of
  #     runtimes, `accepted/2` a stored choice's tiers without the efforts a runtime does
  #     not accept, and `runtime_part/1`, Runtime under the tiers, with its line
  #     (`runtime_line/2`).
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
  alias Apiary.Kinds.Providers
  alias Apiary.ModelKeys.Group
  alias Apiary.Kinds.{Provider, Runtime}

  @doc "The tiers in the order a form shows them: the most capable first."
  @spec shown() :: [String.t()]
  def shown, do: Enum.reverse(Resolution.tiers())

  @doc "The tiers' values with no model and no effort."
  @spec blank() :: map
  def blank, do: Map.new(shown(), &{&1, blank_tier()})

  defp blank_tier, do: %{"model" => "", "effort" => ""}

  ## Providers

  @doc """
  Of `providers`, rows that serve one workspace, the first provider of each key group
  (`Apiary.ModelKeys.Group.firsts/1`), each with its group's label as its `name`: the
  title of its kind in the catalogue, with its address for a kind whose endpoint is a
  setting, such as LiteLLM ("LiteLLM at https://litellm.example.com"); its name for a kind
  the catalogue does not have. `{firsts, first_of}`, as `Group.firsts/1` returns them. A
  row so named is for a form to show, never to write.
  """
  @spec key_groups([Connection.t()]) :: {[Connection.t()], %{Ecto.UUID.t() => Ecto.UUID.t()}}
  def key_groups(providers) do
    {firsts, first_of} = Group.firsts(providers)
    {Enum.map(firsts, &%{&1 | name: group_label(&1)}), first_of}
  end

  defp group_label(%Connection{provider_kind: kind, settings: settings} = provider) do
    with true <- is_binary(kind),
         {:ok, %Apiary.Kinds.Provider{} = described} <- Providers.fetch(kind) do
      case addresses(described, settings) do
        [] ->
          described.title

        addresses ->
          gettext("%{provider} at %{address}",
            provider: described.title,
            address: Enum.join(addresses, ", ")
          )
      end
    else
      _not_described -> provider.name
    end
  end

  defp addresses(described, settings) do
    values =
      case Jason.decode(settings || "{}") do
        {:ok, %{} = values} -> values
        _not_a_map -> %{}
      end

    for name <- Apiary.Kinds.Provider.address_settings(described),
        is_binary(values[name]),
        do: values[name]
  end

  @doc """
  The provider entries of `providers`, each a map of `provider`, `models`, `free` and
  `offered` as a page lists its providers, in their order; a provider that is not offered
  (`offered: false`, `Apiary.Kinds.Providers.offered?/1`) only where it is the provider
  of `stored`, a stored choice, so a save does not change it unseen.
  """
  @spec entries([map], ModelChoice.t() | nil) :: [map]
  def entries(providers, stored) do
    saved = stored && stored.connection_id

    for %{provider: provider} = entry <- providers,
        Map.get(entry, :offered, true) or provider.id == saved,
        do: provider_entry(provider, entry.models, entry.free)
  end

  @doc """
  One provider entry, as `entries/2` lists them: of `provider`, a model provider of the
  organisation; or of a catalogue provider not added yet, whose `value` is its name,
  `label` its title and `provider_ref` `{:kind, name}`. `models` and `free` as
  `entries/2` has them.
  """
  @spec entry(Connection.t() | Provider.t(), [map], boolean) :: map
  def entry(%Connection{} = provider, models, free), do: provider_entry(provider, models, free)

  def entry(%Provider{} = provider, models, free) do
    %{
      value: provider.name,
      label: provider.title,
      provider: provider,
      provider_ref: {:kind, provider.name},
      models: models,
      free: free
    }
  end

  defp provider_entry(%Connection{} = provider, models, free) do
    %{
      value: provider.public_id,
      label: provider.name,
      provider: provider,
      provider_ref: provider.id,
      models: models,
      free: free
    }
  end

  defp ref(%{provider_ref: ref}), do: ref

  @doc "The options of a Provider `choice` input for `entries`."
  @spec options([map]) :: [map]
  def options(entries), do: for(entry <- entries, do: %{value: entry.value, title: entry.label})

  @doc "The entry of `entries` whose value is `value`, nil for none."
  @spec find([map], term) :: map | nil
  def find(entries, value), do: Enum.find(entries, &(&1.value == value))

  @doc "The entry of `entries` that is the provider of `choice`; nil for none."
  @spec chosen([map], ModelChoice.t() | nil) :: map | nil
  def chosen(_entries, nil), do: nil

  def chosen(entries, %ModelChoice{connection_id: id}),
    do: Enum.find(entries, &(ref(&1) == id))

  ## Values

  @doc """
  The tiers' values of `choice` while `entry` is its provider's entry; else `blank/0`. A
  tier the choice leaves out is blank.
  """
  @spec params(ModelChoice.t() | nil, map | nil) :: map
  def params(%ModelChoice{} = choice, %{} = entry) do
    if chosen([entry], choice), do: values(choice.tiers), else: blank()
  end

  def params(_choice, _key), do: blank()

  @doc """
  The tiers' values of a stored tier map `tiers`, of a choice or of a fallback: a tier it
  leaves out, or nil, is blank.
  """
  @spec values(map | nil) :: map
  def values(tiers) do
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
  What `sent/5` reads of a stored choice: its provider's row id, its tiers' values and
  the name of its runtime, the default's for a choice that names none; nil for none.
  """
  @spec stored(ModelChoice.t() | nil) :: map | nil
  def stored(%ModelChoice{connection_id: id} = choice) when is_binary(id),
    do: %{
      provider_id: id,
      tiers: values(choice.tiers),
      runtime: choice.runtime || ModelChoices.default_runtime().name
    }

  def stored(_choice), do: nil

  @doc """
  `stored`, as `stored/1` gives it, for a form whose runtime is `runtime`: as it is while
  `runtime` is the stored choice's, so a stored effort the runtime no longer accepts stays
  shown and a save refuses it; for another runtime, without each tier's effort that
  `runtime` does not accept (its `effort_values`), so a change of the runtime takes such
  an effort back to Not set. nil for nil.
  """
  @spec accepted(map | nil, Runtime.t()) :: map | nil
  def accepted(%{runtime: name} = stored, %Runtime{name: name}), do: stored

  def accepted(%{tiers: tiers} = stored, %Runtime{effort_values: values}) do
    tiers =
      Map.new(tiers, fn {tier, set} ->
        if set["effort"] in values, do: {tier, set}, else: {tier, %{set | "effort" => ""}}
      end)

    %{stored | tiers: tiers}
  end

  def accepted(nil, _runtime), do: nil

  ## Runtime

  @doc """
  The runtime a form shows for a provider that serves `runtimes`, in the catalogue's
  order (`Apiary.Kinds.Providers.runtimes/1`): the one named `name` while it is among
  them, else the first; nil for none.
  """
  @spec runtime([Runtime.t()], String.t() | nil) :: Runtime.t() | nil
  def runtime(runtimes, name),
    do: Enum.find(runtimes, &(&1.name == name)) || List.first(runtimes)

  @doc """
  The tiers' values a form sent, for the provider entry `entry`, after the entry `before`,
  with `old` the values before. While the provider stays the same, a tier keeps a model of its list,
  or its model as it was, and an effort of that model (`efforts/3`); a field the form did
  not send is as it was, so a disabled Effort keeps its effort while its model stays.
  Another provider, or none, leaves every tier blank. A provider whose description
  lists no models takes any model id, and no effort.
  """
  @spec sent(map | nil, map | nil, map, term, map | nil) :: map
  def sent(entry, before, old, values, stored) do
    if entry != nil and before != nil and ref(entry) == ref(before) do
      values = if is_map(values), do: values, else: %{}

      Map.new(shown(), fn tier ->
        was = old[tier] || blank_tier()
        sent = if is_map(values[tier]), do: values[tier], else: %{}
        model = string(sent["model"], was["model"])
        kept? = model == was["model"]
        effort = string(sent["effort"], if(kept?, do: was["effort"], else: ""))

        {tier, fit(entry, tier, String.trim(model), effort, kept?, stored)}
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

  defp fit(entry, tier, model, effort, kept?, stored) do
    if kept? or Enum.any?(entry.models, &(&1.id == model)) do
      efforts = efforts(entry, model, stored_effort(entry, tier, model, stored))
      %{"model" => model, "effort" => if(effort in efforts, do: effort, else: "")}
    else
      blank_tier()
    end
  end

  # The effort the stored choice has for `tier`, while `entry` is of its provider and the
  # tier keeps its model; else "".
  defp stored_effort(entry, tier, model, %{provider_id: id, tiers: tiers}) do
    if ref(entry) == id and tiers[tier]["model"] == model,
      do: tiers[tier]["effort"],
      else: ""
  end

  defp stored_effort(_key, _tier, _model, _stored), do: ""

  # The effort values a tier offers for `model`: the model's offered effort values, and
  # `stored`, the stored choice's effort for it, where they lack it.
  defp efforts(nil, _model, _stored), do: []

  defp efforts(entry, model, stored) do
    offered =
      case Enum.find(entry.models, &(&1.id == model)) do
        %{effort: effort} when is_list(effort) -> effort
        _none -> []
      end

    if stored in ["", nil] or stored in offered, do: offered, else: offered ++ [stored]
  end

  # The models a tier offers: the provider's, by title, and the tier's model where the
  # list lacks it, by its id.
  defp models(entry, model) do
    listed = for m <- entry.models, do: {m.title || m.id, m.id}

    if model == "" or Enum.any?(entry.models, &(&1.id == model)),
      do: listed,
      else: listed ++ [{model, model}]
  end

  @doc "Whether a provider's entry `entry` is chosen and every tier has a model."
  @spec complete?(map | nil, map) :: boolean
  def complete?(nil, _tiers), do: false

  def complete?(_key, tiers),
    do: Enum.all?(shown(), &(String.trim((tiers[&1] || %{})["model"] || "") != ""))

  @doc """
  What a save of `entry`, the entry of a provider of the organisation (not a catalogue
  provider's entry, `entry/3`), and `tiers` sends to `Apiary.ModelChoices.put_choice/4`:
  `provider` and `tiers`, each tier with a model, its effort where it has one;
  and `model` and `effort`, those of the `thinking` tier, as the run's model and effort
  are (`Apiary.ModelChoices.Resolution`), so a page that reads the choice's model shows
  the run's.
  """
  @spec attrs(map, map) :: map
  def attrs(entry, tiers) do
    sent = saved_tiers(tiers)
    thinking = sent["thinking"] || %{}

    %{
      provider: entry.provider.public_id,
      tiers: sent,
      model: thinking["model"],
      effort: thinking["effort"]
    }
  end

  @doc """
  The tier map a save sends for the tiers' values `tiers`: each tier with a model, its
  effort where it has one.
  """
  @spec saved_tiers(map) :: map
  def saved_tiers(tiers) do
    for {tier, %{"model" => model} = set} <- tiers, model != "", into: %{} do
      if set["effort"] in ["", nil],
        do: {tier, %{"model" => model}},
        else: {tier, %{"model" => model, "effort" => set["effort"]}}
    end
  end

  ## Refusals

  @doc """
  Each refusal of a save, a changeset error, on the field it is about: `:provider` for
  the provider and any field the form does not have, `:runtime` for the runtime,
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
          :provider -> {:provider, error}
          :model -> {{"thinking", :model}, error}
          :effort -> {{"thinking", :effort}, error}
          :tiers -> {tier_field(opts, tiers), error}
          :runtime -> {:runtime, error}
          _other -> {:provider, error}
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
  attr :entry, :map, default: nil, doc: "the chosen provider's entry (`entries/2`)"
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

  attr :heading, :string,
    default: "h3",
    values: ~w(h2 h3),
    doc: "the element of the section's heading, by the page's heading levels"

  attr :stacked, :boolean,
    default: false,
    doc: "whether each tier's name and line stay above its fields at every width"

  attr :fit_effort, :boolean,
    default: false,
    doc: "whether each Effort is as wide as its chosen value, so Model gets the rest"

  @doc """
  The tiers of the provider entry `entry`: one section, "Model and effort per tier", with a group per tier,
  its name and line as the group's legend, then its Model and Effort. Model lists the
  provider's models; Effort the effort values of the tier's model, disabled where it has
  none. For a provider whose description lists no models, the section is "Model per
  tier", and each tier has a text field Model and no Effort. A refusal shows under its
  field, and one that names no tier above the tiers.
  """
  def tiers(assigns) do
    entry = assigns.entry

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
          models: if(entry, do: models(entry, model), else: []),
          efforts: efforts(entry, model, stored_effort(entry, tier, model, assigns.stored)),
          model_errors: messages(errors, {tier, :model}),
          effort_errors: messages(errors, {tier, :effort})
        }
      end

    assigns =
      assign(assigns,
        free: entry != nil and entry.free,
        rows: rows,
        head_errors: messages(errors, :tiers)
      )

    ~H"""
    <section id={@id} class="q-sect" aria-labelledby={"#{@id}-h"}>
      <header>
        <.dynamic_tag tag_name={@heading} id={"#{@id}-h"}>
          {if @free, do: gettext("Model per tier"), else: gettext("Model and effort per tier")}
        </.dynamic_tag>
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
                  class={[
                    "select select-sm",
                    if(@fit_effort, do: "w-full lg:w-auto lg:field-sizing-content", else: "w-full"),
                    row.effort_errors != [] && "select-error"
                  ]}
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

  @doc """
  The line under Runtime: why it lists these runtimes, as the provider `provider`, by its
  name, serves them.
  """
  @spec runtime_line([Runtime.t()], String.t()) :: String.t()
  def runtime_line([%Runtime{} = runtime], provider),
    do:
      gettext("%{runtime} is the only runtime that works with %{provider}.",
        runtime: runtime.title,
        provider: provider
      )

  def runtime_line(_runtimes, provider),
    do: gettext("These runtimes work with %{provider}.", provider: provider)

  @doc """
  The line under Provider while the chosen provider, `title` its title in its catalogue
  entry, works with no runtime of the catalogue (`Apiary.Kinds.Providers.runtimes/1`).
  """
  @spec no_runtime_line(String.t()) :: String.t()
  def no_runtime_line(title),
    do:
      gettext(
        "%{provider} works with no runtime in this version of Qory. Pick another provider.",
        provider: title
      )

  attr :id, :string, required: true, doc: "the id of the part; its line's id is it with `-line`"
  attr :select_id, :string, required: true, doc: "the id of the select, with several runtimes"
  attr :name, :string, required: true, doc: "the name of the field"
  attr :runtimes, :list, required: true, doc: "the runtimes the provider serves"
  attr :runtime, Runtime, required: true, doc: "the runtime chosen, one of `runtimes`"

  attr :provider, :string,
    required: true,
    doc: "the title of the provider in its catalogue entry, such as \"OpenRouter\""

  attr :errors, :list, default: [], doc: "the refusals of Runtime, each a message"
  attr :disabled, :boolean, default: false

  attr :form, :string,
    default: nil,
    doc: "the id of the form the field belongs to, where it is not the form it is in"

  @doc """
  Runtime, under the tiers: the runtimes the provider serves, in the catalogue's
  order (`Apiary.Kinds.Providers.runtimes/1`). With one, its name as text, and a hidden
  field with it; with several, a select. Then the line of `runtime_line/2`, and each
  refusal.
  """
  def runtime_part(assigns) do
    assigns = assign(assigns, line: runtime_line(assigns.runtimes, assigns.provider))

    ~H"""
    <div
      :if={match?([_], @runtimes)}
      id={@id}
      role="group"
      aria-labelledby={"#{@id}-label"}
      aria-describedby={String.trim("#{error_ids(@id, @errors)} #{@id}-line")}
      class="grid gap-1"
    >
      <p id={"#{@id}-label"} class="text-[13px]/[18px] font-medium">{gettext("Runtime")}</p>
      <p id={"#{@id}-name"} class="text-[13.5px]/5">{@runtime.title}</p>
      <input type="hidden" name={@name} value={@runtime.name} form={@form} />
      <.tier_error :for={{message, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>
        {message}
      </.tier_error>
      <p id={"#{@id}-line"} class="text-[12.5px]/[18px] text-muted">{@line}</p>
    </div>
    <fieldset :if={match?([_, _ | _], @runtimes)} id={@id} class="fieldset">
      <label for={@select_id} class="text-[13px]/[18px] font-medium">{gettext("Runtime")}</label>
      <select
        id={@select_id}
        name={@name}
        form={@form}
        class={["select select-sm w-full", @errors != [] && "select-error"]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={String.trim("#{error_ids(@id, @errors)} #{@id}-line")}
        disabled={@disabled}
      >
        {Phoenix.HTML.Form.options_for_select(
          for(runtime <- @runtimes, do: {runtime.title, runtime.name}),
          @runtime.name
        )}
      </select>
      <.tier_error :for={{message, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>
        {message}
      </.tier_error>
      <p id={"#{@id}-line"} class="text-[12.5px]/[18px] text-muted">{@line}</p>
    </fieldset>
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
