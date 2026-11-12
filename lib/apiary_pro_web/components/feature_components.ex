defmodule ApiaryProWeb.FeatureComponents do
  @moduledoc """
  The features a page grants or takes away (`ApiaryPro.Grants`): on Instance settings ›
  Organisations for an operator or an organisation with no operator, and on an operator's
  Clients page for a client. Each page asks
  `Apiary.Access.can?/3` for the action behind it, and passes the features it may offer,
  which are only the ones built (`Apiary.Features.built/0`) and never one the granter
  lacks: a feature that is off is not shown here either.

  `feature_fields/1` renders one checkbox per feature offered, named `features[<name>]`,
  as a group named Features for a screen reader, with why a save was refused under it
  where the page passes `errors`, and `checked/1` reads the features a submitted form
  keeps.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryProWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1, input: 1]

  alias Apiary.Features
  alias Phoenix.LiveView.JS

  @doc "The name a page shows for a feature."
  @spec label(Features.feature()) :: String.t() | nil
  def label(:observability), do: gettext("Runs")
  def label(:security), do: gettext("Security policy")
  def label(:managed_organisations), do: gettext("Clients")
  def label(:organisation_policy), do: gettext("Organisation policy")
  def label(:organisation_variables), do: gettext("Organisation secrets and variables")
  # The part of Runs a page shows or hides while features are shown by who asks
  # (`ApiaryPro.Grants.shown/1`), indented under Runs.
  def label(:"observability.terminal"), do: gettext("Terminal tab")
  # The nodes, a part of no feature, which a client's page shows or hides while the
  # operator owns its clients and features are shown by who asks
  # (`ApiaryPro.Features.client_parts/1`), after the features.
  def label(:nodes), do: gettext("Machines and access keys")
  def label(_feature), do: nil

  @doc "One sentence on what a feature covers, for beside its checkbox."
  @spec description(Features.feature()) :: String.t() | nil
  def description(:observability),
    do:
      gettext(
        "Runs, their terminals, the connections and retention. Every other feature needs it."
      )

  def description(:security),
    do: gettext("The security policy's pages. Runs are served their policy either way.")

  def description(:managed_organisations),
    do: gettext("Running organisations for clients, as an operator.")

  def description(:organisation_policy),
    do:
      gettext(
        "Host rules for every workspace, a mode they all keep, and whether workspaces may allow more hosts."
      )

  def description(:organisation_variables),
    do:
      gettext(
        "Secrets and variables kept at the organisation: variables every workspace inherits, with names it may lock, and secrets whose values are never shown once saved."
      )

  def description(:"observability.terminal"),
    do:
      gettext(
        "The run's log: the Terminal tab, the last lines on the Runs list, Raw log and Download log. Runs still record it while it is hidden."
      )

  def description(_feature), do: nil

  @doc """
  checked/1 is the features a submitted form of `feature_fields/1` keeps, as names, from
  its `features` params.
  """
  @spec checked(map | nil) :: [String.t()]
  def checked(%{} = params), do: for({name, "true"} <- params, do: name)
  def checked(_params), do: []

  attr :id, :string, required: true
  attr :offered, :list, required: true, doc: "the features the form may name"
  attr :has, :list, required: true, doc: "the features it has now"
  attr :focus, :boolean, default: false, doc: "focus the first checkbox once it is mounted"

  attr :operator, :string,
    default: nil,
    doc: "the name of the client's operator, which a client's page passes"

  attr :errors, :list,
    default: [],
    doc: "why a save of the group was refused, each shown under the checkboxes; none by default"

  @doc """
  One checkbox per feature offered, checked for those it has, in a group whose legend,
  Features, only a screen reader reads. A refused save's `errors` follow the checkboxes,
  as the core's fields show theirs: the group is marked invalid and described by them, so
  the core's failed submit puts the caret in its first checkbox and a screen reader reads
  why with the group.
  """
  def feature_fields(assigns) do
    assigns =
      assigns
      |> assign(:shown, in_order(assigns.offered))
      |> assign(:error_ids, Enum.map(Enum.with_index(assigns.errors), &error_id(assigns.id, &1)))

    ~H"""
    <fieldset
      id={@id}
      class="grid gap-3"
      aria-invalid={@errors != [] && "true"}
      aria-describedby={@error_ids != [] && Enum.join(@error_ids, " ")}
    >
      <legend class="sr-only">{gettext("Features")}</legend>
      <div
        :for={{feature, i} <- Enum.with_index(@shown)}
        class={["grid gap-0.5", part_of_feature?(feature) && "pl-6"]}
      >
        <.input
          id={"#{@id}-#{dom_id(feature)}"}
          name={"features[#{feature}]"}
          type="checkbox"
          label={label(feature)}
          checked={feature in @has}
          aria-describedby={describe(feature, @operator) && "#{@id}-#{dom_id(feature)}-description"}
          phx-mounted={@focus && i == 0 && JS.focus()}
        />
        <p
          :if={describe(feature, @operator)}
          id={"#{@id}-#{dom_id(feature)}-description"}
          class="pl-6 text-[12.5px]/[18px] text-muted"
        >
          {describe(feature, @operator)}
        </p>
      </div>
      <p
        :for={{message, error_id} <- Enum.zip(@errors, @error_ids)}
        id={error_id}
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
      >
        <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
        {message}
      </p>
    </fieldset>
    """
  end

  # The features offered that have a name, each followed by the parts of it offered, which
  # a page offers only while features are shown by who asks (`ApiaryPro.Grants.shown/1`);
  # then the parts of no feature offered, the nodes, which only a client's page offers.
  defp in_order(offered) do
    of_features =
      for feature <- offered,
          not part?(feature),
          label(feature),
          name <- [feature | Enum.filter(offered, &(part?(&1) and part_of?(&1, feature)))],
          label(name),
          do: name

    of_features ++ Enum.filter(offered, &(part?(&1) and is_nil(Features.feature_of(&1))))
  end

  defp part?(name), do: name in Features.parts()

  defp part_of?(part, feature), do: Features.feature_of(part) == feature

  # A part of a feature is indented under it; a part of no feature, the nodes, is not.
  defp part_of_feature?(name), do: part?(name) and not is_nil(Features.feature_of(name))

  # The sentence beside a box: the nodes' names the client's operator, which runs them.
  defp describe(:nodes, operator) when is_binary(operator),
    do:
      gettext(
        "The machines, pools, access keys and gateways %{operator} runs in this client's workspaces, which its people read only.",
        operator: operator
      )

  defp describe(:nodes, _operator), do: nil
  defp describe(feature, _operator), do: description(feature)

  # A name as an id takes it: a part's dot, `observability.terminal`, is a dash there, so
  # a selector reads it as one name.
  defp dom_id(name), do: name |> Atom.to_string() |> String.replace(".", "-")

  # The id of the group's error at `index`, as the core's fields number theirs: the first
  # is `<id>-error`, the next `<id>-error-2`.
  defp error_id(id, {_message, 0}), do: "#{id}-error"
  defp error_id(id, {_message, index}), do: "#{id}-error-#{index + 1}"

  attr :id, :string, required: true
  attr :features, :list, required: true, doc: "the features it has"
  attr :offered, :list, default: nil, doc: "shown when given: the ones of these it has"
  attr :class, :any, default: nil
  attr :title, :string, default: nil, doc: "the words whole, where the class cuts them"

  @doc """
  The features something has, as plain words in a row's muted text (`docs/ui.md` of the
  core, Lists: a feature is never a pill); "none", faint, for none.
  """
  def feature_words(assigns) do
    assigns = assign(assigns, :shown, shown(assigns.features, assigns.offered))

    ~H"""
    <span id={@id} class={@class} title={@title}>
      {Enum.map_join(@shown, ", ", &label/1)}<span :if={@shown == []} class="text-faint">{gettext(
        "none"
      )}</span>
    </span>
    """
  end

  @doc """
  feature_text/2 is the features of `features` that `offered` holds (every built one when
  it is nil), by name and in the order they were built, as one line of words; "none" for
  none.
  """
  @spec feature_text([Features.feature()], [Features.feature()] | nil) :: String.t()
  def feature_text(features, offered \\ nil) do
    case shown(features, offered) do
      [] -> gettext("none")
      shown -> Enum.map_join(shown, ", ", &label/1)
    end
  end

  # A feature with no name is not shown: a list of words never carries an empty one.
  defp shown(features, offered),
    do:
      Enum.filter(
        Features.built(),
        &(&1 in features and (is_nil(offered) or &1 in offered) and label(&1) != nil)
      )
end
