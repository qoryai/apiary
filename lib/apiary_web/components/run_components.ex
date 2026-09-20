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
  rendered, so the server never re-renders for a clock. The browser's clock is never
  trusted: every ticking element carries the server's now at render (`data-now`), the hook
  learns its offset from the server from it, and counts on the server's time.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents,
    only: [badge: 1, button: 1, icon: 1, mono: 1, notice: 1, term: 1, short_date: 1]

  # Called by its full name below: `PolicyComponents` imports this module.
  alias ApiaryWeb.PolicyComponents

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
          tabindex="0"
          data-tip={closed_tip(@closed_at)}
        >{state_label(@state)}<span class="sr-only">. {closed_tip(@closed_at)}</span></span>
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
          data-now={iso(DateTime.utc_now())}
          aria-live="off"
          class="tabular-nums"
        >{format_seconds(@quiet_for)}</time>
        <span :if={!@quiet_since} class="tabular-nums">{format_seconds(@quiet_for)}</span>
        <span class="sr-only">. {quiet_tip(@interval)}</span>
      </span>
    </span>
    """
  end

  @doc "The word of a state, as the badge says it."
  def state_label("pending"), do: "Pending"
  def state_label("running"), do: "Running"
  def state_label("succeeded"), do: "Succeeded"
  def state_label("failed"), do: "Failed"
  def state_label("timed_out"), do: "Timed out"
  def state_label("lost"), do: "Lost"
  def state_label("closed"), do: "Closed"

  defp state_color("running", true), do: "warning"
  defp state_color("running", false), do: "info"
  defp state_color("succeeded", _), do: "success"
  defp state_color(state, _) when state in ~w(failed timed_out), do: "error"
  defp state_color("lost", _), do: "warning"
  defp state_color(_state, _), do: "neutral"

  defp state_glyph("succeeded"), do: "hero-check-micro"
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

  # What `Apiary.Runs.Liveness` holds a run to when it announced no interval, and its bounds.
  @default_beat 30
  @max_beat 3600

  @doc """
  The seconds a running run has been quiet for, or nil: set once the hive has heard no
  heartbeat for more than one interval. The server decides this, never the browser, and by
  the rule of `Apiary.Runs.Liveness`: silence is measured on the server's clock from when
  the last heartbeat was received, or, for a run that has not beaten yet, from when the
  hive first heard of it; a run that announced no valid interval is held to 30 seconds.
  """
  def quiet_for(run, now \\ DateTime.utc_now())

  def quiet_for(%{state: "running"} = run, now) do
    case heard_at(run) do
      %DateTime{} = at ->
        seconds = DateTime.diff(now, at, :second)
        if seconds > beat(run), do: seconds

      nil ->
        nil
    end
  end

  def quiet_for(_run, _now), do: nil

  @doc "When the server last heard the run is alive: its last heartbeat, else its first event."
  def heard_at(run), do: Map.get(run, :last_heartbeat_at) || Map.get(run, :inserted_at)

  @doc "The heartbeat interval the run is held to, in seconds: its own within bounds, else 30."
  def beat(run) do
    case Map.get(run, :heartbeat_interval_seconds) do
      interval when is_integer(interval) -> interval |> max(1) |> min(@max_beat)
      _ -> @default_beat
    end
  end

  @doc """
  What a running run's clock counts from, `{elapsed_seconds, elapsed_at}`: the runner's own
  `elapsed_seconds` of its last heartbeat and the server time that heartbeat was received;
  before the first heartbeat, zero at the moment the hive first heard of the run. Never the
  runner's `started_at`: its clock may be anywhere.
  """
  def elapsed(%{last_heartbeat_at: %DateTime{} = at, elapsed_seconds: seconds})
      when is_integer(seconds),
      do: {seconds, at}

  def elapsed(%{inserted_at: %DateTime{} = at}), do: {0, at}
  def elapsed(_run), do: {nil, nil}

  ## rd2. Duration

  @doc """
  A duration. `ms` for what has ended; `elapsed_seconds` with `elapsed_at` (the server time
  at which that value was true, see `elapsed/1`) for a clock that counts in the browser;
  `at_least_seconds` for a run whose heartbeats stopped. Nothing given: "n/a".
  """
  attr :id, :string, default: nil
  attr :ms, :integer, default: nil
  attr :elapsed_seconds, :integer, default: nil
  attr :elapsed_at, :any, default: nil, doc: "the server time at which elapsed_seconds was true"
  attr :running_since, :any, default: nil, doc: "deprecated and ignored: the runner's clock"
  attr :at_least_seconds, :integer, default: nil
  attr :precise, :boolean, default: false, doc: "tenths of a second under a minute, for tools"
  attr :so_far, :boolean, default: false, doc: "the run header adds the words"
  attr :class, :any, default: nil

  def duration(%{ms: ms} = assigns) when is_integer(ms) do
    ~H"""
    <span id={@id} class={["tabular-nums", @class]}>{format_duration_ms(@ms, @precise)}</span>
    """
  end

  def duration(%{elapsed_seconds: seconds, elapsed_at: %DateTime{}} = assigns)
      when is_integer(seconds) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <span class={["tabular-nums", @class]}>
      <time
        id={@id}
        phx-hook={@id && "Ticker"}
        data-tick="duration"
        data-base={@elapsed_seconds}
        data-since={iso(@elapsed_at)}
        data-now={iso(@now)}
        aria-live="off"
      >{format_seconds(@elapsed_seconds + max(DateTime.diff(@now, @elapsed_at, :second), 0))}</time>
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
      at least {format_seconds(@at_least_seconds)}<span class="sr-only">. {@tip}</span>
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
      data-now={iso(DateTime.utc_now())}
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
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :sub, doc: "a faint second value on the same line"

  def kv(assigns) do
    ~H"""
    <div class={["q-kv", @class]}>
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
            No heartbeat for
            <.seconds_since at={@since} /><span class="sr-only">. {quiet_tip(@interval)}</span>
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
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <time
      data-tick="seconds"
      data-since={iso(@at)}
      data-now={iso(@now)}
      aria-live="off"
      class="tabular-nums"
    >{format_seconds(max(DateTime.diff(@now, @at, :second), 0))}</time>
    """
  end

  defp ended_sentence("pending", _run), do: "Ping only"

  defp ended_sentence("succeeded", %{duration_ms: ms}) when is_integer(ms),
    do: "Succeeded #{format_duration_ms(ms)} after it started"

  defp ended_sentence("succeeded", _run), do: "Succeeded"

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
  set. What opens is a small dialog, not a menu: it holds a form of checkboxes or radios
  (and dates), and is named as one. A change sends `event` with the form's fields (`name` or
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
  attr :total, :integer, default: nil, doc: "how many values there are, when not all are options"
  attr :query, :string, default: nil, doc: "what the reader typed to narrow the options"
  attr :narrow, :string, default: "narrow", doc: "the event of the narrowing box"

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
          aria-haspopup="dialog"
          aria-controls={"#{@id}-panel"}
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
      <div
        id={"#{@id}-panel"}
        role="dialog"
        aria-label={"Filter by #{String.downcase(@label)}"}
        class="dropdown-content q-filter-menu left-0 top-full mt-1.5"
      >
        <form
          :if={@query not in [nil, ""] or (@total || length(@options)) > 8}
          id={"#{@id}-narrow"}
          phx-change={@narrow}
          phx-submit={@narrow}
        >
          <input type="hidden" name="_filter" value={@name} />
          <input
            id={"#{@id}-search"}
            type="search"
            name="q"
            value={@query}
            class="input input-sm q-filter-search"
            placeholder={"Find a #{String.downcase(@label)}"}
            aria-label={"Find a #{String.downcase(@label)}"}
            phx-debounce="250"
            autocomplete="off"
          />
        </form>
        <p
          :if={@total && @total > length(@options)}
          id={"#{@id}-more"}
          class="px-2 pb-1 text-xs text-faint"
        >
          Showing {length(@options)} of {delimited(@total)}: type to narrow
        </p>
        <form id={"#{@id}-form"} phx-change={@event} phx-submit={@event}>
          <input type="hidden" name="_filter" value={@name} />
          <ul class="q-filter-options" aria-label={@label}>
            <li :if={@options == []} class="px-2 py-1.5 text-xs text-faint">
              {if @query in [nil, ""], do: "Nothing to filter by yet", else: "Nothing matches"}
            </li>
            <li :for={{label, value, count} <- @options}>
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

  # A real button that patches: it answers Space as well as Enter, which a link dressed as
  # a button does not.
  def filter_toggle(assigns) do
    ~H"""
    <button
      id={@id || "filter-#{@name}"}
      type="button"
      phx-click={JS.patch(@patch)}
      aria-pressed={to_string(@pressed)}
      class="q-chip q-chip-toggle"
    >
      <.icon :if={@icon} name={@icon} class="size-4" />{@label}
    </button>
    """
  end

  @doc """
  The segmented control of the theme menu: the group-by control and the decision filter.
  Every segment is a button that patches, so the URL changes and Space works.
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
      <button
        :for={segment <- @segment}
        type="button"
        phx-click={JS.patch(segment.patch)}
        aria-pressed={to_string(segment[:pressed] == true)}
      >
        {render_slot(segment)}
        <span :if={segment[:count]} class="font-mono text-[11px] text-faint tabular-nums">
          {segment[:count]}
        </span>
      </button>
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

  attr :act, :map,
    default: nil,
    doc: "table and hive: what the row may ask of the policy, see `rule_action/1`"

  slot :trailing, doc: "what the slot holds when `act` is not given"

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
      <td class="q-why">
        <.reason c={@c} variant="table" />
        <.after_line :if={@act && @act[:after]} id={"#{@id}-after"} line={@act.after} />
      </td>
      <td><.outcome value={@c.outcome} /></td>
      <td class="q-meta">
        <.seen c={@c} started_at={@started_at} />
      </td>
      <td class="q-slot-cell w-px">
        <span class="q-slot">
          <.rule_action :if={@act} id={"#{@id}-act"} connection={@c} {rule_action_attrs(@act)} />
          {if !@act, do: render_slot(@trailing)}
        </span>
      </td>
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
            phx-value-host={@c.host}
            phx-value-port={@c.port}
            phx-value-path={@c.path}
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
        <.after_line :if={@act && @act[:after]} id={"#{@id}-after"} line={@act.after} />
      </td>
      <td><.outcome value={@c.outcome} /></td>
      <td class="q-meta"><.relative_time at={@c.last_seen_at} /></td>
      <td class="q-slot-cell w-px">
        <span class="q-slot">
          <.rule_action :if={@act} id={"#{@id}-act"} connection={@c} {rule_action_attrs(@act)} />
          {if !@act, do: render_slot(@trailing)}
        </span>
      </td>
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
                <span class={["font-mono text-xs text-faint", hit.run.task && "ml-1"]}>
                  {short_id(hit.run.run_id)}
                </span>
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
            phx-value-host={@c.host}
            phx-value-port={@c.port}
            phx-value-path={@c.path}
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
      <span :if={@line} class="q-rq text-muted">{middle(@line, 56)}</span>
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

  attr :open, :map,
    default: %{},
    doc: "hive: `destination_key/1` of an open destination => %{runs, total}"

  attr :run_path, :any, default: nil

  attr :acts, :map,
    default: nil,
    doc:
      "a row's DOM id => what it may ask of the policy (`rule_action/1`); nil leaves the slots empty"

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
            <th scope="col" class="w-px"><span class="sr-only">Rule actions</span></th>
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
            <th scope="col" class="w-px"><span class="sr-only">Rule actions</span></th>
          </tr>
        </thead>
        <tbody id={@id}>
          <.connection_row
            :for={row <- @rows}
            id={@row_id.(row)}
            connection={row}
            variant={@variant}
            started_at={@started_at}
            open={@open[destination_key(row)]}
            run_path={@run_path}
            act={@acts && @acts[@row_id.(row)]}
          />
        </tbody>
      </table>
    </div>
    """
  end

  defp default_row_id(%{id: id}) when is_binary(id), do: "cx-#{id}"
  defp default_row_id(row), do: destination_id(row)

  @doc """
  The DOM id of a destination across runs. Never an index, and not a short hash either: the
  host and the path are a runner's strings, and two of them must not be made to share an
  id. See `dom_token/1`.
  """
  def destination_id(row), do: "dst-" <> dom_token(destination_key(row))

  @doc "What a destination is: `{host, port, path}`. What the page opens and finds rows by."
  def destination_key(%{host: host, port: port} = row),
    do: {host, port, Map.get(row, :path) || ""}

  @doc """
  A token for a DOM id made from strings the page does not control: the first 16
  characters of the lower-case Base32 of the SHA-256 of the term, 80 bits of it, so a
  collision cannot be arranged.
  """
  def dom_token(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term))
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 16)
  end

  ## pd8. What a connection's row may ask of the policy (brief-policy.md)

  defp rule_action_attrs(act) do
    %{
      standing: act.standing,
      values: act[:values] || %{},
      rule_path: act[:rule_path],
      entry_host: act[:entry_host],
      expanded: act[:expanded] == true
    }
  end

  @doc """
  The trailing slot of a connection's row. `standing` says what it holds: a button that
  opens the popover (`:can_allow`, `:can_deny`), a padlock that opens the refusal
  (`:locked_deny`, `:locked_allow`), nothing the wall's refusals (`:wall`) and a host no
  rule can name (`:unnameable`), and the link to the rule once one answers the row
  (`{:rule_added, _}`). Always visible: never on hover alone.

  `values` ride on the `rule_open` event; they name the row and are looked up among the
  rows the page holds, never trusted.
  """
  attr :id, :string, required: true
  attr :connection, :map, required: true
  attr :standing, :any, required: true
  attr :values, :map, default: %{}
  attr :rule_path, :string, default: nil
  attr :entry_host, :string, default: nil, doc: "the host of the locked rule, for the tooltip"
  attr :expanded, :boolean, default: false

  def rule_action(%{standing: standing} = assigns) when standing in [:can_allow, :can_deny] do
    assigns = assign(assigns, :action, if(standing == :can_allow, do: "allow", else: "deny"))

    ~H"""
    <button
      type="button"
      id={@id}
      class={["btn btn-xs q-rowbtn", @action == "deny" && "btn-ghost"]}
      phx-click={JS.push("rule_open", value: Map.put(@values, "action", @action))}
      aria-haspopup="dialog"
      aria-expanded={to_string(@expanded)}
      aria-label={"#{String.capitalize(@action)} #{@connection.host}"}
    >
      {String.capitalize(@action)}
    </button>
    """
  end

  def rule_action(%{standing: standing} = assigns)
      when standing in [:locked_deny, :locked_allow] do
    assigns =
      assign(
        assigns,
        :tip,
        "A locked hive rule #{if standing == :locked_deny, do: "denies", else: "allows"} #{assigns.entry_host || assigns.connection.host}"
      )

    ~H"""
    <button
      type="button"
      id={@id}
      class="btn btn-ghost btn-xs btn-square q-rowbtn tooltip tooltip-left"
      data-tip={@tip}
      phx-click={
        JS.push("rule_open",
          value: Map.put(@values, "action", if(@standing == :locked_deny, do: "allow", else: "deny"))
        )
      }
      aria-haspopup="dialog"
      aria-expanded={to_string(@expanded)}
      aria-label={@tip}
    >
      <.icon name="hero-lock-closed-micro" class="size-3.5" />
    </button>
    """
  end

  def rule_action(%{standing: {:rule_added, _action}} = assigns) do
    ~H"""
    <.link
      :if={@rule_path}
      id={@id}
      navigate={@rule_path}
      class="btn btn-ghost btn-xs q-rowbtn"
      aria-label={"The rule for #{@connection.host}"}
    >
      Rule
    </.link>
    """
  end

  def rule_action(%{standing: :wall} = assigns) do
    ~H|<span id={@id} class="sr-only">No rule changes this</span>|
  end

  def rule_action(assigns) do
    ~H|<span id={@id} class="sr-only">No rule can name this host</span>|
  end

  @doc """
  The line a row gains once a rule answers it (pd8, "After"). The row above it is the
  record and stays as it was. `line` is `%{action, level, version, by, at, state,
  reloaded_at}`; `state` is `:pending` (the run is alive and has not reported the digest
  in force), `:in_force` (it has: claimed from the record, never after a timer),
  `:ended`, `:machine` (the run takes no policy from this server) or `:hive` (the hive's
  page, which says nothing of a run).
  """
  attr :id, :string, required: true
  attr :line, :map, required: true

  def after_line(assigns) do
    ~H"""
    <div id={@id} class="q-after" data-state={@line.state}>
      <.badge color={after_color(@line.state)}>
        <.icon name="hero-shield-check-micro" class="size-3" />{if @line.state == :in_force,
          do: "In force in this run",
          else: "Rule added"}
      </.badge>
      <span>
        {if @line.action == :deny, do: "Denied", else: "Allowed"} for {if @line.level ==
                                                                            :repository,
                                                                          do: "this repository",
                                                                          else: "the hive"}<span :if={
          @line.version
        }> in <.scoped_version version={@line.version} class="text-xs" /></span><span :if={
          @line.state != :in_force && @line.by
        }> by {@line.by}</span><span :if={@line.state != :in_force && @line.at}> · <.relative_time at={@line.at} /></span>. {after_sentence(
          @line
        )}
      </span>
    </div>
    """
  end

  defp after_color(:in_force), do: "success"
  defp after_color(:pending), do: "info"
  defp after_color(:hive), do: "info"
  defp after_color(_state), do: "neutral"

  defp after_sentence(%{state: :pending}), do: "The run has not reloaded yet."

  defp after_sentence(%{state: :in_force, reloaded_at: seq}) when is_integer(seq),
    do: "The run reloaded at ##{seq |> Integer.to_string() |> String.pad_leading(4, "0")}."

  defp after_sentence(%{state: :in_force}), do: "The run has reported it."

  defp after_sentence(%{state: :ended}),
    do: "This run has ended; the next run of the repository has it."

  defp after_sentence(%{state: :machine}),
    do: "This run uses its machine's policy and does not take this one."

  defp after_sentence(_line), do: nil

  @doc """
  The popover of a row's Allow or Deny (pd8): a `popover` element in the top layer, so the
  table's scroll container cannot clip it, placed under its button by the `RulePopover`
  hook and a bottom sheet below 768 px. `popover` is the page's state of it:

      %{anchor:, action: :allow | :deny, host:, path:, page: :run | :hive, level:,
        repository: %{label:} | nil, repositories: [%{id, label, runs}], choice:,
        what: %{repository:, hive:}, own_rule:, hive:, alive:, fetched:, interval:, consequence:, error:,
        refusal: nil | %{standing:, rule:, locked_by:, locked_at:, owner:, rule_path:}}

  The form changes with `rule_change` and is sent with `rule_submit`; `rule_cancel`
  closes it. A refusal has no form.
  """
  attr :id, :string, default: "rule-popover"
  attr :popover, :map, required: true

  def rule_popover(%{popover: %{refusal: %{}}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="q-pop"
      popover="auto"
      phx-hook="RulePopover"
      data-anchor={@popover.anchor}
      role="dialog"
      aria-labelledby={"#{@id}-title"}
    >
      <header>
        <.icon name="hero-lock-closed-micro" class="size-4 text-faint" />
        <h3 id={"#{@id}-title"}>
          <span class="q-pop-host">{middle(@popover.host, 40)}</span>
          stays {if @popover.refusal.standing == :locked_deny, do: "denied", else: "allowed"}
        </h3>
      </header>
      <div class="q-pop-body">
        <.notice kind={:warning}>
          <span id={"#{@id}-refusal"}>
            A locked hive rule {if @popover.refusal.standing == :locked_deny,
              do: "denies",
              else: "allows"}
            <.mono bare>{@popover.refusal.rule}</.mono>. It holds against every repository, so {if @popover.refusal.standing ==
                                                                                                     :locked_deny,
                                                                                                   do:
                                                                                                     "no rule added here would change what happens.",
                                                                                                   else:
                                                                                                     "a deny added here would change nothing."}
            <span :if={@popover.refusal.locked_by}>
              Locked by {@popover.refusal.locked_by}<span :if={@popover.refusal.locked_at}> on {short_date(@popover.refusal.locked_at)}</span>.
            </span>
            {if @popover.refusal.owner,
              do: "You can change or unlock it on the hive's policy page.",
              else: "Only an owner can change or unlock it."}
          </span>
        </.notice>
      </div>
      <footer>
        <.button id={"#{@id}-close"} phx-click="rule_cancel" data-autofocus>Close</.button>
        <.button id={"#{@id}-locked-rule"} navigate={@popover.refusal.rule_path}>
          Show the locked rule
        </.button>
      </footer>
    </div>
    """
  end

  def rule_popover(assigns) do
    assigns =
      assigns
      |> assign(:deny, assigns.popover.action == :deny)
      |> assign(:what, popover_what(assigns.popover))
      |> assign(:ready, popover_ready?(assigns.popover))

    ~H"""
    <div
      id={@id}
      class="q-pop"
      popover="auto"
      phx-hook="RulePopover"
      data-anchor={@popover.anchor}
      role="dialog"
      aria-labelledby={"#{@id}-title"}
    >
      <form id={"#{@id}-form"} phx-change="rule_change" phx-submit="rule_submit">
        <header>
          <PolicyComponents.rule_mark action={if @deny, do: "deny", else: "allow"} />
          <h3 id={"#{@id}-title"}>
            {if @deny, do: "Deny", else: "Allow"}{if @what && @what.kind == :path, do: " on"}
            <span class="q-pop-host" title={@popover.host}>{middle(@popover.host, 40)}</span>
          </h3>
        </header>
        <div class="q-pop-body">
          <div :if={@popover.error} id={"#{@id}-error"} role="alert">
            <.notice kind={:error}>{@popover.error}</.notice>
          </div>

          <fieldset :if={@what && @what.kind == :path} id={"#{@id}-what-set"}>
            <legend>
              What. This host has path rules:
              <.mono :for={path <- Enum.take(@what.paths, 6)} bare class="q-rule">
                {middle(path, 40)}
              </.mono>
              <span :if={length(@what.paths) > 6}>
                and {length(@what.paths) - 6} more
              </span>
              <span :if={@what.paths == []}>none, so no path is allowed</span>
            </legend>
            <p id={"#{@id}-what"} class="q-pop-what">
              <b>This path</b>
              <.mono bare class="q-rule">{middle(@popover.path, 64)}</.mono>
              {if @deny,
                do: "is taken out of the paths in force for the host.",
                else: "is added to the paths in force for the host."}
            </p>
          </fieldset>

          <fieldset>
            <legend>For</legend>
            <label :if={@popover.page == :run and @popover.repository} class="q-popt">
              <input
                type="radio"
                name="for"
                value="repository"
                checked={@popover.level == :repository}
              />
              <span>
                <b>This repository</b>
                <span class="font-mono text-xs text-muted">{middle(@popover.repository.label, 48)}</span>
              </span>
              <small :if={@deny && @popover.consequence[:repository]}>
                {@popover.consequence.repository}
              </small>
            </label>
            <label :if={@popover.page == :hive and @popover.repositories != []} class="q-popt">
              <input
                type="radio"
                name="for"
                value="repository"
                checked={@popover.level == :repository}
              />
              <span><b>One repository</b></span>
              <small :if={@deny && @popover.consequence[:repository]}>
                {@popover.consequence.repository}
              </small>
            </label>
            <%!-- Outside the label: inside it, every option would be part of the radio's name. --%>
            <div
              :if={@popover.page == :hive and @popover.repositories != []}
              class="q-popt-more"
            >
              <select
                name="repository"
                id={"#{@id}-repository"}
                class="select select-sm q-pop-select"
                aria-label="Repository"
              >
                <option value="" selected={is_nil(@popover.choice)}>Choose a repository</option>
                <option
                  :for={repository <- @popover.repositories}
                  value={repository.id}
                  selected={@popover.choice == repository.id}
                >
                  {middle(repository.label, 56)} · {count_noun(repository.runs, "run")}
                </option>
              </select>
            </div>
            <label class="q-popt">
              <input type="radio" name="for" value="hive" checked={@popover.level == :hive} />
              <span><b>The whole hive</b></span>
              <small>
                Every repository of {@popover.hive}. {if @deny, do: @popover.consequence[:hive]}
              </small>
              <small :if={@popover[:own_rule]} id={"#{@id}-own-rule"}>
                {if @popover.page == :run,
                  do: "This repository's own rule still decides here.",
                  else: "A repository's own rule for this host still decides there."}
              </small>
            </label>
          </fieldset>

          <p class="q-pop-next">
            <.icon name="hero-arrow-path-micro" class="size-3.5" />
            <span id={"#{@id}-next"}>
              Takes effect in running sessions within a heartbeat, about {@popover.interval} s. {next_sentence(
                @popover
              )}
            </span>
          </p>
        </div>
        <footer>
          <.button id={"#{@id}-cancel"} type="button" phx-click="rule_cancel">Cancel</.button>
          <.button
            id={"#{@id}-submit"}
            type="submit"
            variant={if @deny, do: "danger", else: "primary"}
            disabled={!@ready}
          >
            {if @deny, do: "Deny", else: "Allow"} for {case @popover.level do
              :hive -> "the hive"
              :repository when @popover.page == :run -> "this repository"
              :repository -> "the repository"
              _ -> "…"
            end}
          </.button>
        </footer>
      </form>
    </div>
    """
  end

  # What the domain will do is said for the level chosen, and for no other.
  defp popover_what(%{level: level, what: what}) when is_map(what), do: what[level]
  defp popover_what(_popover), do: nil

  defp popover_ready?(%{level: :hive}), do: true
  defp popover_ready?(%{level: :repository, page: :run}), do: true
  defp popover_ready?(%{level: :repository, choice: choice}) when is_binary(choice), do: true
  defp popover_ready?(_popover), do: false

  defp next_sentence(%{action: :deny}),
    do: "Open connections to the host are closed at the reload."

  defp next_sentence(%{page: :run, alive: true, fetched: true}),
    do: "This run is alive: its next attempt can succeed."

  defp next_sentence(%{page: :run, alive: true}),
    do: "This run uses its machine's policy and does not take this one."

  defp next_sentence(_popover), do: nil

  @doc """
  A version named on a run's pages: the link of pd1 and, since versions count per target
  (the baseline's apart from each repository's), the words that say whose it is.
  `version` is `%{n, path, label}`; a missing label says nothing.
  """
  attr :version, :map, required: true
  attr :class, :any, default: nil
  attr :title, :string, default: nil

  def scoped_version(assigns) do
    ~H"""
    <span class={["q-sver", @class]}>
      <PolicyComponents.version_link
        version={@version.n}
        navigate={@version[:path]}
        title={
          @title ||
            "Version #{@version.n}#{if @version[:label], do: " of the #{@version.label}"}. Open the exact document."
        }
      /><small :if={@version[:label]} class="q-sver-of" title={@version.label}><span aria-hidden="true"> · </span><span class="sr-only"> of </span>{middle(
        @version.label,
        32
      )}</small>
    </span>
    """
  end

  @doc "A version in a sentence: \"the hive baseline's v3\", \"acme/shop's v1\"."
  def version_words(%{n: n, label: label}) when is_binary(label), do: "#{possessive(label)} v#{n}"
  def version_words(%{n: n}), do: "v#{n}"
  def version_words(_version), do: "another configuration"

  defp possessive("hive baseline"), do: "the hive baseline's"
  defp possessive(label), do: middle(label, 40) <> "'s"

  ## pd9. The drift mark

  @doc """
  The mark of a run that is alive and last reported a run configuration other than the one
  in force for its repository: an amber badge, a triangle and words, never a pulse. It is
  a comparison of two digests of the record; no timer decides it.
  """
  attr :id, :string, default: "run-drift"

  attr :reported, :any,
    default: nil,
    doc: "%{n, …} of the version the run last reported, when known"

  attr :in_force, :map, required: true, doc: "%{n, rendered_at, …} of the version in force"
  attr :last_seq, :integer, default: nil
  attr :class, :any, default: nil

  def drift(assigns) do
    ~H"""
    <span
      id={@id}
      class={["q-drift tooltip tooltip-left q-tip-wide", @class]}
      tabindex="0"
      data-tip={drift_tip(@reported, @in_force, @last_seq)}
    >
      <.icon name="hero-exclamation-triangle-micro" class="size-[11px]" />Behind v{@in_force.n}<span
        :if={@in_force[:label]}
        class="q-drift-of"
      > · {middle(@in_force.label, 24)}</span>
    </span>
    """
  end

  defp drift_tip(reported, in_force, last_seq) do
    [
      "The run last reported #{version_words(reported)}" <>
        if(is_integer(last_seq) and last_seq > 0,
          do: " at ##{last_seq |> Integer.to_string() |> String.pad_leading(4, "0")}.",
          else: "."
        ),
      "#{String.capitalize(version_words(in_force))} has been in force since #{clock_label(in_force.rendered_at)}.",
      "A run reloads at its next heartbeat."
    ]
    |> Enum.join(" ")
  end

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
