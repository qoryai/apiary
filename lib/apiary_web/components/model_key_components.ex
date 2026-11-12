defmodule ApiaryWeb.ModelKeyComponents do
  # The settings and the state of a model key, a value of a model provider's secret
  # (`Apiary.ModelKeys`), as the provider's page, Add key and Edit key
  # (`ApiaryWeb.ProviderLive.Show`, `ApiaryWeb.ProviderLive.Key`) and the workspace's
  # Secrets page (`ApiaryWeb.SecretLive.Index`) show them:
  #
  #   * `settings_fields/1`: Resets, a weekly day, time and time zone, Pause for, a
  #     number and a unit, and, for a provider with limit windows, Use up to, a
  #     percentage, each optional, with their hints and their errors;
  #   * `params/3` the fields of a key's settings, `read_settings/1` the settings of what
  #     a form sent, and `errors/1` the errors of a settings changeset, by field group;
  #   * `state/2` the state of a key from its states, in words.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys
  alias Apiary.ModelKeys.{Setting, State}
  alias ApiaryWeb.UserLive.Settings, as: UserSettings

  @fields ~w(reset_day reset_time reset_zone pause_number pause_unit use_up_to)
  @units %{"minutes" => 60, "hours" => 3600, "days" => 86_400}
  @reset_fields [:reset_weekday, :reset_time, :reset_time_zone]

  @doc "The names of the fields `settings_fields/1` sends."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  Whether the keys of `provider` are a subscription's: its catalogue entry's API `auth`
  has `oauth: true`, as `Apiary.ModelKeys.default_pause_seconds/1` reads it.
  """
  @spec subscription?(Connection.t()) :: boolean
  def subscription?(%Connection{provider_kind: kind}) do
    case Providers.fetch(kind) do
      {:ok, %Provider{apis: apis}} -> Enum.any?(apis, &(get_in(&1, ["auth", "oauth"]) == true))
      :error -> false
    end
  end

  @doc """
  The fields of the settings `setting` (nil for none), as a form shows them: the time
  zone the scope's reader's where the key has no reset, the unit of Pause for the
  largest that the setting's seconds are a whole number of, else hours for a
  subscription and minutes for an API key, and Use up to empty where the key has none.
  """
  @spec params(Setting.t() | nil, Scope.t(), boolean) :: map
  def params(setting, %Scope{} = scope, subscription) do
    reset =
      if Setting.reset?(setting),
        do: %{
          "reset_day" => Integer.to_string(setting.reset_weekday),
          "reset_time" => Calendar.strftime(setting.reset_time, "%H:%M"),
          "reset_zone" => setting.reset_time_zone
        },
        else: %{"reset_day" => "", "reset_time" => "", "reset_zone" => Scope.time_zone(scope)}

    reset
    |> Map.merge(pause_params(setting, subscription))
    |> Map.put("use_up_to", use_up_to_param(setting))
  end

  defp use_up_to_param(%Setting{use_up_to_percent: percent}) when is_integer(percent),
    do: Integer.to_string(percent)

  defp use_up_to_param(_setting), do: ""

  defp pause_params(%Setting{pause_seconds: seconds}, _subscription) when is_integer(seconds) do
    case Enum.find([{"days", 86_400}, {"hours", 3600}], fn {_u, n} -> rem(seconds, n) == 0 end) do
      {unit, n} -> %{"pause_number" => Integer.to_string(div(seconds, n)), "pause_unit" => unit}
      nil -> %{"pause_number" => Integer.to_string(div(seconds, 60)), "pause_unit" => "minutes"}
    end
  end

  defp pause_params(_setting, subscription),
    do: %{"pause_number" => "", "pause_unit" => if(subscription, do: "hours", else: "minutes")}

  @doc """
  The settings that the fields `params` stand for (`Apiary.ModelKeys.Setting`), and the
  errors of what cannot be read: `{attrs, errors}`, `errors` as `errors/1` has them. A
  reset with neither a day nor a time is none, whatever the time zone, which is chosen
  from the start. A Pause for with no number is none; one with a number that is not a
  whole one, or with a unit not offered, is an error. A Use up to with no number is none;
  one that is not a whole number is an error.
  """
  @spec attrs(map) :: {map, map}
  def attrs(%{} = params) do
    day = field(params, "reset_day")
    time = field(params, "reset_time")

    reset =
      if day == "" and time == "",
        do: %{"reset_weekday" => nil, "reset_time" => nil, "reset_time_zone" => nil},
        else: %{
          "reset_weekday" => day,
          "reset_time" => time,
          "reset_time_zone" => field(params, "reset_zone")
        }

    {pause_seconds, pause_errors} =
      case pause(field(params, "pause_number"), field(params, "pause_unit")) do
        {:ok, seconds} -> {seconds, %{}}
        :error -> {nil, %{pause: [pause_error()]}}
      end

    {percent, use_up_to_errors} =
      case use_up_to(field(params, "use_up_to")) do
        {:ok, percent} -> {percent, %{}}
        :error -> {nil, %{use_up_to: [use_up_to_error()]}}
      end

    {reset |> Map.put("pause_seconds", pause_seconds) |> Map.put("use_up_to_percent", percent),
     Map.merge(pause_errors, use_up_to_errors)}
  end

  defp use_up_to(""), do: {:ok, nil}

  defp use_up_to(number) do
    if number =~ ~r/\A\d{1,7}\z/, do: {:ok, String.to_integer(number)}, else: :error
  end

  defp field(params, name) do
    case params[name] do
      value when is_binary(value) -> String.trim(value)
      _other -> ""
    end
  end

  defp pause("", _unit), do: {:ok, nil}

  defp pause(number, unit) do
    with true <- number =~ ~r/\A\d{1,7}\z/,
         {:ok, seconds} <- Map.fetch(@units, unit),
         do: {:ok, String.to_integer(number) * seconds},
         else: (_ -> :error)
  end

  @doc """
  The errors of a settings changeset by field group, each group's one message: `:resets`
  for an error of the day, the time or the time zone, `:pause` for one of Pause for, and
  `:use_up_to` for one of Use up to.
  """
  @spec errors(Ecto.Changeset.t()) :: map
  def errors(%Ecto.Changeset{errors: errors}) do
    fields = Keyword.keys(errors)

    %{}
    |> put_if(Enum.any?(fields, &(&1 in @reset_fields)), :resets, resets_error())
    |> put_if(:pause_seconds in fields, :pause, pause_error())
    |> put_if(:use_up_to_percent in fields, :use_up_to, use_up_to_error())
  end

  @doc """
  The settings that the fields `params` stand for, checked as they are saved
  (`attrs/1`, `Apiary.ModelKeys.Setting.changeset/3`) for a key of a provider with
  `limit_windows` (`Apiary.ModelKeys.limit_windows/1`): `{:ok, attrs}`, or
  `{:error, errors}` by field group, as `errors/1` has them.
  """
  @spec read_settings(map, [String.t()]) :: {:ok, map} | {:error, map}
  def read_settings(%{} = params, limit_windows \\ []) do
    {attrs, read_errors} = attrs(params)
    changeset = Setting.changeset(%Setting{}, attrs, limit_windows)

    errors =
      Map.merge(read_errors, errors(changeset), fn _group, a, b -> Enum.uniq(a ++ b) end)

    if errors == %{}, do: {:ok, attrs}, else: {:error, errors}
  end

  defp put_if(errors, true, group, message), do: Map.put(errors, group, [message])
  defp put_if(errors, false, _group, _message), do: errors

  defp resets_error,
    do: gettext("Set the day, the time and the time zone, or leave all three empty.")

  defp pause_error, do: gettext("Enter a time from 1 minute to 7 days.")

  defp use_up_to_error, do: gettext("Enter a percentage from 1 to 99.")

  @doc """
  Resets, Pause for and, for a provider with limit windows, Use up to, each a group of
  its fields with its hint under it, or its error in the hint's place. The fields are the
  form's (`fields/0`), named as its other fields.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :errors, :map, default: %{}, doc: "the groups' errors, as `errors/1` has them"
  attr :subscription, :boolean, required: true, doc: "whether the key is a subscription's"

  attr :limit_windows, :list,
    default: [],
    doc: "the provider's limit windows (`Apiary.ModelKeys.limit_windows/1`); none: no Use up to"

  def settings_fields(assigns) do
    assigns =
      assign(assigns,
        resets_errors: Map.get(assigns.errors, :resets, []),
        pause_errors: Map.get(assigns.errors, :pause, []),
        use_up_to_errors: Map.get(assigns.errors, :use_up_to, []),
        zone: assigns.form[:reset_zone].value
      )

    ~H"""
    <fieldset
      id={"#{@form[:reset_day].id}-resets"}
      class="grid gap-1.5"
      aria-describedby={group_note(@form[:reset_day].id, "resets", @resets_errors)}
    >
      <legend class="mb-1 text-[13px]/[18px] font-medium">
        {gettext("Resets")}
        <span class="font-normal text-faint">{gettext("(optional)")}</span>
      </legend>
      <div class="grid gap-3 sm:grid-cols-[minmax(0,10rem)_minmax(0,8rem)_minmax(0,1fr)]">
        <.input
          type="select"
          id={@form[:reset_day].id}
          name={@form[:reset_day].name}
          value={@form[:reset_day].value}
          label={gettext("Day")}
          prompt=""
          options={Format.weekdays()}
          class={@resets_errors != [] && "select-error"}
        />
        <.input
          type="time"
          id={@form[:reset_time].id}
          name={@form[:reset_time].name}
          value={@form[:reset_time].value}
          label={gettext("Time")}
          class={@resets_errors != [] && "input-error"}
        />
        <.input
          type="select"
          id={@form[:reset_zone].id}
          name={@form[:reset_zone].name}
          value={@zone}
          label={gettext("Time zone")}
          options={UserSettings.time_zone_options(@zone)}
          class={@resets_errors != [] && "select-error"}
        />
      </div>
      <.group_note
        id={@form[:reset_day].id}
        group="resets"
        errors={@resets_errors}
        hint={
          gettext(
            "The weekly time when this key's allowance resets. Set it if the provider sends no reset time."
          )
        }
      />
    </fieldset>

    <fieldset
      id={"#{@form[:pause_number].id}-pause"}
      class="grid gap-1.5"
      aria-describedby={group_note(@form[:pause_number].id, "pause", @pause_errors)}
    >
      <legend id={"#{@form[:pause_number].id}-legend"} class="mb-1 text-[13px]/[18px] font-medium">
        {gettext("Pause for")}
        <span class="font-normal text-faint">{gettext("(optional)")}</span>
      </legend>
      <div class="grid grid-cols-[minmax(0,7rem)_minmax(0,9rem)] gap-3">
        <.input
          type="number"
          id={@form[:pause_number].id}
          name={@form[:pause_number].name}
          value={@form[:pause_number].value}
          min="1"
          step="1"
          inputmode="numeric"
          aria-labelledby={"#{@form[:pause_number].id}-legend"}
          class={@pause_errors != [] && "input-error"}
        />
        <.input
          type="select"
          id={@form[:pause_unit].id}
          name={@form[:pause_unit].name}
          value={@form[:pause_unit].value}
          options={unit_options()}
          aria-labelledby={"#{@form[:pause_number].id}-legend"}
          class={@pause_errors != [] && "select-error"}
        />
      </div>
      <.group_note
        id={@form[:pause_number].id}
        group="pause"
        errors={@pause_errors}
        hint={pause_hint(@subscription)}
      />
    </fieldset>

    <fieldset
      :if={@limit_windows != []}
      id={"#{@form[:use_up_to].id}-use-up-to"}
      class="grid gap-1.5"
      aria-describedby={group_note(@form[:use_up_to].id, "use-up-to", @use_up_to_errors)}
    >
      <legend id={"#{@form[:use_up_to].id}-legend"} class="mb-1 text-[13px]/[18px] font-medium">
        {gettext("Use up to")}
        <span class="font-normal text-faint">{gettext("(optional)")}</span>
      </legend>
      <div class="grid grid-cols-[minmax(0,7rem)_auto] items-center gap-2">
        <.input
          type="number"
          id={@form[:use_up_to].id}
          name={@form[:use_up_to].name}
          value={@form[:use_up_to].value}
          min="1"
          max="99"
          step="1"
          inputmode="numeric"
          aria-labelledby={"#{@form[:use_up_to].id}-legend"}
          class={@use_up_to_errors != [] && "input-error"}
        />
        <span class="text-[13px]/5">%</span>
      </div>
      <.group_note
        id={@form[:use_up_to].id}
        group="use-up-to"
        errors={@use_up_to_errors}
        hint={use_up_to_hint(@limit_windows)}
      />
    </fieldset>
    """
  end

  defp use_up_to_hint(limit_windows),
    do:
      gettext(
        "Runs skip this key once its %{windows} use reaches this percentage of the allowance, until that window resets, so the rest stays for your sessions outside Qory Apiary. Empty: runs use the key up to its limit.",
        windows: windows_words(limit_windows)
      )

  # The windows in words, the last after "or": "5-hour or 7-day".
  defp windows_words(windows) do
    case Enum.map(windows, &window/1) do
      [one] ->
        one

      words ->
        {first, [last]} = Enum.split(words, -1)
        gettext("%{windows} or %{last}", windows: Enum.join(first, ", "), last: last)
    end
  end

  defp unit_options,
    do: [
      {gettext("minutes"), "minutes"},
      {gettext("hours"), "hours"},
      {gettext("days"), "days"}
    ]

  defp pause_hint(true),
    do:
      gettext(
        "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 hour."
      )

  defp pause_hint(false),
    do:
      gettext(
        "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 minute."
      )

  defp group_note(id, group, []), do: "#{id}-#{group}-hint"
  defp group_note(id, group, _errors), do: "#{id}-#{group}-error"

  attr :id, :string, required: true
  attr :group, :string, required: true
  attr :errors, :list, required: true
  attr :hint, :string, required: true

  # A group's hint, or its error in the hint's place, as a field shows a field's error.
  defp group_note(assigns) do
    ~H"""
    <p
      :if={@errors == []}
      id={"#{@id}-#{@group}-hint"}
      class="text-[12.5px]/[18px] text-muted"
    >
      {@hint}
    </p>
    <p
      :for={message <- Enum.take(@errors, 1)}
      id={"#{@id}-#{@group}-error"}
      class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
    >
      <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
      {message}
    </p>
    """
  end

  ## A key's state

  @doc """
  The state of a key at `now`, from `states`, its states by window
  (`Apiary.ModelKeys.provider_states/2`), its Use up to percentage `percent` (nil for
  none) and its provider's `limit_windows` (`Apiary.ModelKeys.limit_windows/1`), in the
  reader's time zone:

    * `{:cooldown, until, source}` while the key is in cooldown
      (`Apiary.ModelKeys.cooldown/4`): "In cooldown until Fri 14:00", and where that time
      comes from; for a Pause for, the cooldown that applied, from the response that
      started it to its end (`cooldown_until` less `observed_at`), whatever the key's
      Pause for is now; for a window at the key's Use up to percentage, the window and
      the percentage the key has now, which the window's use may be past;
    * `{:available, segments}` otherwise, one segment per window with a utilization or a
      reset still to come: "5-hour 89%, resets 14:00".
  """
  @spec state([State.t()], DateTime.t(), pos_integer | nil, [String.t()]) ::
          {:cooldown, String.t(), String.t()} | {:available, [String.t()]}
  def state(states, %DateTime{} = now, percent \\ nil, limit_windows \\ []) do
    case ModelKeys.cooldown(states, percent, limit_windows, now) do
      {until, source} ->
        {:cooldown, gettext("In cooldown until %{time}", time: Format.week_time(until, now)),
         source(source, percent)}

      nil ->
        {:available, segments(states, now)}
    end
  end

  defp source({:use_up_to, %State{window: window}}, percent),
    do:
      gettext("%{window} at %{percent}%, this key's Use up to",
        window: window(window),
        percent: Format.number(percent)
      )

  defp source({:stored, state}, _percent), do: source(state)

  defp source(%State{source: "provider"}), do: gettext("from the provider's response")
  defp source(%State{source: "schedule"}), do: gettext("from this key's schedule")

  defp source(%State{cooldown_until: until, observed_at: observed_at}),
    do:
      gettext("no reset time given; paused for %{duration}",
        duration: pause_words(max(DateTime.diff(until, observed_at, :second), 1))
      )

  @doc """
  A Pause for in words, in its largest whole unit: "1 hour", "30 minutes", "2 days".
  """
  @spec pause_words(pos_integer) :: String.t()
  def pause_words(seconds) when is_integer(seconds) do
    cond do
      rem(seconds, 86_400) == 0 ->
        n = div(seconds, 86_400)
        ngettext("%{number} day", "%{number} days", n, number: Format.number(n))

      rem(seconds, 3600) == 0 ->
        n = div(seconds, 3600)
        ngettext("%{number} hour", "%{number} hours", n, number: Format.number(n))

      true ->
        n = max(div(seconds, 60), 1)
        ngettext("%{number} minute", "%{number} minutes", n, number: Format.number(n))
    end
  end

  defp segments(states, now) do
    Enum.flat_map(states, fn state ->
      reset = future(state.resets_at, now)
      if state.utilization || reset, do: [segment(state, reset, now)], else: []
    end)
  end

  defp future(%DateTime{} = at, now), do: if(DateTime.compare(at, now) == :gt, do: at)
  defp future(nil, _now), do: nil

  defp segment(%State{window: window, utilization: utilization}, reset, now) do
    used =
      if utilization,
        do: "#{window(window)} #{gettext("%{percent}%", percent: Format.number(utilization))}",
        else: window(window)

    if reset,
      do: gettext("%{use}, resets %{time}", use: used, time: Format.week_time(reset, now)),
      else: used
  end

  # The windows of the contract (`Apiary.ModelKeys.State`) in words; another code shows
  # as it is.
  defp window("five_hour"), do: gettext("5-hour")
  defp window("seven_day"), do: gettext("7-day")
  defp window("seven_day_opus"), do: gettext("7-day Opus")
  defp window("seven_day_sonnet"), do: gettext("7-day Sonnet")
  defp window("overage"), do: gettext("Extra usage")
  defp window("requests"), do: gettext("Requests per minute")
  defp window("tokens"), do: gettext("Tokens per minute")
  defp window("input_tokens"), do: gettext("Input tokens per minute")
  defp window("output_tokens"), do: gettext("Output tokens per minute")
  defp window("spend_limit"), do: gettext("Spend limit")
  defp window("key"), do: gettext("Limit")
  defp window(code), do: code

  @doc """
  A key's state as `state/2` has it, on one line: the state, then its source or its
  segments, each after a middle dot.
  """
  attr :id, :string, required: true
  attr :state, :any, required: true

  def state_line(%{state: {:cooldown, until, source}} = assigns) do
    assigns = assign(assigns, until: until, source: source)

    ~H"""
    <span id={@id} class="text-[13px]/5">
      <span class="font-medium">{@until}</span>
      <span class="text-muted"> · {@source}</span>
    </span>
    """
  end

  def state_line(%{state: {:available, segments}} = assigns) do
    assigns = assign(assigns, :segments, segments)

    ~H"""
    <span id={@id} class="text-[13px]/5">
      <span class="font-medium">{gettext("Available")}</span>
      <span :for={segment <- @segments} class="text-muted"> · {segment}</span>
    </span>
    """
  end
end
