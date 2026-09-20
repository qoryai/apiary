defmodule ApiaryWeb.RunComponents do
  @moduledoc """
  The components the runs list, the run page and the connections pages share
  (`docs/design/brief-runs.md`, rd1 to rd15): the run state badge, durations and times that
  tick in the browser, the key and value strip, label chips, the alive indicator, the
  filter bar, tabs, the connection row with its reason, the connections tables and the
  new-items pill.

  Everything rendered here is a field of an event or a count of events; what the record
  lacks reads "n/a". Event data is untrusted: it is only ever interpolated, never `raw/1`.

  Times tick in the browser: every `<time data-tick=…>` is re-rendered once a second by the
  `Ticker` hook's one interval (`assets/js/hooks/ticker.js`), in the same words the server
  rendered, so the server never re-renders for a clock.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents,
    only: [badge: 1, icon: 1, mono: 1, term: 1, short_date: 1]

  alias Phoenix.LiveView.JS

  @outcome_tip "What became of the connection. Connected: the dial succeeded. Dial failed: allowed, but the host did not answer. Refused: never dialled."
  @at_least_tip "Elapsed at the last heartbeat. The clock stops counting when heartbeats stop."

  ## rd1. Run state

  @doc """
  The badge of a run's state, one family for the seven states. `quiet_for` (seconds since
  the last heartbeat, set by the server once it is over one interval) turns a running badge
  amber and adds the note beside it.
  """
  attr :state, :string, required: true, values: Apiary.Runs.Run.states()
  attr :exit_code, :integer, default: nil, doc: "after Failed when not 0 and not -1"
  attr :signal, :string, default: nil, doc: "shown instead of the exit code"
  attr :quiet_for, :integer, default: nil
  attr :quiet_since, :any, default: nil, doc: "the last heartbeat, so the seconds tick"
  attr :interval, :integer, default: nil, doc: "heartbeat_interval_seconds, for the tooltip"
  attr :closed_at, :any, default: nil, doc: "for the tooltip of a closed run"
  attr :note, :boolean, default: true, doc: "false drops the amber note, for tight rows"
  attr :class, :any, default: nil

  def run_state(assigns) do
    quiet? = assigns.state == "running" and is_integer(assigns.quiet_for)

    assigns =
      assigns
      |> assign(:quiet?, quiet?)
      |> assign(:color, state_color(assigns.state, quiet?))
      |> assign(:glyph, state_glyph(assigns.state))
      |> assign(:code, exit_word(assigns))

    ~H"""
    <span class={["inline-flex items-center gap-2 align-middle", @class]}>
      <.badge
        color={@color}
        class={[
          "q-state",
          @state == "pending" && "q-state-pending",
          @state == "running" && !@quiet? && "q-state-running"
        ]}
      >
        <.icon :if={@glyph} name={@glyph} class="size-3" />
        <i :if={!@glyph} aria-hidden="true"></i>
        <span
          :if={@state == "closed"}
          class="tooltip q-tip-wide"
          data-tip={closed_tip(@closed_at)}
        >{state_label(@state)}</span>
        <span :if={@state != "closed"}>{state_label(@state)}</span>
        <span :if={@code} class="font-mono text-[11px]">{@code}</span>
      </.badge>
      <span
        :if={@quiet? && @note}
        class="q-quiet tooltip q-tip-wide"
        tabindex="0"
        data-tip={quiet_tip(@interval)}
      >
        <.icon name="hero-exclamation-triangle-micro" class="size-3" /> No heartbeat for
        <time
          :if={@quiet_since}
          data-tick="seconds"
          data-since={iso(@quiet_since)}
          aria-live="off"
          class="tabular-nums"
        >{format_seconds(@quiet_for)}</time>
        <span :if={!@quiet_since} class="tabular-nums">{format_seconds(@quiet_for)}</span>
      </span>
    </span>
    """
  end

  @doc "The word of a state, as the badge says it."
  def state_label("pending"), do: "Pending"
  def state_label("running"), do: "Running"
  def state_label("exited"), do: "Exited"
  def state_label("failed"), do: "Failed"
  def state_label("timed_out"), do: "Timed out"
  def state_label("lost"), do: "Lost"
  def state_label("closed"), do: "Closed"

  defp state_color("running", true), do: "warning"
  defp state_color("running", false), do: "info"
  defp state_color("exited", _), do: "success"
  defp state_color(state, _) when state in ~w(failed timed_out), do: "error"
  defp state_color("lost", _), do: "warning"
  defp state_color(_state, _), do: "neutral"

  defp state_glyph("exited"), do: "hero-check-micro"
  defp state_glyph("failed"), do: "hero-x-mark-micro"
  defp state_glyph("timed_out"), do: "hero-clock-micro"
  defp state_glyph("lost"), do: "hero-signal-slash-micro"
  defp state_glyph("closed"), do: "hero-lock-closed-micro"
  defp state_glyph(_state), do: nil

  defp exit_word(%{state: "failed", signal: signal}) when is_binary(signal) and signal != "",
    do: signal

  defp exit_word(%{state: "failed", exit_code: code})
       when is_integer(code) and code not in [0, -1],
       do: "exit #{code}"

  defp exit_word(_assigns), do: nil

  defp quiet_tip(interval) when is_integer(interval) do
    "Heartbeats are due every #{format_seconds(interval)}. After #{format_seconds(interval * 3)} of silence the run is marked lost."
  end

  defp quiet_tip(_interval),
    do: "Heartbeats have stopped. After three missed intervals the run is marked lost."

  defp closed_tip(%DateTime{} = at),
    do: "Closed by a member on #{short_date(at)}. The run never posted its exit."

  defp closed_tip(_at), do: "Closed by a member. The run never posted its exit."

  @doc """
  The seconds a running run has been quiet for, or nil: set once the last heartbeat is
  older than one interval. The server decides this, never the browser.
  """
  def quiet_for(run, now \\ DateTime.utc_now())

  def quiet_for(
        %{
          state: "running",
          last_heartbeat_at: %DateTime{} = at,
          heartbeat_interval_seconds: interval
        },
        now
      )
      when is_integer(interval) do
    seconds = DateTime.diff(now, at, :second)
    if seconds > interval, do: seconds
  end

  def quiet_for(_run, _now), do: nil

  ## rd2. Duration

  @doc """
  A duration. `ms` for what has ended, `running_since` for a clock that counts in the
  browser, `at_least_seconds` for a run whose heartbeats stopped. Nothing given: "n/a".
  """
  attr :id, :string, default: nil
  attr :ms, :integer, default: nil
  attr :running_since, :any, default: nil
  attr :at_least_seconds, :integer, default: nil
  attr :precise, :boolean, default: false, doc: "tenths of a second under a minute, for tools"
  attr :so_far, :boolean, default: false, doc: "the run header adds the words"
  attr :class, :any, default: nil

  def duration(%{ms: ms} = assigns) when is_integer(ms) do
    ~H"""
    <span id={@id} class={["tabular-nums", @class]}>{format_duration_ms(@ms, @precise)}</span>
    """
  end

  def duration(%{running_since: %DateTime{}} = assigns) do
    ~H"""
    <span class={["tabular-nums", @class]}>
      <time
        id={@id}
        phx-hook={@id && "Ticker"}
        data-tick="duration"
        data-since={iso(@running_since)}
        aria-live="off"
      >{format_seconds(max(DateTime.diff(DateTime.utc_now(), @running_since, :second), 0))}</time>
      <small :if={@so_far} class="text-xs text-faint">so far</small>
    </span>
    """
  end

  def duration(%{at_least_seconds: seconds} = assigns) when is_integer(seconds) do
    assigns = assign(assigns, :tip, @at_least_tip)

    ~H"""
    <span
      id={@id}
      class={["tooltip tooltip-left q-tip-wide tabular-nums", @class]}
      tabindex="0"
      data-tip={@tip}
    >
      at least {format_seconds(@at_least_seconds)}
    </span>
    """
  end

  def duration(assigns) do
    ~H"""
    <span id={@id} class={["text-faint", @class]}>n/a</span>
    """
  end

  @doc "\"41 ms\", \"48 s\" (or \"3.4 s\" when precise), \"6 m 51 s\", \"1 h 00 m\"."
  def format_duration_ms(ms, precise \\ false)
  def format_duration_ms(ms, _precise) when ms < 1000, do: "#{ms} ms"

  def format_duration_ms(ms, true) when ms < 60_000,
    do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"

  def format_duration_ms(ms, _precise), do: format_seconds(div(ms, 1000))

  @doc "\"48 s\", \"6 m 51 s\", \"1 h 00 m\"."
  def format_seconds(seconds) when seconds < 60, do: "#{max(seconds, 0)} s"

  def format_seconds(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)} m #{pad(rem(seconds, 60))} s"

  def format_seconds(seconds),
    do: "#{div(seconds, 3600)} h #{pad(div(rem(seconds, 3600), 60))} m"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  ## rd3. Relative time and the offset

  @doc """
  A time across runs: relative up to yesterday ("2 minutes ago", "Yesterday, 16:40"), then
  "17 Sep, 09:30". `clock` gives "Today, 14:02:11". The absolute UTC time is the `title`.
  """
  attr :id, :string, default: nil
  attr :at, :any, required: true
  attr :format, :string, default: "relative", values: ~w(relative clock)
  attr :class, :any, default: nil

  def relative_time(%{at: %DateTime{}} = assigns) do
    ~H"""
    <time
      id={@id}
      phx-hook={@id && "Ticker"}
      datetime={iso(@at)}
      data-tick={@format}
      title={absolute(@at)}
      aria-live="off"
      class={["tabular-nums", @class]}
    >{if @format == "clock", do: clock_label(@at), else: relative_label(@at)}</time>
    """
  end

  def relative_time(assigns) do
    ~H"""
    <span id={@id} class={["text-faint", @class]}>n/a</span>
    """
  end

  @doc false
  def relative_label(%DateTime{} = at, now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, at, :second), 0)
    days = Date.diff(DateTime.to_date(now), DateTime.to_date(at))

    cond do
      seconds < 5 -> "Just now"
      seconds < 60 -> "#{seconds} seconds ago"
      seconds < 120 -> "1 minute ago"
      seconds < 3600 -> "#{div(seconds, 60)} minutes ago"
      days <= 0 and seconds < 7200 -> "1 hour ago"
      days <= 0 -> "#{div(seconds, 3600)} hours ago"
      days == 1 -> "Yesterday, #{Calendar.strftime(at, "%H:%M")}"
      at.year == now.year -> Calendar.strftime(at, "%-d %b, %H:%M")
      true -> Calendar.strftime(at, "%-d %b %Y, %H:%M")
    end
  end

  @doc false
  def clock_label(%DateTime{} = at, now \\ DateTime.utc_now()) do
    case Date.diff(DateTime.to_date(now), DateTime.to_date(at)) do
      0 -> "Today, #{Calendar.strftime(at, "%H:%M:%S")}"
      1 -> "Yesterday, #{Calendar.strftime(at, "%H:%M:%S")}"
      _ -> Calendar.strftime(at, "%-d %b %Y, %H:%M:%S")
    end
  end

  @doc "\"20 Sep 2026, 14:02:11 UTC\"."
  def absolute(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M:%S UTC")
  def absolute(_at), do: nil

  @doc """
  An event's time inside a run, as an offset from `run.started`: "+0:08.1", "+1:02:08"
  past an hour, "before start" for an event timed before it (the ping).
  """
  attr :at, :any, required: true
  attr :from, :any, required: true
  attr :class, :any, default: nil

  def offset(assigns) do
    ~H"""
    <span
      class={["font-mono text-[11.5px] text-faint tabular-nums whitespace-nowrap", @class]}
      title={absolute_ms(@at)}
    >{format_offset(@at, @from)}</span>
    """
  end

  @doc false
  def format_offset(%DateTime{} = at, %DateTime{} = from) do
    ms = DateTime.diff(at, from, :millisecond)

    cond do
      ms < 0 ->
        "before start"

      ms >= 3_600_000 ->
        s = div(ms, 1000)
        "+#{div(s, 3600)}:#{pad(div(rem(s, 3600), 60))}:#{pad(rem(s, 60))}"

      true ->
        tenths = div(ms, 100)
        "+#{div(tenths, 600)}:#{pad(div(rem(tenths, 600), 10))}.#{rem(tenths, 10)}"
    end
  end

  def format_offset(_at, _from), do: "n/a"

  defp absolute_ms(%DateTime{} = at) do
    ms =
      at.microsecond |> elem(0) |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")

    Calendar.strftime(at, "%-d %b %Y, %H:%M:%S") <> "." <> ms <> " UTC"
  end

  defp absolute_ms(_at), do: nil

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil

  ## rd4. Key and value strip

  @doc "The run header's facts as one bordered object."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def kvs(assigns) do
    ~H"""
    <dl id={@id} class={["q-kvs", @class]}>{render_slot(@inner_block)}</dl>
    """
  end

  attr :label, :string, required: true
  attr :tip, :string, default: nil, doc: "turns the label into a term hover"
  attr :mono, :boolean, default: false
  attr :title, :string, default: nil, doc: "the full value, when the cell may truncate it"
  slot :inner_block, required: true
  slot :sub, doc: "a faint second value on the same line"

  def kv(assigns) do
    ~H"""
    <div class="q-kv">
      <dt>
        <.term :if={@tip} word={@label} standard={@tip} class="q-tip-wide tooltip-right" />
        <span :if={!@tip}>{@label}</span>
      </dt>
      <dd class={@mono && "font-mono !text-[12.5px]"} title={@title}>
        {render_slot(@inner_block)}
        <small :if={@sub != []} class="font-mono">{render_slot(@sub)}</small>
      </dd>
    </div>
    """
  end

  ## rd5. Label chip

  @doc "One label of a run: the key on a tinted ground, the value beside it."
  attr :key, :string, required: true
  attr :value, :string, required: true
  attr :navigate, :string, default: nil

  def label_chip(assigns) do
    assigns = assign(assigns, :shown, middle(assigns.value, 32))

    ~H"""
    <.link :if={@navigate} navigate={@navigate} class="q-label q-label-link" title={@value}>
      <i>{@key}</i><b>{@shown}</b>
    </.link>
    <span :if={!@navigate} class="q-label" title={@value}><i>{@key}</i><b>{@shown}</b></span>
    """
  end

  @doc "A run's labels in the record's order, with forge, repository and task first."
  def ordered_labels(%{} = labels) do
    first = for key <- ~w(forge repository task), value = labels[key], do: {key, value}
    first ++ (labels |> Map.drop(~w(forge repository task)) |> Enum.sort())
  end

  def ordered_labels(_labels), do: []

  @doc "Cuts a long value in the middle: both ends tell more than the start alone."
  def middle(value, max) when is_binary(value) do
    if String.length(value) <= max do
      value
    else
      head = div(max - 1, 2)
      tail = max - 1 - head
      String.slice(value, 0, head) <> "…" <> String.slice(value, -tail, tail)
    end
  end

  def middle(value, _max), do: value

  @doc "The first eight characters of a run id, as the runner prints it."
  def short_id(run_id) when is_binary(run_id), do: String.slice(run_id, 0, 8)
  def short_id(_run_id), do: "n/a"

  @doc "\"1 run\", \"3 runs\"; `plural` for the irregular."
  def count_noun(count, noun, plural \\ nil)
  def count_noun(1, noun, _plural), do: "1 #{noun}"
  def count_noun(count, noun, nil), do: "#{delimited(count)} #{noun}s"
  def count_noun(count, _noun, plural), do: "#{delimited(count)} #{plural}"

  @doc "1240 as \"1,240\"."
  def delimited(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+$)/, ",")
  end

  ## rd6. Alive indicator

  @doc """
  The line at the right of a run's title: whether the record is still being written, and
  when it last was. Ticking text is not a live region; the page's announcer says the change.
  """
  attr :id, :string, default: "run-alive"
  attr :state, :string, required: true
  attr :last_heartbeat_at, :any, default: nil
  attr :last_event_at, :any, default: nil
  attr :interval, :integer, default: nil
  attr :quiet, :boolean, default: false
  attr :run, :any, default: nil, doc: "the run, for the sentences of the ended states"
  attr :class, :any, default: nil

  def alive(assigns) do
    assigns = assign(assigns, :since, assigns.last_heartbeat_at || assigns.last_event_at)

    ~H"""
    <span
      id={@id}
      role="status"
      aria-live="off"
      class={["q-alive", @state == "running" && @quiet && "q-alive-amber", @class]}
    >
      <%= cond do %>
        <% @state == "running" and @quiet -> %>
          <span class="q-dot" aria-hidden="true"></span>
          <span class="tooltip tooltip-left q-tip-wide" tabindex="0" data-tip={quiet_tip(@interval)}>
            No heartbeat for <.seconds_since at={@since} />
          </span>
        <% @state == "running" and @since -> %>
          <span class="q-dot q-ripple" aria-hidden="true"></span>
          <span class="q-alive-on">
            Alive, {if is_nil(@last_heartbeat_at), do: "last event "}<.seconds_since at={@since} />
            ago
          </span>
          <span class="q-alive-off">Reconnecting</span>
        <% @state == "running" -> %>
          <span>Alive</span>
        <% true -> %>
          <span>{ended_sentence(@state, @run)}</span>
      <% end %>
    </span>
    """
  end

  attr :at, :any, required: true

  defp seconds_since(assigns) do
    ~H"""
    <time data-tick="seconds" data-since={iso(@at)} aria-live="off" class="tabular-nums">{format_seconds(
      max(DateTime.diff(DateTime.utc_now(), @at, :second), 0)
    )}</time>
    """
  end

  defp ended_sentence("pending", _run), do: "Ping only"

  defp ended_sentence("exited", %{duration_ms: ms}) when is_integer(ms),
    do: "Exited #{format_duration_ms(ms)} after it started"

  defp ended_sentence("exited", _run), do: "Exited"

  defp ended_sentence("failed", %{signal: signal}) when is_binary(signal) and signal != "",
    do: "Failed with #{signal}"

  defp ended_sentence("failed", %{exit_code: code}) when is_integer(code) and code != -1,
    do: "Failed with exit #{code}"

  defp ended_sentence("failed", _run), do: "Failed"

  defp ended_sentence("timed_out", %{duration_ms: ms}) when is_integer(ms),
    do: "Timed out after #{format_duration_ms(ms)}"

  defp ended_sentence("timed_out", _run), do: "Timed out"

  defp ended_sentence("lost", %{} = run) do
    case Map.get(run, :last_heartbeat_at) || Map.get(run, :last_event_at) do
      %DateTime{} = at -> "Lost. Last heard #{Calendar.strftime(at, "%-d %b %Y, %H:%M")}"
      _ -> "Lost"
    end
  end

  defp ended_sentence("lost", _run), do: "Lost"
  defp ended_sentence("closed", %{closed_at: %DateTime{} = at}), do: "Closed #{short_date(at)}"
  defp ended_sentence("closed", _run), do: "Closed"

  ## rd7. Filter bar

  @doc """
  The row of filter chips. Every chip is a query parameter; the LiveView patches the URL.
  """
  attr :id, :string, required: true
  attr :clear, :string, default: nil, doc: "patch target with no filters; shows Clear"
  attr :label, :string, default: "Filters"
  slot :inner_block, required: true
  slot :trailing, doc: "the group-by control, the summary"

  def filter_bar(assigns) do
    ~H"""
    <div id={@id} class="q-filters" role="group" aria-label={@label}>
      {render_slot(@inner_block)}
      <.link :if={@clear} id={"#{@id}-clear"} patch={@clear} class="q-filters-clear">Clear</.link>
      <span class="q-filters-grow"></span>
      {render_slot(@trailing)}
    </div>
    """
  end

  @doc """
  One filter: a dashed chip while unset, a solid one with its value and a remove button once
  set. The menu is a form; a change sends `event` with the form's fields (`name` or
  `name[]`, and `from` and `to` when `dates` is given), and the LiveView patches.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true, doc: "the query parameter"
  attr :label, :string, required: true
  attr :value, :any, default: nil, doc: "nil is unset; a string or a list"
  attr :options, :list, required: true, doc: "[{label, value, count}]"
  attr :multiple, :boolean, default: false
  attr :remove, :string, default: nil, doc: "patch target without this filter"
  attr :event, :string, default: "filter"

  attr :dates, :map,
    default: nil,
    doc: "%{from: iso date or nil, to: …}: adds the two date inputs"

  attr :value_label, :string, default: nil, doc: "overrides the words of the set value"

  def filter(assigns) do
    values = assigns.value |> List.wrap() |> Enum.map(&to_string/1)
    id = assigns.id || "filter-#{assigns.name}"

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:values, values)
      |> assign(:set?, values != [])
      |> assign(:shown, assigns.value_label || shown_value(values, assigns.options))

    ~H"""
    <div
      id={@id}
      class="q-filter dropdown"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <span class={["q-chip", @set? && "q-chip-on"]}>
        <button
          id={"#{@id}-button"}
          type="button"
          class="q-chip-main"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-label={
            if @set?, do: "#{@label}: #{@shown}, change", else: "Filter by #{String.downcase(@label)}"
          }
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        >
          <.icon :if={!@set?} name="hero-plus-micro" class="size-4 text-faint" />
          {@label}
          <b :if={@set?}>{@shown}</b>
        </button>
        <.link
          :if={@set? && @remove}
          id={"#{@id}-remove"}
          patch={@remove}
          class="q-chip-x"
          aria-label={"Remove filter: #{String.downcase(@label)} #{@shown}"}
        >
          <.icon name="hero-x-mark-micro" class="size-3" />
        </.link>
      </span>
      <div class="dropdown-content q-filter-menu left-0 top-full mt-1.5">
        <input
          :if={length(@options) > 8}
          id={"#{@id}-search"}
          type="search"
          class="input input-sm q-filter-search"
          placeholder={"Find a #{String.downcase(@label)}"}
          aria-label={"Find a #{String.downcase(@label)}"}
          data-filter-search
          phx-update="ignore"
          autocomplete="off"
        />
        <form id={"#{@id}-form"} phx-change={@event} phx-submit={@event}>
          <input type="hidden" name="_filter" value={@name} />
          <ul class="q-filter-options" aria-label={@label}>
            <li :if={@options == []} class="px-2 py-1.5 text-xs text-faint">
              Nothing to filter by yet
            </li>
            <li
              :for={{label, value, count} <- @options}
              data-filter-option={String.downcase(to_string(label))}
            >
              <label class="q-filter-option" data-menu-close={!@multiple}>
                <input
                  type={if @multiple, do: "checkbox", else: "radio"}
                  name={if @multiple, do: "#{@name}[]", else: @name}
                  value={value}
                  checked={to_string(value) in @values}
                  class={if @multiple, do: "checkbox checkbox-xs", else: "radio radio-xs"}
                />
                <span class="min-w-0 flex-1 truncate" title={label}>{label}</span>
                <span :if={count} class="font-mono text-[11.5px] text-faint tabular-nums">
                  {count}
                </span>
              </label>
            </li>
          </ul>
          <div :if={@dates} class="q-filter-dates">
            <label>
              <span>From</span>
              <input
                type="date"
                name="from"
                value={@dates[:from]}
                class="input input-sm"
                phx-debounce="blur"
              />
            </label>
            <label>
              <span>To</span>
              <input
                type="date"
                name="to"
                value={@dates[:to]}
                class="input input-sm"
                phx-debounce="blur"
              />
            </label>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp shown_value([one], options), do: option_label(one, options)

  defp shown_value([a, b], options),
    do: "#{option_label(a, options)}, #{option_label(b, options)}"

  defp shown_value(values, _options), do: "#{length(values)} selected"

  defp option_label(value, options) do
    Enum.find_value(options, value, fn {label, v, _count} ->
      if to_string(v) == value, do: to_string(label)
    end)
  end

  @doc "A chip that is on or off, such as \"Has denials\"."
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :pressed, :boolean, default: false
  attr :patch, :string, required: true

  def filter_toggle(assigns) do
    ~H"""
    <.link
      id={@id || "filter-#{@name}"}
      patch={@patch}
      role="button"
      aria-pressed={to_string(@pressed)}
      class="q-chip q-chip-toggle"
    >
      <.icon :if={@icon} name={@icon} class="size-4" />{@label}
    </.link>
    """
  end

  @doc """
  The segmented control of the theme menu, as links: the group-by control and the decision
  filter. Every segment is a patch.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :segment, required: true do
    attr :patch, :string, required: true
    attr :pressed, :boolean
    attr :count, :any
  end

  def segments(assigns) do
    ~H"""
    <div id={@id} class="q-seg" role="group" aria-label={@label}>
      <.link
        :for={segment <- @segment}
        patch={segment.patch}
        role="button"
        aria-pressed={to_string(segment[:pressed] == true)}
      >
        {render_slot(segment)}
        <span :if={segment[:count]} class="font-mono text-[11px] text-faint tabular-nums">
          {segment[:count]}
        </span>
      </.link>
    </div>
    """
  end

  ## rd9. Tabs

  @doc "The tabs of a second-level page. Links, not an ARIA tablist: each tab is a URL."
  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :tab, required: true do
    attr :patch, :string, required: true
    attr :icon, :string
    attr :current, :boolean
    attr :count, :any
    attr :tone, :string
  end

  def tabs(assigns) do
    ~H"""
    <nav id={@id} class="q-tabs" aria-label={@label}>
      <.link
        :for={tab <- @tab}
        patch={tab.patch}
        aria-current={tab[:current] == true && "page"}
      >
        <.icon :if={tab[:icon]} name={tab[:icon]} class="size-4" />
        {render_slot(tab)}
        <span :if={tab[:count]} class={["q-tabs-n", tab[:tone] == "error" && "q-tabs-bad"]}>
          {tab[:count]}
        </span>
      </.link>
    </nav>
    """
  end

  ## rd12. Connection row and mark

  @doc "The 18 px mark of a decision: allowed is soft with a check, denied is solid with a bar."
  attr :decision, :string, required: true
  attr :class, :any, default: nil

  def decision_mark(assigns) do
    ~H"""
    <span
      class={["q-mark", if(@decision == "denied", do: "q-mark-no", else: "q-mark-ok"), @class]}
      title={decision_word(@decision)}
    >
      <.icon
        name={if @decision == "denied", do: "hero-no-symbol-micro", else: "hero-check-micro"}
        class="size-3"
      />
      <span class="sr-only">{decision_word(@decision)}</span>
    </span>
    """
  end

  defp decision_word("denied"), do: "Denied"
  defp decision_word("allowed"), do: "Allowed"
  defp decision_word(_other), do: "Unknown decision"

  @doc """
  One connection, the same wherever it appears. `inline` is the 32 px row of the timeline,
  `table` a row of a run's connections, `hive` a row of the hive's, with the disclosure of
  the runs that reached the destination.

  `connection` is a projection row (`last_decision`, `last_rule`, …) or a map read from one
  egress event (`decision`, `rule`, …); both spellings are read.
  """
  attr :id, :string, required: true
  attr :connection, :map, required: true
  attr :variant, :string, default: "table", values: ~w(inline table hive)
  attr :started_at, :any, default: nil, doc: "offsets instead of relative time, inside a run"
  attr :caption, :string, default: nil, doc: "inline: \"while 2 calls were open\""
  attr :open, :any, default: nil, doc: "hive: nil when closed, else %{runs: [...], total: n}"
  attr :toggle, :string, default: "toggle_destination"
  attr :more, :string, default: "more_destination_runs"
  attr :run_path, :any, default: nil, doc: "hive: a function from a run to its connections page"
  slot :trailing, doc: "reserved: a later milestone's allow and deny buttons"

  def connection_row(%{variant: "inline"} = assigns) do
    assigns = assign(assigns, :c, normalise(assigns.connection))

    ~H"""
    <div
      id={@id}
      class={["q-cx", @c.decision == "denied" && "q-cx-denied"]}
      data-decision={@c.decision}
    >
      <.decision_mark decision={@c.decision} />
      <.destination c={@c} />
      <span class="q-why"><.reason c={@c} variant="inline" /><span :if={@caption} class="text-faint"> · {@caption}</span></span>
      <.outcome value={@c.outcome} />
      <.offset
        :if={@started_at && @c.last_seen_at}
        at={@c.last_seen_at}
        from={@started_at}
        class="q-cx-at"
      />
      <span :if={!(@started_at && @c.last_seen_at)} class="q-cx-at"></span>
      <span class="q-slot">{render_slot(@trailing)}</span>
    </div>
    """
  end

  def connection_row(%{variant: "table"} = assigns) do
    assigns = assign(assigns, :c, normalise(assigns.connection))

    ~H"""
    <tr id={@id} class={["q-row", @c.decision == "denied" && "q-denied"]} data-decision={@c.decision}>
      <td>
        <div class="q-dcell"><.decision_mark decision={@c.decision} /><.destination c={@c} /></div>
      </td>
      <td class="q-num">{delimited(@c.attempts)}</td>
      <td class={["q-num", @c.allowed == 0 && "q-zero"]}>{delimited(@c.allowed)}</td>
      <td class={["q-num", if(@c.denied == 0, do: "q-zero", else: "q-bad")]}>
        {delimited(@c.denied)}
      </td>
      <td class="q-why"><.reason c={@c} variant="table" /></td>
      <td><.outcome value={@c.outcome} /></td>
      <td class="q-meta">
        <.seen c={@c} started_at={@started_at} />
      </td>
      <td class="q-slot-cell w-px"><span class="q-slot">{render_slot(@trailing)}</span></td>
    </tr>
    """
  end

  def connection_row(%{variant: "hive"} = assigns) do
    c = normalise(assigns.connection)

    assigns =
      assigns
      |> assign(:c, c)
      |> assign(:share, share(c.allowed, c.denied))

    ~H"""
    <tr id={@id} class={["q-row", @c.decision == "denied" && "q-denied"]} data-decision={@c.decision}>
      <td>
        <div class="q-dcell">
          <button
            type="button"
            id={"#{@id}-toggle"}
            class="q-expander"
            phx-click={@toggle}
            phx-value-id={@id}
            aria-expanded={to_string(@open != nil)}
            aria-controls={"#{@id}-runs"}
            aria-label={"Runs that reached #{destination_words(@c)}"}
          >
            <.icon name="hero-chevron-right-micro" class="size-3" />
          </button>
          <.decision_mark decision={@c.decision} /><.destination c={@c} />
        </div>
      </td>
      <td class="q-num">{delimited(@c.runs)}</td>
      <td class="q-num">{delimited(@c.attempts)}</td>
      <td>
        <span class="q-split" aria-hidden="true"><i style={"width:#{@share}%"}></i><u style={"width:#{100 - @share}%"}></u></span>
        <span class={[
          "ml-1.5 tabular-nums",
          if(@c.allowed == 0 and @c.denied > 0, do: "q-bad", else: "text-muted")
        ]}>
          {delimited(@c.allowed)} /
          <span class={@c.denied > 0 && "q-bad"}>{delimited(@c.denied)}</span>
        </span>
      </td>
      <td class="q-why">
        <.reason c={@c} variant="hive" /><span
          :if={@c.allowed > 0 and @c.denied > 0}
          class="text-faint"
        > · last attempt</span>
      </td>
      <td><.outcome value={@c.outcome} /></td>
      <td class="q-meta"><.relative_time at={@c.last_seen_at} /></td>
      <td class="q-slot-cell w-px"><span class="q-slot">{render_slot(@trailing)}</span></td>
    </tr>
    <tr :if={@open} id={"#{@id}-runs"} class="q-sub">
      <td colspan="8">
        <div class="q-sub-in">
          <h3>{count_noun(@open.total, "run")} reached this destination</h3>
          <div class="q-hits">
            <.link
              :for={hit <- @open.runs}
              id={"#{@id}-run-#{hit.run.run_id}"}
              navigate={@run_path && @run_path.(hit.run)}
              class="q-hit"
            >
              <.run_state
                state={hit.run.state}
                exit_code={hit.run.exit_code}
                signal={hit.run.signal}
                quiet_for={quiet_for(hit.run)}
                note={false}
              />
              <span class="truncate">
                <b :if={hit.run.task} class="font-medium">{hit.run.task}</b>
                <span class="font-mono text-xs text-faint">{short_id(hit.run.run_id)}</span>
              </span>
              <span class="truncate font-mono text-xs text-muted">
                {if hit.run.forge && hit.run.repository,
                  do: "#{hit.run.forge}/#{hit.run.repository}",
                  else: "Unassigned"}
              </span>
              <span class={["tabular-nums", hit.denied > 0 && "q-bad"]}>
                {if hit.denied > 0,
                  do: "#{delimited(hit.denied)} denied",
                  else: "#{delimited(hit.allowed)} allowed"}
              </span>
              <.relative_time at={hit.last_seen_at} class="text-[12.5px] text-muted" />
            </.link>
          </div>
          <button
            :if={length(@open.runs) < @open.total}
            type="button"
            id={"#{@id}-more"}
            class="btn btn-ghost btn-xs justify-self-start"
            phx-click={@more}
            phx-value-id={@id}
          >
            Show {min(10, @open.total - length(@open.runs))} more
          </button>
        </div>
      </td>
    </tr>
    """
  end

  # Both spellings of a connection, as one map with every key present.
  defp normalise(connection) do
    get = fn keys -> Enum.find_value(keys, &Map.get(connection, &1)) end

    %{
      host: get.([:host]),
      port: get.([:port]),
      path: get.([:path]) || "",
      method: get.([:method]),
      request_method: get.([:request_method, :last_request_method]),
      decision: get.([:decision, :last_decision]),
      rule: blank(get.([:rule, :last_rule])),
      path_rule: blank(get.([:path_rule, :last_path_rule])),
      credential: blank(get.([:credential, :last_credential])),
      outcome: get.([:outcome, :last_outcome]),
      mode: get.([:mode, :last_mode]),
      attempts: get.([:attempts]) || 0,
      allowed: get.([:allowed]) || 0,
      denied: get.([:denied]) || 0,
      runs: get.([:runs]) || 0,
      first_seen_at: get.([:first_seen_at, :at]),
      last_seen_at: get.([:last_seen_at, :at])
    }
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  defp share(allowed, denied) when allowed + denied > 0,
    do: round(allowed * 100 / (allowed + denied))

  defp share(_allowed, _denied), do: 100

  defp destination_words(c) do
    [c.host, request_line(c)]
    |> Enum.reject(&(&1 in [nil, "", "CONNECT", "HTTP"]))
    |> Enum.join(" ")
  end

  # The request line on a terminated host, else the proxy's method.
  defp request_line(%{path: path} = c) when path != "" do
    "#{c.request_method || c.method} #{path}"
  end

  defp request_line(c), do: c.method

  attr :c, :map, required: true

  defp destination(assigns) do
    assigns = assign(assigns, :line, request_line(assigns.c))

    ~H"""
    <span class="q-dest" title={"#{@c.host}:#{@c.port} #{@line}"}>
      {@c.host}<span class="text-faint">:{@c.port}</span>
      <span :if={@line} class="text-muted">{middle(@line, 56)}</span>
    </span>
    """
  end

  attr :c, :map, required: true
  attr :variant, :string, required: true

  # C3: one sentence from the decision, the rule, the path rule and the mode of the last
  # attempt. The strings are rf's.
  defp reason(assigns) do
    assigns = assign(assigns, :kind, reason_kind(assigns.c))

    ~H"""
    <b :if={@variant == "inline" && @c.decision == "denied"}>Denied. </b>
    <%= case @kind do %>
      <% :own_address -> %>
        <b>The wall refuses the machine's own address,</b> in either mode.
      <% :ambiguous_path -> %>
        <b>The path can be read two ways.</b> The wall denies it in either mode.
      <% :denied_no_rule -> %>
        <b>No rule matches.</b> {mode_sentence(@c.mode, :denies)}
      <% :denied_no_path_rule -> %>
        <b>Host allowed, no path rule matches.</b> {mode_sentence(@c.mode, :denies)}
      <% :denied_by_rule -> %>
        Rule
        <.rule value={@c.rule} /><span :if={@c.path_rule}>, path <.rule value={@c.path_rule} /></span>
      <% :allowed_no_rule -> %>
        <b>No rule matches.</b> {mode_sentence(@c.mode, :lets_through)}
      <% :allowed_by_rule -> %>
        <span :if={@variant == "inline"}><b>Allowed</b> by rule</span><span :if={@variant != "inline"}>Rule</span>
        <.rule value={@c.rule} /><span :if={@c.path_rule}>, path <.rule value={@c.path_rule} /></span><span :if={
          @c.credential
        }>, credential <.rule value={@c.credential} /></span>
      <% :unknown -> %>
        <span class="text-faint">n/a</span>
    <% end %>
    <span :if={@c.decision == "allowed" && @c.outcome == "refused"}>
      Closed when a new policy denied the host.
    </span>
    """
  end

  defp reason_kind(%{decision: "denied", rule: "wall:own-address"}), do: :own_address
  defp reason_kind(%{decision: "denied", path_rule: "wall:ambiguous-path"}), do: :ambiguous_path
  defp reason_kind(%{decision: "denied", rule: nil}), do: :denied_no_rule
  defp reason_kind(%{decision: "denied", path_rule: nil}), do: :denied_no_path_rule
  defp reason_kind(%{decision: "denied"}), do: :denied_by_rule
  defp reason_kind(%{decision: "allowed", rule: nil}), do: :allowed_no_rule
  defp reason_kind(%{decision: "allowed"}), do: :allowed_by_rule
  defp reason_kind(_c), do: :unknown

  # The mode is the event's; a row projected before the mode was kept says only what it knows.
  defp mode_sentence("enforce", :denies), do: "Enforce mode denies it."
  defp mode_sentence("observe", :lets_through), do: "Observe mode lets it through."
  defp mode_sentence(_mode, :denies), do: "The policy denies it."
  defp mode_sentence(_mode, :lets_through), do: "It was let through."

  attr :value, :string, required: true

  defp rule(assigns) do
    ~H"""
    <.mono class="q-rule" bare>{@value}</.mono>
    """
  end

  attr :value, :string, default: nil

  defp outcome(assigns) do
    ~H"""
    <span :if={@value == "connected"} class="q-outcome">Connected</span>
    <span :if={@value == "dial_failed"} class="q-outcome q-outcome-dial">Dial failed</span>
    <span :if={@value == "refused"} class="q-outcome q-outcome-refused">Refused</span>
    <span :if={@value not in ~w(connected dial_failed refused)} class="text-xs text-faint">
      {@value || "n/a"}
    </span>
    """
  end

  attr :c, :map, required: true
  attr :started_at, :any, default: nil

  defp seen(%{started_at: %DateTime{}} = assigns) do
    ~H"""
    <.offset at={@c.first_seen_at} from={@started_at} class="!text-[12.5px] !text-muted" />
    <span :if={@c.first_seen_at != @c.last_seen_at}>
      <span class="text-faint">to</span>
      <.offset at={@c.last_seen_at} from={@started_at} class="!text-[12.5px] !text-muted" />
    </span>
    """
  end

  defp seen(assigns) do
    ~H"""
    <.relative_time at={@c.first_seen_at} />
    <span :if={@c.first_seen_at != @c.last_seen_at}>
      <span class="text-faint">to</span> <.relative_time at={@c.last_seen_at} />
    </span>
    """
  end

  ## rd13. Connections tables

  @doc """
  The table of a run's connections (`variant="table"`, C1) or of the hive's across runs
  (`variant="hive"`, C2). `rows` are connections as `<.connection_row>` reads them; `row_id`
  gives each its DOM id (`"cx-<id>"` for a projection row, `"dst-<hash>"` for a destination).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the accessible name of the scroll region"
  attr :rows, :list, required: true
  attr :variant, :string, default: "table", values: ~w(table hive)
  attr :started_at, :any, default: nil
  attr :row_id, :any, default: nil
  attr :open, :map, default: %{}, doc: "hive: DOM id of an open destination => %{runs, total}"
  attr :run_path, :any, default: nil
  attr :class, :any, default: nil

  def connections_table(assigns) do
    assigns =
      assigns
      |> assign(:row_id, assigns.row_id || (&default_row_id/1))
      |> assign(:outcome_tip, @outcome_tip)

    ~H"""
    <div
      class={["overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs", @class]}
      tabindex="0"
      role="region"
      aria-label={@label}
    >
      <table class="table q-cxt">
        <thead>
          <tr :if={@variant == "table"}>
            <th scope="col">Destination</th>
            <th scope="col" class="q-num">Attempts</th>
            <th scope="col" class="q-num">Allowed</th>
            <th scope="col" class="q-num">Denied</th>
            <th scope="col">Reason</th>
            <th scope="col">
              <.term word="Outcome" standard={@outcome_tip} class="q-tip-wide tooltip-bottom" />
            </th>
            <th scope="col">First and last seen</th>
            <th scope="col" class="w-px"><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
          <tr :if={@variant == "hive"}>
            <th scope="col">Destination</th>
            <th scope="col" class="q-num">Runs</th>
            <th scope="col" class="q-num">Attempts</th>
            <th scope="col">Allowed / denied</th>
            <th scope="col">Reason</th>
            <th scope="col">
              <.term word="Outcome" standard={@outcome_tip} class="q-tip-wide tooltip-bottom" />
            </th>
            <th scope="col">Last seen</th>
            <th scope="col" class="w-px"><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
        </thead>
        <tbody id={@id}>
          <.connection_row
            :for={row <- @rows}
            id={@row_id.(row)}
            connection={row}
            variant={@variant}
            started_at={@started_at}
            open={@open[@row_id.(row)]}
            run_path={@run_path}
          />
        </tbody>
      </table>
    </div>
    """
  end

  defp default_row_id(%{id: id}) when is_binary(id), do: "cx-#{id}"
  defp default_row_id(row), do: destination_id(row)

  @doc "The DOM id of a destination across runs: never an index."
  def destination_id(%{host: host, port: port} = row),
    do: "dst-#{:erlang.phash2({host, port, Map.get(row, :path) || ""})}"

  ## rd15. New items pill

  @doc """
  The pill that counts what arrived while the reader was away from the live end. A button,
  not a live region. Hidden at zero. `on_click` is an event name or a `JS` command; the
  scroll container's selector rides on `data-target` for the hook that scrolls.
  """
  attr :id, :string, required: true
  attr :count, :integer, required: true
  attr :noun, :string, default: "event"
  attr :target, :string, required: true
  attr :on_click, :any, default: nil
  attr :rest, :global

  def new_items(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={["q-newpill", @count > 0 && "q-newpill-show"]}
      data-target={@target}
      data-count={@count}
      phx-click={@on_click}
      tabindex={if @count > 0, do: "0", else: "-1"}
      aria-hidden={to_string(@count == 0)}
      {@rest}
    >
      <.icon name="hero-arrow-down-micro" class="size-4" />
      <span>{delimited(@count)} new {if @count == 1, do: @noun, else: @noun <> "s"}</span>
    </button>
    """
  end
end
