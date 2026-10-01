defmodule ApiaryWeb.RunComponents do
  @moduledoc """
  The components the runs list, the run page and Network access share: the run
  state badge and the state's mark in a row, durations and times that tick in the
  browser, the key and value strip, label chips, the alive indicator, what a list of runs
  adds to `CoreComponents`' list controls (a Filter menu section's options, the rail of
  targets, the pager; docs/ui.md, Lists), a target's one notation, the runs table and the
  preview beside it, the filter chips the Activity page keeps, tabs, the connection row
  with its reason, the connections tables (the content of Network access, with a row's
  text actions and ⋯ menu) and the new-items pill.

  Everything rendered here is a field of an event or a count of events; what the record
  lacks reads "n/a". Event data is untrusted: it is only ever interpolated, never `raw/1`.

  A connection is the record, and what the policy made of it is not: on an instance
  without `security` the pages pass `security={false}`, and a connection says what the
  runner reported, allowed or denied, the host, the tool and the outcome, with no rule, no
  mode and no rule action. The components do not ask `Apiary.Features` themselves: the
  page asks with its scope and says so.

  Times tick in the browser (`docs/ui.md`): every `<time data-tick=…>` is re-rendered once
  a second by the `Ticker` hook's one interval (`assets/js/hooks/ticker.js`), in the same
  words the server rendered, so the server never re-renders for a clock. The browser's
  clock is never trusted: every ticking element carries the server's now at render
  (`data-now`), the hook learns its offset from the server from it, and counts on the
  server's time.
  """
  use Phoenix.Component
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText

  import ApiaryWeb.CoreComponents,
    only: [
      badge: 1,
      button: 1,
      icon: 1,
      menu_divider: 1,
      menu_heading: 1,
      menu_item: 1,
      mono: 1,
      notice: 1,
      row_menu: 1,
      term: 1
    ]

  alias ApiaryWeb.Format
  # Called by its full name below: `PolicyComponents` imports this module.
  alias ApiaryWeb.PolicyComponents

  alias Apiary.Runs
  alias Phoenix.LiveView.JS

  @outcome_tip gettext_noop(
                 "What became of the connection. Connected: the dial succeeded, with the status the host answered when the proxy read the request. Answered: the tool the request was handed to answered with that status. Handed over: the tool took the request, and no answer is recorded. Dial failed: allowed, but the host or the tool did not answer. Refused: never dialled."
               )
  @at_least_tip gettext_noop(
                  "Elapsed at the last heartbeat. The clock stops counting when heartbeats stop."
                )

  # Where an element sits in a translated sentence: the binding's value, which `spliced/1`
  # cuts the sentence at. It never reaches the page.
  @hole "\u0000"

  ## Run state

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
        <.icon name="hero-exclamation-triangle-micro" class="size-3" />
        <.spliced text={gettext("No heartbeat for %{duration}", duration: hole())}>
          <time
            :if={@quiet_since}
            data-tick="seconds"
            data-since={iso(@quiet_since)}
            data-now={iso(DateTime.utc_now())}
            aria-live="off"
            class="tabular-nums"
          >{format_seconds(@quiet_for)}</time>
          <span :if={!@quiet_since} class="tabular-nums">{format_seconds(@quiet_for)}</span>
        </.spliced>
        <span class="sr-only">. {quiet_tip(@interval)}</span>
      </span>
    </span>
    """
  end

  @doc "The word of a state, as the badge says it."
  def state_label("pending"), do: gettext("Pending")
  def state_label("running"), do: gettext("Running")
  def state_label("succeeded"), do: gettext("Succeeded")
  def state_label("failed"), do: gettext("Failed")
  def state_label("timed_out"), do: gettext("Timed out")
  def state_label("lost"), do: gettext("Lost")
  def state_label("closed"), do: gettext("Closed")

  # A translated sentence with one element in it. `text` is the sentence, translated with the
  # element's binding set to `hole/0`; the slot is rendered where the binding stood.
  attr :text, :string, required: true
  slot :inner_block, required: true

  defp spliced(assigns) do
    {before, rest} =
      case String.split(assigns.text, @hole, parts: 2) do
        [before, rest] -> {before, rest}
        [before] -> {before, ""}
      end

    assigns = assign(assigns, before: before, rest: rest)

    ~H"{@before}{render_slot(@inner_block)}{@rest}"
  end

  defp hole, do: @hole

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
       do: gettext("exit %{code}", code: code)

  defp exit_word(_assigns), do: nil

  defp quiet_tip(interval) when is_integer(interval) do
    gettext(
      "Heartbeats are due every %{interval}. After %{silence} of silence the run is marked lost.",
      interval: format_seconds(interval),
      silence: format_seconds(interval * 3)
    )
  end

  defp quiet_tip(_interval),
    do: gettext("Heartbeats have stopped. After three missed intervals the run is marked lost.")

  defp closed_tip(%DateTime{} = at),
    do:
      gettext("Closed by a member on %{date}. The run never posted its exit.",
        date: Format.date(at)
      )

  defp closed_tip(_at), do: gettext("Closed by a member. The run never posted its exit.")

  # What `Apiary.Runs.Liveness` holds a run to when it announced no interval, and its bounds.
  @default_beat 30
  @max_beat 3600

  @doc """
  The seconds a running run has been quiet for, or nil: set once the workspace has heard
  no heartbeat for more than one interval. The server decides this, never the browser, and
  by the rule of `Apiary.Runs.Liveness`: silence is measured on the server's clock from
  when the last heartbeat was received, or, for a run that has not beaten yet, from when
  the workspace first heard of it; a run that announced no valid interval is held to 30
  seconds.
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
  before the first heartbeat, zero at the moment the workspace first heard of the run.
  Never the runner's `started_at`: its clock may be anywhere.
  """
  def elapsed(%{last_heartbeat_at: %DateTime{} = at, elapsed_seconds: seconds})
      when is_integer(seconds),
      do: {seconds, at}

  def elapsed(%{inserted_at: %DateTime{} = at}), do: {0, at}
  def elapsed(_run), do: {nil, nil}

  ## Duration

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
      <small :if={@so_far} class="text-xs text-faint">{gettext("so far")}</small>
    </span>
    """
  end

  def duration(%{at_least_seconds: seconds} = assigns) when is_integer(seconds) do
    assigns = assign(assigns, :tip, Gettext.gettext(ApiaryWeb.Gettext, @at_least_tip))

    ~H"""
    <span
      id={@id}
      class={["tooltip tooltip-left q-tip-wide tabular-nums", @class]}
      tabindex="0"
      data-tip={@tip}
    >
      {gettext("at least %{duration}", duration: format_seconds(@at_least_seconds))}<span class="sr-only">. {@tip}</span>
    </span>
    """
  end

  def duration(assigns) do
    ~H"""
    <span id={@id} class={["text-faint", @class]}>{gettext("n/a")}</span>
    """
  end

  @doc "\"41 ms\", \"48 s\" (or \"3.4 s\" when precise), \"6 m 51 s\", \"1 h 00 m\"."
  def format_duration_ms(ms, precise \\ false)
  def format_duration_ms(ms, _precise) when ms < 1000, do: gettext("%{ms} ms", ms: ms)

  def format_duration_ms(ms, true) when ms < 60_000,
    do: gettext("%{seconds} s", seconds: Format.number(ms / 1000, digits: 1))

  def format_duration_ms(ms, _precise), do: format_seconds(div(ms, 1000))

  @doc "\"48 s\", \"6 m 51 s\", \"1 h 00 m\"."
  def format_seconds(seconds) when seconds < 60,
    do: gettext("%{seconds} s", seconds: max(seconds, 0))

  def format_seconds(seconds) when seconds < 3600,
    do:
      gettext("%{minutes} m %{seconds} s",
        minutes: div(seconds, 60),
        seconds: pad(rem(seconds, 60))
      )

  def format_seconds(seconds),
    do:
      gettext("%{hours} h %{minutes} m",
        hours: div(seconds, 3600),
        minutes: pad(div(rem(seconds, 3600), 60))
      )

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  ## Relative time and the offset

  @doc """
  A time across runs: relative up to yesterday ("2 minutes ago", "Yesterday, 16:40"), then
  "17 Sept, 09:30" (`ApiaryWeb.Format.relative/2`). `clock` gives "Today, 14:02:11"
  (`ApiaryWeb.Format.clock/2`). The full time with its zone is the `title`.
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
      title={Format.datetime(@at, seconds: true, zone: true)}
      aria-live="off"
      class={["tabular-nums", @class]}
    >{if @format == "clock", do: Format.clock(@at), else: Format.relative(@at)}</time>
    """
  end

  def relative_time(assigns) do
    ~H"""
    <span id={@id} class={["text-faint", @class]}>{gettext("n/a")}</span>
    """
  end

  @doc """
  The words the browser's clocks tick in (`assets/js/hooks/ticker.js`), in the reader's
  language, so the script holds none: every "N seconds ago" up to a minute, every "N
  minutes ago" up to an hour and every "N hours ago" up to a day of 25 hours, as
  `ApiaryWeb.Format.ago/2` writes them; the templates of `format_seconds/1` and of the
  days. The dates and times themselves the script formats with `Intl.DateTimeFormat`, in
  the locale and the time zone of `ApiaryWeb.Format`, which the root layout puts on the
  body beside these.
  """
  def clock_words do
    %{
      justNow: gettext("Just now"),
      secondsAgo: for(n <- 0..59, do: Format.ago(n, :second)),
      minutesAgo: for(n <- 0..59, do: Format.ago(n, :minute)),
      # Up to 24: the day summer time ends has 25 hours.
      hoursAgo: for(n <- 0..24, do: Format.ago(n, :hour)),
      today: gettext("Today, %{time}", time: "%{time}"),
      yesterday: gettext("Yesterday, %{time}", time: "%{time}"),
      seconds: gettext("%{seconds} s", seconds: "%{seconds}"),
      minutesSeconds:
        gettext("%{minutes} m %{seconds} s", minutes: "%{minutes}", seconds: "%{seconds}"),
      hoursMinutes: gettext("%{hours} h %{minutes} m", hours: "%{hours}", minutes: "%{minutes}")
    }
  end

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
      title={Format.datetime(@at, milliseconds: true, zone: true)}
    >{format_offset(@at, @from)}</span>
    """
  end

  @doc false
  def format_offset(%DateTime{} = at, %DateTime{} = from) do
    ms = DateTime.diff(at, from, :millisecond)

    cond do
      ms < 0 ->
        gettext("before start")

      ms >= 3_600_000 ->
        s = div(ms, 1000)
        "+#{div(s, 3600)}:#{pad(div(rem(s, 3600), 60))}:#{pad(rem(s, 60))}"

      true ->
        tenths = div(ms, 100)
        "+#{div(tenths, 600)}:#{pad(div(rem(tenths, 600), 10))}.#{rem(tenths, 10)}"
    end
  end

  def format_offset(_at, _from), do: gettext("n/a")

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil

  ## Key and value strip

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

  ## Label chip

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

  @doc """
  A run's labels in the record's order: first the labels that name a target in the
  workspace's domain (`Apiary.Lingo.Domain.target_labels/1`), then the task, then the rest
  by name.
  """
  def ordered_labels(%{} = labels, workspace) do
    keys = Apiary.Lingo.Domain.target_labels(workspace) ++ ["task"]
    first = for key <- keys, value = labels[key], do: {key, value}
    first ++ (labels |> Map.drop(keys) |> Enum.sort())
  end

  def ordered_labels(_labels, _workspace), do: []

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
  def short_id(_run_id), do: gettext("n/a")

  ## Alive indicator

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
            <.spliced text={gettext("No heartbeat for %{duration}", duration: hole())}>
              <.seconds_since at={@since} />
            </.spliced><span class="sr-only">. {quiet_tip(@interval)}</span>
          </span>
        <% @state == "running" and @since -> %>
          <span class="q-dot q-ripple" aria-hidden="true"></span>
          <span class="q-alive-on">
            <.spliced text={
              if is_nil(@last_heartbeat_at),
                do: gettext("Alive, last event %{duration} ago", duration: hole()),
                else: gettext("Alive, %{duration} ago", duration: hole())
            }>
              <.seconds_since at={@since} />
            </.spliced>
          </span>
          <span class="q-alive-off">{gettext("Reconnecting")}</span>
        <% @state == "running" -> %>
          <span>{gettext("Alive")}</span>
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

  defp ended_sentence("pending", _run), do: gettext("Ping only")

  defp ended_sentence("succeeded", %{duration_ms: ms}) when is_integer(ms),
    do: gettext("Succeeded %{duration} after it started", duration: format_duration_ms(ms))

  defp ended_sentence("succeeded", _run), do: gettext("Succeeded")

  defp ended_sentence("failed", %{signal: signal}) when is_binary(signal) and signal != "",
    do: gettext("Failed with %{signal}", signal: signal)

  defp ended_sentence("failed", %{exit_code: code}) when is_integer(code) and code != -1,
    do: gettext("Failed with exit %{code}", code: code)

  defp ended_sentence("failed", _run), do: gettext("Failed")

  defp ended_sentence("timed_out", %{duration_ms: ms}) when is_integer(ms),
    do: gettext("Timed out after %{duration}", duration: format_duration_ms(ms))

  defp ended_sentence("timed_out", _run), do: gettext("Timed out")

  defp ended_sentence("lost", %{} = run) do
    case Map.get(run, :last_heartbeat_at) || Map.get(run, :last_event_at) do
      %DateTime{} = at ->
        gettext("Lost. Last heard %{time}", time: Format.datetime(at))

      _ ->
        gettext("Lost")
    end
  end

  defp ended_sentence("lost", _run), do: gettext("Lost")

  defp ended_sentence("closed", %{closed_at: %DateTime{} = at}),
    do: gettext("Closed %{date}", date: Format.date(at))

  defp ended_sentence("closed", _run), do: gettext("Closed")

  ## Filter bar

  @doc """
  The row of filter chips. Every chip is a query parameter; the LiveView patches the URL.
  """
  attr :id, :string, required: true
  attr :clear, :string, default: nil, doc: "patch target with no filters; shows Clear"
  attr :label, :string, default: nil, doc: "the group's accessible name; nil says Filters"
  slot :inner_block, required: true
  slot :trailing, doc: "the group-by control, the summary"

  def filter_bar(assigns) do
    ~H"""
    <div id={@id} class="q-filters" role="group" aria-label={@label || gettext("Filters")}>
      {render_slot(@inner_block)}
      <.link :if={@clear} id={"#{@id}-clear"} patch={@clear} class="q-filters-clear">
        {gettext("Clear")}
      </.link>
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

  attr :groups, :list,
    default: [],
    doc: """
    with `multiple`, the options under headings: `[%{key:, label:, name:, states: [values]}]`
    in the order shown. Each heading is a checkbox named `family_<key>` (value `1`), named
    `name` for a screen reader and reading `label`, checked when every one of its values is
    chosen and mixed when some are; its values follow it, indented, each looked up in
    `options`, which therefore holds one for every value of every group
    """

  attr :tips, :map,
    default: %{},
    doc: "value => a sentence shown on hover and focus of the option's word (grouped only)"

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
            if @set?,
              do: gettext("%{filter}: %{value}, change", filter: @label, value: @shown),
              else: gettext("Filter by %{filter}", filter: String.downcase(@label))
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
          aria-label={
            gettext("Remove filter: %{filter} %{value}",
              filter: String.downcase(@label),
              value: @shown
            )
          }
        >
          <.icon name="hero-x-mark-micro" class="size-3" />
        </.link>
      </span>
      <div
        id={"#{@id}-panel"}
        role="dialog"
        aria-label={gettext("Filter by %{filter}", filter: String.downcase(@label))}
        class="dropdown-content q-filter-menu left-0 top-full mt-1.5"
      >
        <.filter_options
          id={@id}
          name={@name}
          label={@label}
          values={@values}
          options={@options}
          multiple={@multiple}
          event={@event}
          dates={@dates}
          total={@total}
          query={@query}
          narrow={@narrow}
          groups={@groups}
          tips={@tips}
        />
      </div>
    </div>
    """
  end

  @doc """
  What a filter offers, inside the chip's dialog or a section of the Filter menu: a box that
  narrows the options on the server once there are more than eight (`narrow` is its
  event), the options as a form of checkboxes or radios (and dates), which sends `event`
  on a change with the filter's name in `_filter`, and "Show more" (`more`, its event,
  with the name as `name`) while the values outnumber the options. The ids start with
  `id`: `<id>-form`, `<id>-narrow`, `<id>-search`, `<id>-more`.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :values, :list, required: true, doc: "the chosen values, as strings"
  attr :options, :list, required: true
  attr :multiple, :boolean, default: false
  attr :event, :string, default: "filter"
  attr :dates, :map, default: nil
  attr :total, :integer, default: nil
  attr :query, :string, default: nil
  attr :narrow, :string, default: "narrow"
  attr :more, :string, default: nil, doc: "the event that asks for more options"
  attr :groups, :list, default: []
  attr :tips, :map, default: %{}

  attr :search_label, :string,
    default: nil,
    doc: "the narrowing box's name; nil says Find a <label>"

  def filter_options(assigns) do
    assigns =
      assigns
      |> assign(:grouped?, assigns.multiple and assigns.groups != [])
      |> assign(
        :search_label,
        assigns.search_label ||
          gettext("Find a %{filter}", filter: String.downcase(assigns.label))
      )

    ~H"""
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
        placeholder={@search_label}
        aria-label={@search_label}
        phx-debounce="250"
        autocomplete="off"
      />
    </form>
    <p
      :if={@total && @total > length(@options)}
      id={"#{@id}-more"}
      class="px-2 pb-1 text-xs text-faint"
    >
      {gettext("Showing %{shown} of %{total}: type to narrow",
        shown: Format.number(length(@options)),
        total: Format.number(@total)
      )}
    </p>
    <form
      id={"#{@id}-form"}
      phx-change={@event}
      phx-submit={@event}
      phx-hook={@grouped? && "FamilyBoxes"}
    >
      <input type="hidden" name="_filter" value={@name} />
      <ul :if={!@grouped?} class="q-filter-options" aria-label={@label}>
        <li :if={@options == []} class="px-2 py-1.5 text-xs text-faint">
          {if @query in [nil, ""],
            do: gettext("Nothing to filter by yet"),
            else: gettext("Nothing matches")}
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
            <span :if={count} class="flex-none font-mono text-[11.5px] text-faint tabular-nums">
              {count_label(count)}
            </span>
          </label>
        </li>
      </ul>
      <%!-- Grouped: a heading per family, itself a checkbox over the family's values. The
          checked and mixed states are rendered here; the FamilyBoxes hook mirrors mixed into
          the `indeterminate` property and ticks the family's boxes before a heading's change
          reaches the server, and Filters.change/2 reads the heading when the script did not. --%>
      <ul :if={@grouped?} class="q-filter-options" aria-label={@label}>
        <li :for={group <- @groups} class="q-filter-group">
          <label class="q-filter-option q-filter-family">
            <input
              type="checkbox"
              name={"family_#{group.key}"}
              value="1"
              checked={family_state(group, @values) == :all}
              aria-checked={family_state(group, @values) == :some && "mixed"}
              aria-label={group.name}
              class="checkbox checkbox-xs"
              data-family={group.key}
            />
            <span class="min-w-0 flex-1 truncate">{group.label}</span>
          </label>
          <ul class="q-filter-states" aria-label={group.label}>
            <li :for={{label, value, count} <- group_options(group, @options)}>
              <label class="q-filter-option">
                <input
                  type="checkbox"
                  name={"#{@name}[]"}
                  value={value}
                  checked={to_string(value) in @values}
                  class="checkbox checkbox-xs"
                  data-family={group.key}
                  aria-describedby={@tips[to_string(value)] && "#{@id}-tip-#{value}"}
                />
                <span :if={!@tips[to_string(value)]} class="min-w-0 flex-1 truncate" title={label}>
                  {label}
                </span>
                <span :if={@tips[to_string(value)]} class="min-w-0 flex-1 truncate">
                  <span
                    class="tooltip q-tip-wide"
                    tabindex="0"
                    data-tip={@tips[to_string(value)]}
                  >{label}</span>
                </span>
                <span :if={count} class="flex-none font-mono text-[11.5px] text-faint tabular-nums">
                  {count_label(count)}
                </span>
              </label>
              <span :if={@tips[to_string(value)]} id={"#{@id}-tip-#{value}"} class="sr-only">
                {@tips[to_string(value)]}
              </span>
            </li>
          </ul>
        </li>
      </ul>
      <div :if={@dates} class="q-filter-dates">
        <label>
          <span>{gettext("From")}</span>
          <input
            type="date"
            name="from"
            value={@dates[:from]}
            class="input input-sm"
            phx-debounce="blur"
          />
        </label>
        <label>
          <span>{gettext("To")}</span>
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
    <button
      :if={@more && @total && @total > length(@options)}
      id={"#{@id}-show-more"}
      type="button"
      class="q-filter-showmore"
      phx-click={@more}
      phx-value-name={@name}
    >
      {gettext("Show more")}
    </button>
    """
  end

  # Whether every, some or none of the group's values is chosen.
  defp family_state(%{states: states}, values) do
    case Enum.count(states, &(to_string(&1) in values)) do
      0 -> :none
      n when n == length(states) -> :all
      _some -> :some
    end
  end

  # The group's values as options, in the group's order; a value without an option is left
  # out, so the caller passes one for every value it wants shown.
  defp group_options(%{states: states}, options) do
    for value <- states,
        option =
          Enum.find(options, fn {_label, v, _count} -> to_string(v) == to_string(value) end),
        do: option
  end

  defp shown_value([one], options), do: option_label(one, options)

  defp shown_value([a, b], options),
    do: "#{option_label(a, options)}, #{option_label(b, options)}"

  defp shown_value(values, _options),
    do:
      ngettext("%{number} selected", "%{number} selected", length(values),
        number: Format.number(length(values))
      )

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
          {count_label(segment[:count])}
        </span>
      </button>
    </div>
    """
  end

  # A count beside a label, grouped as the reader's language groups it.
  defp count_label(n) when is_number(n), do: Format.number(n)
  defp count_label(other), do: other

  ## The controls of a list

  # A list is narrowed one way (docs/ui.md, Lists), with `CoreComponents`' views, search,
  # Filter menu, Sort and tokens. What a list of runs adds is here: the content of a
  # Filter menu's section (`filter_options/1`, `filter_check/1`), the rail of targets
  # beside the list from 1280 px, and the pager.

  @doc """
  A form of one checkbox, for a filter that is on or off (With denials, Tool invocations):
  it sends `event` with `_filter` set to `name`, and the box as `name` when it is ticked.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :event, :string, default: "filter"

  def filter_check(assigns) do
    ~H"""
    <form id={"#{@id}-form"} phx-change={@event} phx-submit={@event}>
      <input type="hidden" name="_filter" value={@name} />
      <label class="q-filter-option">
        <input
          type="checkbox"
          name={@name}
          value="1"
          checked={@checked}
          class="checkbox checkbox-xs"
        />
        <span class="min-w-0 flex-1">{@label}</span>
      </label>
    </form>
    """
  end

  @doc """
  A target as every page writes it: its path in mono, and its system faint before it only
  where the same path is on more than one system of the workspace. Given `shared`
  (`Apiary.Runs.shared_paths/2`) the component decides; without it the caller has, and a
  `system` given is shown. The whole `system/path` is its title.
  """
  attr :path, :string, required: true
  attr :system, :string, default: nil
  attr :shared, :any, default: nil, doc: "the paths on more than one system (a MapSet)"
  attr :class, :any, default: nil
  attr :rest, :global

  def target_name(assigns) do
    %{system: system, path: path, shared: shared} = assigns

    assigns =
      assign(assigns,
        shown: system && (is_nil(shared) or MapSet.member?(shared, path)) && system,
        title: if(system, do: "#{system}/#{path}", else: path)
      )

    ~H"""
    <span class={["q-tname", @class]} title={@title} {@rest}><span :if={@shown} class="q-tname-sys">{@shown}<span class="q-tname-sep">/</span></span>{@path}</span>
    """
  end

  @doc """
  The rail of a list from 1280 px: the targets of what the list holds under every filter
  but the target, with their counts. A search on the server at its top; every run; the
  pinned targets (`rail.pinned`) first; then the targets with the most, `rail.more` more
  behind a button that asks for them; the runs without a target last. Choosing one is a
  link that sets the target (`path`, a function of the target, nil for every one). Below
  1280 px the rail is not shown and the Filter menu's section does its work.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rail, :map, default: nil, doc: "`Apiary.Runs.target_counts/3`; nil while it loads"
  attr :chosen, :any, default: nil, doc: "the target the filters hold"
  attr :shared, :any, default: nil, doc: "the paths on more than one system (a MapSet)"
  attr :path, :any, required: true
  attr :query, :string, default: nil
  attr :search, :string, default: "rail_search"
  attr :more, :string, default: "rail_more"

  def target_rail(assigns) do
    assigns = assign(assigns, :shared, assigns.shared || MapSet.new())

    ~H"""
    <nav id={@id} class="q-rail" aria-label={@label}>
      <%!-- The rail's own headings (Pinned, Most runs) are h3s under this one. --%>
      <h2 class="sr-only">{@label}</h2>
      <form id={"#{@id}-search"} class="q-rail-find" phx-change={@search} phx-submit={@search}>
        <.icon name="hero-magnifying-glass-micro" class="size-4" />
        <input
          id={"#{@id}-q"}
          type="text"
          name="q"
          value={@query}
          placeholder={gettext("Find a target")}
          aria-label={gettext("Find a target")}
          phx-debounce="200"
          autocomplete="off"
          spellcheck="false"
        />
      </form>
      <div :if={!@rail} class="q-rail-list" aria-busy="true">
        <span :for={n <- 1..8} class={["skeleton q-skel q-rail-skel", rem(n, 3) == 0 && "w-2/3"]}></span>
      </div>
      <div :if={@rail} class="q-rail-list">
        <.link
          id={"#{@id}-all"}
          patch={@path.(nil)}
          aria-current={is_nil(@chosen) && "true"}
        >
          <span class="q-rail-name q-rail-plain">{gettext("All targets")}</span>
          <span class="q-rail-n">{Format.number(@rail.all)}</span>
        </.link>
      </div>
      <%= if @rail && @rail.pinned != [] do %>
        <h3 class="q-rail-h">{gettext("Pinned")}</h3>
        <div class="q-rail-list">
          <.rail_target
            :for={target <- @rail.pinned}
            id={@id}
            target={target}
            chosen={@chosen}
            shared={@shared}
            path={@path}
          />
        </div>
      <% end %>
      <%= if @rail do %>
        <h3 :if={@rail.targets != []} class="q-rail-h">
          {if @query in [nil, ""], do: gettext("Most runs"), else: gettext("Matches")}
        </h3>
        <p :if={@rail.targets == [] && @query not in [nil, ""]} class="q-rail-none">
          {gettext("No target matches.")}
        </p>
        <div class="q-rail-list">
          <.rail_target
            :for={target <- @rail.targets}
            id={@id}
            target={target}
            chosen={@chosen}
            shared={@shared}
            path={@path}
          />
          <.link
            :if={@rail.unassigned > 0 && @query in [nil, ""] && @rail.more == 0}
            id={"#{@id}-none"}
            patch={@path.(:none)}
            aria-current={@chosen == :none && "true"}
          >
            <span class="q-rail-name q-rail-plain">{gettext("Unassigned")}</span>
            <span class="q-rail-n">{Format.number(@rail.unassigned)}</span>
          </.link>
        </div>
        <button
          :if={@rail.more > 0}
          id={"#{@id}-more"}
          type="button"
          class="q-rail-more"
          phx-click={@more}
        >
          {ngettext("%{number} more", "%{number} more", @rail.more, number: Format.number(@rail.more))}
        </button>
      <% end %>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :target, :map, required: true
  attr :chosen, :any, required: true
  attr :shared, :any, required: true
  attr :path, :any, required: true

  defp rail_target(assigns) do
    assigns = assign(assigns, :pair, {assigns.target.system, assigns.target.path})

    ~H"""
    <.link
      id={"#{@id}-t-#{dom_token(@pair)}"}
      patch={@path.(@pair)}
      aria-current={@chosen == @pair && "true"}
      title={"#{@target.system}/#{@target.path}"}
    >
      <.target_name
        class="q-rail-name"
        system={@target.system}
        path={@target.path}
        shared={@shared}
      />
      <span class={["q-rail-n", @target.runs == 0 && "q-rail-n0"]}>
        {Format.number(@target.runs)}
      </span>
    </.link>
    """
  end

  @doc """
  The foot of a paged list: where the page is ("1–50 of 3,137"), the way to the page
  before and after (`previous` and `next`, nil at an end, named by the list's order), and
  what else the list offers there (the slot: the page size, Jump to date).
  """
  attr :id, :string, required: true
  attr :first, :integer, required: true
  attr :last, :integer, required: true
  attr :total, :integer, required: true

  attr :previous, :any,
    default: nil,
    doc: "the path of the page before; nil or false at the first"

  attr :next, :any, default: nil, doc: "the path of the page after; nil or false at the last"
  attr :previous_label, :string, required: true
  attr :next_label, :string, required: true
  attr :prefix, :string, required: true, doc: "the start of the buttons' ids"
  slot :inner_block

  def pager(assigns) do
    ~H"""
    <div id={@id} class="q-pager">
      <p id={"#{@prefix}-footer"} class="q-pager-count">
        {gettext("%{first}–%{last} of %{total}",
          first: Format.number(@first),
          last: Format.number(@last),
          total: Format.number(@total)
        )}
      </p>
      {render_slot(@inner_block)}
      <span :if={@previous || @next} class="q-pager-go">
        <.button
          id={"#{@prefix}-previous"}
          size="sm"
          patch={@previous || nil}
          disabled={!@previous}
        >
          <.icon name="hero-arrow-left-micro" class="size-3.5" />{@previous_label}
        </.button>
        <.button id={"#{@prefix}-next"} size="sm" patch={@next || nil} disabled={!@next}>
          {@next_label}<.icon name="hero-arrow-right-micro" class="size-3.5" />
        </.button>
      </span>
    </div>
    """
  end

  ## The runs list

  @doc """
  A run's state as a row of a list says it: a dot, and its word where the state needs a
  look (pending, running, failed, timed out, lost, closed); a run that succeeded is its
  dot, its word for a screen reader only, unless `word` asks for it. `quiet_for` turns a
  running run's dot amber and adds the note, as `run_state/1` does; `code` follows the
  word (the exit, for the preview).
  """
  attr :state, :string, required: true, values: Apiary.Runs.Run.states()
  attr :quiet_for, :integer, default: nil
  attr :quiet_since, :any, default: nil
  attr :interval, :integer, default: nil
  attr :closed_at, :any, default: nil
  attr :word, :boolean, default: false
  attr :code, :string, default: nil
  attr :class, :any, default: nil

  def run_mark(assigns) do
    assigns =
      assign(assigns, :quiet?, assigns.state == "running" and is_integer(assigns.quiet_for))

    ~H"""
    <span class={["q-st", "q-st-#{@state}", @quiet? && "q-st-quiet", @class]}>
      <i aria-hidden="true"></i>
      <span
        :if={@state == "closed"}
        class="q-st-w tooltip q-tip-wide"
        data-tip={closed_tip(@closed_at)}
      >{state_label(@state)}<span class="sr-only">. {closed_tip(@closed_at)}</span></span>
      <span
        :if={@state != "closed"}
        class={["q-st-w", @state == "succeeded" && !@word && "sr-only"]}
      >{state_label(@state)}</span>
      <span :if={@code} class="q-st-code">{@code}</span>
      <span
        :if={@quiet?}
        class="q-quiet tooltip q-tip-wide"
        tabindex="0"
        data-tip={quiet_tip(@interval)}
      >
        <.spliced text={gettext("No heartbeat for %{duration}", duration: hole())}>
          <time
            :if={@quiet_since}
            data-tick="seconds"
            data-since={iso(@quiet_since)}
            data-now={iso(DateTime.utc_now())}
            aria-live="off"
            class="tabular-nums"
          >{format_seconds(@quiet_for)}</time>
          <span :if={!@quiet_since} class="tabular-nums">{format_seconds(@quiet_for)}</span>
        </.spliced>
        <span class="sr-only">. {quiet_tip(@interval)}</span>
      </span>
    </span>
    """
  end

  @doc "A run's exit as the preview says it after the state: \"exit 1\", \"SIGKILL\"; nil otherwise."
  def exit_note(%{state: state, signal: signal})
      when state in ~w(succeeded failed) and is_binary(signal) and signal != "",
      do: signal

  def exit_note(%{state: state, exit_code: code})
      when state in ~w(succeeded failed) and is_integer(code) and code != -1,
      do: gettext("exit %{code}", code: code)

  def exit_note(_run), do: nil

  @doc """
  The runs of a list, one line each: the state as a mark, the run's title (its task, else
  its id) the only strong text, its target after it until the table is 1000 px wide and
  then in a column of its own, the runtime and the host faint from 1300 px, when it
  started, how long it ran from 720 px, and its denials, red when there are any. The
  columns join by the table's own width (a container query), so a table beside a rail or a
  preview reflows as a narrower screen would.

  Every row's id is the run's (`run-<run_id>`); its title is a link to the run's page that
  covers the row. `selected` marks the row a preview beside the list shows
  (`aria-current`). `target={false}` leaves the target out, for a list of one target.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the accessible name of the scroll region"
  attr :runs, :list, required: true

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :quiet_ids, :any, default: nil
  attr :selected, :string, default: nil, doc: "the run_id of the row the preview shows"
  attr :loading, :boolean, default: false
  attr :shared, :any, default: nil, doc: "the paths on more than one system (a MapSet)"
  attr :target, :boolean, default: true
  attr :rest, :global

  def runs_table(assigns) do
    assigns =
      assigns
      |> assign(:shared, assigns.shared || MapSet.new())
      |> assign(:quiet_ids, assigns.quiet_ids || MapSet.new())

    ~H"""
    <div
      id={"#{@id}-region"}
      class="q-rl-wrap"
      tabindex="0"
      role="region"
      aria-label={@label}
      aria-busy={to_string(@loading)}
      {@rest}
    >
      <table id={@id} class="q-rl" role="table">
        <thead role="rowgroup">
          <tr role="row">
            <th scope="col" role="columnheader" class="q-rl-st">{gettext("State")}</th>
            <th scope="col" role="columnheader" class="q-rl-run">{gettext("Run")}</th>
            <th :if={@target} scope="col" role="columnheader" class="q-rl-c3">
              {gettext("Target")}
            </th>
            <th scope="col" role="columnheader" class="q-rl-c4">{gettext("Runtime")}</th>
            <th scope="col" role="columnheader" class="q-rl-c4">{gettext("Host")}</th>
            <th scope="col" role="columnheader">{gettext("Started")}</th>
            <th scope="col" role="columnheader" class="q-rl-c2 q-num">{gettext("Duration")}</th>
            <th scope="col" role="columnheader" class="q-num">{gettext("Denied")}</th>
          </tr>
        </thead>
        <tbody :if={@loading} id={"#{@id}-loading"} role="rowgroup">
          <tr :for={n <- 1..10} role="row" class="q-skel-row" aria-hidden="true">
            <td role="cell"><span class="skeleton q-skel w-3"></span></td>
            <td role="cell">
              <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-56", else: "w-40")]}></span>
            </td>
            <td :if={@target} role="cell" class="q-rl-c3">
              <span class="skeleton q-skel w-32"></span>
            </td>
            <td role="cell" class="q-rl-c4"><span class="skeleton q-skel w-20"></span></td>
            <td role="cell" class="q-rl-c4"><span class="skeleton q-skel w-20"></span></td>
            <td role="cell"><span class="skeleton q-skel w-20"></span></td>
            <td role="cell" class="q-rl-c2"><span class="skeleton q-skel ml-auto w-14"></span></td>
            <td role="cell"><span class="skeleton q-skel ml-auto w-5"></span></td>
          </tr>
        </tbody>
        <tbody :if={!@loading} id={"#{@id}-rows"} role="rowgroup">
          <.run_row
            :for={run <- @runs}
            :key={run.id}
            scope={@scope}
            run={run}
            target={@target}
            shared={@shared}
            quiet={MapSet.member?(@quiet_ids, run.id)}
            selected={@selected == run.run_id}
          />
        </tbody>
      </table>
    </div>
    """
  end

  attr :scope, :map, required: true
  attr :run, :map, required: true
  attr :target, :boolean, required: true
  attr :shared, :any, required: true
  attr :quiet, :boolean, default: false
  attr :selected, :boolean, default: false

  defp run_row(assigns) do
    ~H"""
    <tr
      id={"run-#{@run.run_id}"}
      class="q-rl-row"
      role="row"
      data-run={@run.run_id}
      aria-current={@selected && "true"}
    >
      <td class="q-rl-st" role="cell">
        <.run_mark
          state={@run.state}
          quiet_for={if @quiet, do: quiet_for(@run) || 0}
          quiet_since={heard_at(@run)}
          interval={beat(@run)}
          closed_at={@run.closed_at}
        />
      </td>
      <td class="q-rl-run" role="cell">
        <span class="q-rl-tt">
          <.link
            navigate={run_page(@scope, @run)}
            class={["q-rowlink q-rl-title", !@run.task && "q-rl-id"]}
            title={@run.task}
          >
            {@run.task || short_id(@run.run_id)}
          </.link>
          <.target_name
            :if={@target && @run.target_system && @run.target_path}
            class="q-rl-inl"
            system={@run.target_system}
            path={@run.target_path}
            shared={@shared}
          />
        </span>
      </td>
      <td :if={@target} class="q-rl-c3" role="cell">
        <.target_name
          :if={@run.target_system && @run.target_path}
          system={@run.target_system}
          path={@run.target_path}
          shared={@shared}
        />
        <span :if={!(@run.target_system && @run.target_path)} class="q-rl-faint">
          {gettext("n/a")}
        </span>
      </td>
      <td class="q-rl-c4 q-rl-faint" role="cell">
        <span :if={@run.runtime}>{@run.runtime} {@run.runtime_version}</span>
        <span :if={!@run.runtime}>{gettext("n/a")}</span>
      </td>
      <td class="q-rl-c4 q-rl-faint q-rl-host" role="cell">{@run.host || gettext("n/a")}</td>
      <td class="q-rl-when" role="cell">
        <.relative_time at={@run.started_at || @run.inserted_at} />
      </td>
      <td class="q-rl-c2 q-rl-dur q-num" role="cell">
        <.run_length run={@run} quiet={@quiet} />
      </td>
      <td class="q-rl-den q-num" role="cell">
        <span :if={@run.denied_count > 0} class="q-rl-denied">
          <.icon name="hero-no-symbol-micro" class="size-3" />{Format.number(@run.denied_count)}
          <span class="sr-only">{gettext("denied")}</span>
        </span>
      </td>
    </tr>
    """
  end

  attr :run, :map, required: true
  attr :quiet, :boolean, required: true

  @doc """
  How long a run ran, as its row and its preview say it: the duration its exit gave; for a
  running run the time since it started, ticking; for a quiet, lost or closed one "at
  least" what it last reported; nothing for a run that has only pinged.
  """
  def run_length(%{run: %{state: state}} = assigns)
      when state in ~w(succeeded failed timed_out) do
    ~H"""
    <.duration ms={@run.duration_ms} />
    """
  end

  def run_length(%{run: %{state: "running"}, quiet: false} = assigns) do
    {seconds, at} = elapsed(assigns.run)
    assigns = assign(assigns, seconds: seconds, at: at)

    ~H"""
    <.duration elapsed_seconds={@seconds} elapsed_at={@at} />
    """
  end

  def run_length(%{run: %{state: "pending"}} = assigns) do
    ~H"""
    <.duration />
    """
  end

  def run_length(assigns) do
    ~H"""
    <.duration at_least_seconds={@run.elapsed_seconds} />
    """
  end

  @doc """
  The preview of a run beside the runs list, from 1920 px: one pane with a rule at its
  left and no card, the run's state and its title, a line of what it ran on, when it
  started and for how long, its denials, and the last lines of its log as plain text in the
  terminal's dark box, the one box in it; Open run leads to its page. `preview` is nil while
  it loads.
  """
  attr :id, :string, required: true
  attr :scope, :map, required: true
  attr :preview, :map, default: nil, doc: "%{run:, lines:, denials:, quiet:}"
  attr :shared, :any, default: nil

  def run_preview(assigns) do
    assigns = assign(assigns, :shared, assigns.shared || MapSet.new())

    ~H"""
    <aside id={@id} class="q-pv" aria-label={gettext("Run preview")} aria-busy={to_string(!@preview)}>
      <div :if={!@preview} class="q-pv-skel">
        <span class="skeleton q-skel w-28"></span>
        <span class="skeleton q-skel h-5 w-3/4"></span>
        <span class="skeleton q-skel w-1/2"></span>
        <span class="skeleton q-skel mt-4 h-64 w-full"></span>
      </div>
      <%= if @preview do %>
        <div class="q-pv-h">
          <.run_mark
            state={@preview.run.state}
            word
            code={exit_note(@preview.run)}
            quiet_for={if @preview.quiet, do: quiet_for(@preview.run) || 0}
            quiet_since={heard_at(@preview.run)}
            interval={beat(@preview.run)}
            closed_at={@preview.run.closed_at}
          />
          <span class="flex-1"></span>
          <.button
            id={"#{@id}-open"}
            size="sm"
            navigate={run_page(@scope, @preview.run)}
          >
            {gettext("Open run")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
          </.button>
        </div>
        <h2 class="q-pv-t">{@preview.run.task || short_id(@preview.run.run_id)}</h2>
        <p class="q-pv-m">
          <.target_name
            :if={@preview.run.target_system && @preview.run.target_path}
            system={@preview.run.target_system}
            path={@preview.run.target_path}
            shared={@shared}
          />
          <span :if={@preview.run.runtime}>
            {@preview.run.runtime} {@preview.run.runtime_version}
          </span>
          <span :if={@preview.run.host} class="font-mono text-[12px]">{@preview.run.host}</span>
          <span class="font-mono text-[12px]">{short_id(@preview.run.run_id)}</span>
        </p>
        <dl class="q-pv-kv">
          <dt>{gettext("Started")}</dt>
          <dd>
            <.relative_time
              :if={@preview.run.started_at || @preview.run.inserted_at}
              at={@preview.run.started_at || @preview.run.inserted_at}
            />
          </dd>
          <dt>{gettext("Duration")}</dt>
          <dd class="tabular-nums"><.run_length run={@preview.run} quiet={@preview.quiet} /></dd>
          <dt :if={@preview.run.denied_count > 0}>{gettext("Denied")}</dt>
          <dd :if={@preview.run.denied_count > 0} id={"#{@id}-denials"}>
            <span class="q-rl-denied">
              <.icon name="hero-no-symbol-micro" class="size-3" />{Format.number(
                @preview.run.denied_count
              )}
            </span>
            <span :for={d <- @preview.denials} class="q-pv-dest">{d.host}:{d.port}</span>
            <span :if={@preview.more_denials > 0} class="q-pv-more">
              {ngettext("and %{number} more", "and %{number} more", @preview.more_denials,
                number: Format.number(@preview.more_denials)
              )}
            </span>
          </dd>
          <dt :if={key_label(@preview.run)}>{gettext("Access key")}</dt>
          <dd :if={key_label(@preview.run)} class="font-mono text-[12px]">
            {key_label(@preview.run)}
          </dd>
          <dt :if={@preview.run.cost_usd}>{gettext("Cost")}</dt>
          <dd :if={@preview.run.cost_usd} class="tabular-nums">
            {cost_words(@preview.run.cost_usd)}
          </dd>
        </dl>
        <div class="q-pv-term">
          <div class="q-pv-bar">
            <span class="flex-1">
              {if @preview.run.state in Apiary.Runs.Run.alive_states(),
                do: gettext("Terminal, live"),
                else: gettext("Terminal, last lines")}
            </span>
            <.link navigate={"#{run_page(@scope, @preview.run)}/terminal"}>{gettext("Full log")}</.link>
          </div>
          <pre
            :if={@preview.lines != []}
            id={"#{@id}-log"}
            class="q-pv-log"
            role="log"
            aria-live="off"
            aria-label={gettext("The last lines of the log")}
          >{Enum.join(@preview.lines, "\n")}</pre>
          <p :if={@preview.lines == []} id={"#{@id}-log"} class="q-pv-nolog">
            {if @preview.run.log_pruned_at,
              do: gettext("The log was pruned."),
              else: gettext("No log recorded.")}
          </p>
        </div>
      <% end %>
    </aside>
    """
  end

  defp key_label(%{access_key: %{label: label}}), do: label
  defp key_label(_run), do: nil

  # Reported in dollars, as the overview writes it: a cent's fraction to four places.
  defp cost_words(%Decimal{} = cost) do
    if Decimal.compare(cost, Decimal.new("0.01")) == :lt and Decimal.compare(cost, 0) == :gt,
      do: "$" <> Format.number(cost, digits: 4),
      else: "$" <> Format.number(cost, digits: 2)
  end

  defp run_page(scope, run), do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}"

  ## Tabs

  @doc """
  The tabs of a second-level page. Links, not an ARIA tablist: each tab is a URL, a patch
  within the page's LiveView, or a navigation to another page's (`navigate`).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :tab, required: true do
    attr :id, :string
    attr :patch, :string
    attr :navigate, :string
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
        id={tab[:id]}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        aria-current={tab[:current] == true && "page"}
      >
        <.icon :if={tab[:icon]} name={tab[:icon]} class="size-4" />
        {render_slot(tab)}
        <span :if={tab[:count]} class={["q-tabs-n", tab[:tone] == "error" && "q-tabs-bad"]}>
          {count_label(tab[:count])}
        </span>
      </.link>
    </nav>
    """
  end

  ## Connection row and mark

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

  defp decision_word("denied"), do: gettext("Denied")
  defp decision_word("allowed"), do: gettext("Allowed")
  defp decision_word(_other), do: gettext("Unknown decision")

  @doc """
  The name of a tool as a connection leads with it: the wrench, "Tool" for a screen reader,
  and the name. Every surface that shows a tool invocation (`Apiary.Runs.tool_invocation?/2`)
  names the tool with this; a request refused before it reached the tool never does.
  """
  attr :name, :string, required: true

  def tool_mark(assigns) do
    ~H"""
    <.icon name="hero-wrench-screwdriver-micro" class="q-tool-icon size-3.5" /><span class="sr-only">{gettext(
      "Tool"
    )}</span>
    <b class="q-tool-name">{@name}</b>
    """
  end

  @doc """
  One connection, the same wherever it appears. `inline` is the 32 px row of the timeline,
  `table` a row of a run's Network access, `workspace` a row of the workspace's (and of a
  target's tab), with the disclosure of the runs that reached the destination.

  The `workspace` row is on the row spec (docs/ui.md, Lists): one line, no tint and no
  mark; the destination, its host in mono with the port faint and the path muted, is the
  only strong text; the runs and the attempts are muted numbers; allowed and denied are a
  thin split with their numbers, the denied one red only when there is one; the reason is
  one muted line, whole on hover, and folds under the destination below 600 px of table.
  Columns join as the table widens (`connections_table/1`). A row's acts are
  `rule_action/1` and `rule_menu/1`.

  `connection` is a projection row (`last_decision`, `last_rule`, …) or a map read from one
  egress event (`decision`, `rule`, …); both spellings are read.

  A tool invocation, a connection whose `tool` (or `last_tool`) is named and whose decision
  is allowed (`Apiary.Runs.tool_invocation?/2`), reads as a call to that tool: the tool's
  name first, then the request line, the host after them; the reason says it was handed to
  the tool, and the outcome what the tool answered. A request to a tool's host that a path
  rule refused never reached the tool and reads as any denial, host first, its reason
  saying which tool's host it was for. The rule actions still act on the host and the
  path, which is what a rule decides. `q-dest-tool` marks the destination of a tool
  invocation, and only of one, for the tests and the pages that look for one.
  """
  attr :id, :string, required: true
  attr :connection, :map, required: true
  attr :variant, :string, default: "table", values: ~w(inline table workspace)
  attr :started_at, :any, default: nil, doc: "offsets instead of relative time, inside a run"
  attr :caption, :string, default: nil, doc: "inline: \"while 2 calls were open\""
  attr :open, :any, default: nil, doc: "workspace: nil when closed, else %{runs: [...], total: n}"
  attr :toggle, :string, default: "toggle_destination"
  attr :more, :string, default: "more_destination_runs"

  attr :run_path, :any,
    default: nil,
    doc: "workspace: a function from a run to its Network access tab"

  attr :host_path, :any,
    default: nil,
    doc: "table and workspace: a function from a host to the list narrowed to it, for the menu"

  attr :act, :map,
    default: nil,
    doc: "table and workspace: what the row may ask of the policy, see `rule_action/1`"

  attr :security, :boolean,
    default: true,
    doc: "false: the record alone, without the reason, the rule actions or the slot"

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
      <span class="q-why"><.reason c={@c} variant="inline" security={@security} /><span
        :if={@caption}
        class="text-faint"
      > · {@caption}</span></span>
      <.outcome value={@c.outcome} invocation={@c.invocation} status={@c.status} />
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
    <tr
      id={@id}
      class={["q-row q-cxr", @c.decision == "denied" && "q-denied"]}
      data-decision={@c.decision}
    >
      <td class="q-cx-d">
        <div class="q-dcell"><.decision_mark decision={@c.decision} /><.destination c={@c} /></div>
        <span :if={@security} class="q-cx-fold q-cx-fold-marked">
          <.reason c={@c} variant="table" />
        </span>
      </td>
      <td class="q-num q-from-sm">{Format.number(@c.attempts)}</td>
      <td class={["q-num q-from-md", @c.allowed == 0 && "q-zero"]}>{Format.number(@c.allowed)}</td>
      <td class={["q-num", if(@c.denied == 0, do: "q-zero", else: "q-cx-bad")]}>
        {Format.number(@c.denied)}
      </td>
      <td :if={@security} class="q-why q-from-sm">
        <.reason c={@c} variant="table" />
        <.after_line :if={@act && @act[:after]} id={"#{@id}-after"} line={@act.after} />
      </td>
      <td class="q-from-sm">
        <.outcome value={@c.outcome} invocation={@c.invocation} status={@c.status} />
      </td>
      <td class="q-meta q-cx-nw q-from-md">
        <.seen c={@c} started_at={@started_at} />
      </td>
      <td :if={@security} class="q-cx-acts">
        <.rule_action :if={@act} id={"#{@id}-act"} connection={@c} {rule_action_attrs(@act)} />
        <.rule_menu
          :if={@act}
          id={"#{@id}-menu"}
          act_id={"#{@id}-act"}
          connection={@c}
          act={@act}
          host_path={@host_path}
        />
        {if !@act, do: render_slot(@trailing)}
      </td>
    </tr>
    """
  end

  def connection_row(%{variant: "workspace"} = assigns) do
    c = normalise(assigns.connection)

    assigns =
      assigns
      |> assign(:c, c)
      |> assign(:share, share(c.allowed, c.denied))
      |> assign(:mixed, c.allowed > 0 and c.denied > 0)

    ~H"""
    <tr
      id={@id}
      class={["q-row q-cxr", @c.decision == "denied" && "q-denied"]}
      data-decision={@c.decision}
    >
      <td class="q-cx-ex">
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
          aria-label={gettext("Runs that reached %{destination}", destination: destination_words(@c))}
        >
          <.icon name="hero-chevron-right-micro" class="size-3.5" />
        </button>
      </td>
      <td class="q-cx-d">
        <.destination_title c={@c} />
        <span :if={@security} class="q-cx-fold">
          <.reason c={@c} variant="workspace" />
        </span>
      </td>
      <td class="q-num q-cx-runs">{Format.number(@c.runs)}</td>
      <td class="q-num q-from-lg">{Format.number(@c.attempts)}</td>
      <td class="q-cx-nw">
        <.split allowed={@c.allowed} denied={@c.denied} share={@share} />
      </td>
      <td :if={@security} class="q-why q-from-sm">
        <span :if={@act && @act[:above]} class="q-why-l q-above-why" id={"#{@id}-above"}>
          <span class="q-tile" aria-hidden="true">{String.first(@act.above.name)}</span>
          {@act.above.name} · {if @act.above.action == :deny,
            do: gettext("denied"),
            else: gettext("allowed")}
        </span>
        <span :if={!(@act && @act[:above])} class="q-why-l" title={reason_title(@c, @mixed)}>
          <.reason c={@c} variant="workspace" /><span
            :if={@mixed}
            class="text-faint"
          > · {gettext("last attempt")}</span>
        </span>
        <.after_line :if={@act && @act[:after]} id={"#{@id}-after"} line={@act.after} />
      </td>
      <td class="q-cx-nw q-from-lg">
        <.outcome value={@c.outcome} invocation={@c.invocation} status={@c.status} />
      </td>
      <td class="q-meta q-cx-nw q-cx-seen"><.relative_time at={@c.last_seen_at} /></td>
      <td :if={@security} class="q-cx-acts">
        <.rule_action :if={@act} id={"#{@id}-act"} connection={@c} {rule_action_attrs(@act)} />
        <.rule_menu
          id={"#{@id}-menu"}
          act_id={"#{@id}-act"}
          connection={@c}
          act={@act}
          host_path={@host_path}
        />
        {if !@act, do: render_slot(@trailing)}
      </td>
    </tr>
    <tr :if={@open} id={"#{@id}-runs"} class="q-sub">
      <td colspan={if @security, do: 9, else: 7}>
        <div class="q-sub-in">
          <h3>
            {ngettext(
              "%{number} run reached this destination",
              "%{number} runs reached this destination",
              @open.total,
              number: Format.number(@open.total)
            )}
          </h3>
          <div class="q-hits">
            <.link
              :for={hit <- @open.runs}
              id={"#{@id}-run-#{hit.run.run_id}"}
              navigate={@run_path && @run_path.(hit.run)}
              class="q-hit"
            >
              <.run_mark state={hit.run.state} quiet_for={quiet_for(hit.run)} />
              <span class="truncate">
                <b :if={hit.run.task} class="font-medium">{hit.run.task}</b>
                <span class={["font-mono text-xs text-faint", hit.run.task && "ml-1"]}>
                  {short_id(hit.run.run_id)}
                </span>
              </span>
              <span class="truncate font-mono text-xs text-muted">
                {if hit.run.target_system && hit.run.target_path,
                  do: "#{hit.run.target_system}/#{hit.run.target_path}",
                  else: gettext("Unassigned")}
              </span>
              <span class={["tabular-nums", hit.denied > 0 && "q-bad"]}>
                {if hit.denied > 0,
                  do:
                    ngettext("%{number} denied", "%{number} denied", hit.denied,
                      number: Format.number(hit.denied)
                    ),
                  else:
                    ngettext("%{number} allowed", "%{number} allowed", hit.allowed,
                      number: Format.number(hit.allowed)
                    )}
              </span>
              <.relative_time at={hit.last_seen_at} class="text-[12.5px] text-muted" />
            </.link>
          </div>
          <button
            :if={length(@open.runs) < @open.total}
            type="button"
            id={"#{@id}-more"}
            class="q-link q-hits-more"
            phx-click={@more}
            phx-value-host={@c.host}
            phx-value-port={@c.port}
            phx-value-path={@c.path}
          >
            {ngettext(
              "Show %{number} more",
              "Show %{number} more",
              min(10, @open.total - length(@open.runs)),
              number: Format.number(min(10, @open.total - length(@open.runs)))
            )}
          </button>
        </div>
      </td>
    </tr>
    """
  end

  # Both spellings of a connection, as one map with every key present.
  defp normalise(connection) do
    get = fn keys -> Enum.find_value(keys, &Map.get(connection, &1)) end
    tool = blank(get.([:tool, :last_tool]))
    decision = get.([:decision, :last_decision])

    %{
      host: get.([:host]),
      port: get.([:port]),
      path: get.([:path]) || "",
      method: get.([:method]),
      request_method: get.([:request_method, :last_request_method]),
      decision: decision,
      rule: blank(get.([:rule, :last_rule])),
      path_rule: blank(get.([:path_rule, :last_path_rule])),
      credential: blank(get.([:credential, :last_credential])),
      outcome: get.([:outcome, :last_outcome]),
      mode: get.([:mode, :last_mode]),
      tool: tool,
      invocation: Runs.tool_invocation?(tool, decision),
      status: get.([:status, :last_status]),
      request_id: get.([:request_id]),
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

  attr :allowed, :integer, required: true
  attr :denied, :integer, required: true
  attr :share, :integer, required: true

  # Allowed and denied as a thin split and its two numbers: a zero faint, the denied
  # number red only when there is one. The words are the title and a screen reader's.
  defp split(assigns) do
    assigns =
      assign(
        assigns,
        :words,
        gettext("%{allowed} allowed, %{denied} denied",
          allowed: Format.number(assigns.allowed),
          denied: Format.number(assigns.denied)
        )
      )

    ~H"""
    <span class="q-cx-split" title={@words}>
      <span class="q-split" aria-hidden="true"><i style={"width:#{@share}%"}></i><u style={"width:#{100 - @share}%"}></u></span>
      <span aria-hidden="true"><span class={@allowed == 0 && "q-zero"}>{Format.number(@allowed)}</span><span class="q-cx-sl">/</span><span class={
        if(@denied > 0, do: "q-cx-bad", else: "q-zero")
      }>{Format.number(@denied)}</span></span>
      <span class="sr-only">{@words}</span>
    </span>
    """
  end

  attr :c, :map, required: true

  # The destination as a row's title: the host in mono, the port faint, the path muted and
  # cut in the middle. A tool invocation leads with its tool, as everywhere.
  defp destination_title(%{c: %{invocation: true}} = assigns), do: destination(assigns)

  defp destination_title(assigns) do
    ~H"""
    <span
      class="q-dest q-cx-t"
      title={destination_title_words(@c)}
      data-request-id={@c.request_id}
    >
      <span class="q-cx-h">{@c.host}<span class="q-cx-p">:{@c.port}</span></span>
      <span :if={@c.path != ""} class="q-cx-path">{middle(@c.path, 96)}</span>
    </span>
    """
  end

  defp destination_title_words(%{path: ""} = c), do: "#{c.host}:#{c.port}"
  defp destination_title_words(c), do: "#{c.host}:#{c.port} #{c.path}"

  # The reason as words alone, for the title that shows a cut reason whole: the sentences
  # `reason/1` shows for a row of the workspace, in the same order.
  defp reason_title(c, mixed) do
    parts = %{rule: c.rule || "", path: c.path_rule || ""}

    main =
      case reason_kind(c) do
        :own_address ->
          [gettext("The wall refuses the machine's own address,"), gettext("in either mode.")]

        :ambiguous_path ->
          [
            gettext("The path can be read two ways."),
            gettext("The wall denies it in either mode.")
          ]

        :denied_no_rule ->
          [gettext("No rule matches."), mode_sentence(c.mode, :denies)]

        :denied_no_path_rule ->
          [gettext("Host allowed, no path rule matches."), mode_sentence(c.mode, :denies)]

        :tool_by_rule ->
          [plain_text(handed_sentence(c), parts)]

        :tool_no_rule ->
          [
            gettext("No rule matches."),
            mode_sentence(c.mode, :lets_through),
            plain_text(handed_sentence(c), parts)
          ]

        :allowed_no_rule ->
          [gettext("No rule matches."), mode_sentence(c.mode, :lets_through)]

        kind when kind in [:denied_by_rule, :allowed_by_rule] ->
          [rule_words(c)]

        :unknown ->
          [gettext("n/a")]
      end

    closed =
      c.decision == "allowed" && c.outcome == "refused" &&
        gettext("Closed when a new policy denied the host.")

    tool =
      c.decision == "denied" && c.tool &&
        plain_text(rich_gettext("Refused before reaching the tool %{tool}.", tool: {:b, c.tool}))

    words = [main, closed, tool] |> List.flatten() |> Enum.reject(&(&1 in [nil, false, ""]))
    Enum.join(words, " ") <> if(mixed, do: " · " <> gettext("last attempt"), else: "")
  end

  # "Rule api.example, path /v1/*, credential model-key", as the row shows it.
  defp rule_words(c) do
    [
      gettext("Rule") <> " " <> (c.rule || ""),
      c.path_rule && gettext("path") <> " " <> c.path_rule,
      c.decision == "allowed" && c.credential && gettext("credential") <> " " <> c.credential
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(", ")
  end

  defp destination_words(c) do
    [c.invocation && c.tool, request_line(c), c.host]
    |> Enum.reject(&(&1 in [nil, false, "", "CONNECT", "HTTP"]))
    |> Enum.join(" ")
  end

  # The request line on a terminated host, else the proxy's method.
  defp request_line(%{path: path} = c) when path != "" do
    "#{c.request_method || c.method} #{path}"
  end

  defp request_line(c), do: c.method

  attr :c, :map, required: true

  # A tool invocation is named by its tool: the request line follows, and the host, which
  # may be a name that exists only on the runner's machine, comes last and faint. A
  # request refused before it reached the tool is named by its host, as any denial.
  defp destination(%{c: %{invocation: true}} = assigns) do
    assigns = assign(assigns, :line, request_line(assigns.c))

    ~H"""
    <span
      class="q-dest q-dest-tool"
      title={destination_title(@c, @line)}
      data-request-id={@c.request_id}
    >
      <.tool_mark name={@c.tool} />
      <span :if={@line} class="q-rq text-muted">{middle(@line, 56)}</span>
      <span class="q-on">{@c.host}:{@c.port}</span>
    </span>
    """
  end

  defp destination(assigns) do
    assigns = assign(assigns, :line, request_line(assigns.c))

    ~H"""
    <span class="q-dest" title={destination_title(@c, @line)} data-request-id={@c.request_id}>
      {@c.host}<span class="text-faint">:{@c.port}</span>
      <span :if={@line} class="q-rq text-muted">{middle(@line, 56)}</span>
    </span>
    """
  end

  # The whole destination, for the hover a cut cell needs; one request's id with it, where
  # the row is one request (the timeline's).
  defp destination_title(c, line) do
    whole =
      [c.invocation && c.tool, "#{c.host}:#{c.port}", line]
      |> Enum.reject(&(&1 in [nil, false, ""]))
      |> Enum.join(" ")

    if c.request_id,
      do: gettext("%{destination}, request %{id}", destination: whole, id: c.request_id),
      else: whole
  end

  attr :c, :map, required: true
  attr :variant, :string, required: true
  attr :security, :boolean, default: true

  # Without security only the inline row has a reason, and it is the record's: the
  # decision, and the tool a request was for. Which rule matched, and in which mode, is
  # what the policy made of it.
  defp reason(%{security: false} = assigns) do
    ~H"""
    <b :if={@c.decision == "denied"}>{gettext("Denied.")}</b>
    <.rich :if={@c.decision == "allowed" && @c.invocation} text={handed_sentence(@c, false)} />
    <b :if={@c.decision == "allowed" && !@c.invocation}>{gettext("Allowed.")}</b>
    <span :if={@c.decision == "denied" && @c.tool} class="q-for-tool">
      <.rich text={rich_gettext("Refused before reaching the tool %{tool}.", tool: {:b, @c.tool})} />
    </span>
    """
  end

  # C3: one sentence from the decision, the rule, the path rule and the mode of the last
  # attempt. The strings are rf's.
  defp reason(assigns) do
    assigns = assign(assigns, :kind, reason_kind(assigns.c))

    ~H"""
    <b :if={@variant == "inline" && @c.decision == "denied"}>{gettext("Denied.")}</b>
    <%= case @kind do %>
      <% :own_address -> %>
        <b>{gettext("The wall refuses the machine's own address,")}</b> {gettext("in either mode.")}
      <% :ambiguous_path -> %>
        <b>{gettext("The path can be read two ways.")}</b> {gettext(
          "The wall denies it in either mode."
        )}
      <% :denied_no_rule -> %>
        <b>{gettext("No rule matches.")}</b> {mode_sentence(@c.mode, :denies)}
      <% :denied_no_path_rule -> %>
        <b>{gettext("Host allowed, no path rule matches.")}</b> {mode_sentence(@c.mode, :denies)}
      <% :denied_by_rule -> %>
        {gettext("Rule")}
        <.rule value={@c.rule} /><span :if={@c.path_rule}>, {gettext("path")}
        <.rule value={@c.path_rule} /></span>
      <% :tool_by_rule -> %>
        <.rich text={handed_sentence(@c)}>
          <:part name={:rule}><.rule value={@c.rule} /></:part>
          <:part name={:path}><.rule value={@c.path_rule || ""} /></:part>
        </.rich>
      <% :tool_no_rule -> %>
        <b>{gettext("No rule matches.")}</b> {mode_sentence(@c.mode, :lets_through)}
        <.rich text={handed_sentence(@c)}>
          <:part name={:path}><.rule value={@c.path_rule || ""} /></:part>
        </.rich>
      <% :allowed_no_rule -> %>
        <b>{gettext("No rule matches.")}</b> {mode_sentence(@c.mode, :lets_through)}
      <% :allowed_by_rule -> %>
        <span :if={@variant == "inline"}><b>{gettext("Allowed")}</b> {gettext("by rule")}</span><span :if={
          @variant != "inline"
        }>{gettext("Rule")}</span>
        <.rule value={@c.rule} /><span :if={@c.path_rule}>, {gettext("path")}
        <.rule value={@c.path_rule} /></span><span :if={@c.credential}>, {gettext("credential")}
        <.rule value={@c.credential} /></span>
      <% :unknown -> %>
        <span class="text-faint">{gettext("n/a")}</span>
    <% end %>
    <span :if={@c.decision == "allowed" && @c.outcome == "refused"}>
      {gettext("Closed when a new policy denied the host.")}
    </span>
    <span :if={@c.decision == "denied" && @c.tool} class="q-for-tool">
      <.rich text={rich_gettext("Refused before reaching the tool %{tool}.", tool: {:b, @c.tool})} />
    </span>
    """
  end

  defp reason_kind(%{decision: "denied", rule: "wall:own-address"}), do: :own_address
  defp reason_kind(%{decision: "denied", path_rule: "wall:ambiguous-path"}), do: :ambiguous_path
  defp reason_kind(%{decision: "denied", rule: nil}), do: :denied_no_rule

  # A request inside a terminated tunnel was denied on its path: the row names the path,
  # the host's rule let the connection in, and no path entry matched. A denial without a
  # path is the host's, by a deny entry, and the rule is that entry.
  defp reason_kind(%{decision: "denied", path: path, path_rule: path_rule})
       when is_binary(path) and path != "" and path_rule in [nil, ""],
       do: :denied_no_path_rule

  defp reason_kind(%{decision: "denied"}), do: :denied_by_rule

  # A tool invocation was for the tool: that is what the reason says, and whether it
  # reached the tool (`handed_sentence/1`). A request a path rule refused is no tool
  # invocation and took a denial's reason above; `reason/1` adds whose host it was for.
  defp reason_kind(%{invocation: true, rule: nil}), do: :tool_no_rule
  defp reason_kind(%{invocation: true}), do: :tool_by_rule
  defp reason_kind(%{decision: "allowed", rule: nil}), do: :allowed_no_rule
  defp reason_kind(%{decision: "allowed"}), do: :allowed_by_rule
  defp reason_kind(_c), do: :unknown

  # Handed to the tool, by the host's rule and the path rule when either matched, when the
  # request reached it. One that did not (the tool was not running, or a reload closed
  # the connection) was only for the tool: the outcome says what became of it.
  defp handed_sentence(c, rules? \\ true)
  defp handed_sentence(%{outcome: "connected"} = c, true), do: handed(c)
  defp handed_sentence(c, true), do: meant(c)

  # The same, of the record alone: no rule is named.
  defp handed_sentence(%{outcome: "connected"} = c, false),
    do: rich_gettext("Handed to %{tool}", tool: {:b, c.tool})

  defp handed_sentence(c, false), do: rich_gettext("For %{tool}", tool: {:b, c.tool})

  defp handed(%{rule: nil, path_rule: nil} = c),
    do: rich_gettext("Handed to %{tool}", tool: {:b, c.tool})

  defp handed(%{rule: nil} = c),
    do: rich_gettext("Handed to %{tool}, path %{path}", tool: {:b, c.tool}, path: {:part, :path})

  defp handed(%{path_rule: nil} = c),
    do:
      rich_gettext("Handed to %{tool} by rule %{rule}", tool: {:b, c.tool}, rule: {:part, :rule})

  defp handed(c) do
    rich_gettext("Handed to %{tool} by rule %{rule}, path %{path}",
      tool: {:b, c.tool},
      rule: {:part, :rule},
      path: {:part, :path}
    )
  end

  defp meant(%{rule: nil, path_rule: nil} = c),
    do: rich_gettext("For %{tool}", tool: {:b, c.tool})

  defp meant(%{rule: nil} = c),
    do: rich_gettext("For %{tool}, path %{path}", tool: {:b, c.tool}, path: {:part, :path})

  defp meant(%{path_rule: nil} = c),
    do: rich_gettext("For %{tool} by rule %{rule}", tool: {:b, c.tool}, rule: {:part, :rule})

  defp meant(c) do
    rich_gettext("For %{tool} by rule %{rule}, path %{path}",
      tool: {:b, c.tool},
      rule: {:part, :rule},
      path: {:part, :path}
    )
  end

  # The mode is the event's; an event that names neither mode says only what it knows.
  defp mode_sentence("enforce", :denies), do: gettext("Enforce mode denies it.")
  defp mode_sentence("observe", :lets_through), do: gettext("Observe mode lets it through.")
  defp mode_sentence(_mode, :denies), do: gettext("The policy denies it.")
  defp mode_sentence(_mode, :lets_through), do: gettext("It was let through.")

  attr :value, :string, required: true

  defp rule(assigns) do
    ~H"""
    <.mono class="q-rule" bare>{@value}</.mono>
    """
  end

  attr :value, :string, default: nil
  attr :invocation, :boolean, default: false, doc: "whether the request was a tool invocation"
  attr :status, :integer, default: nil, doc: "what the host or the tool answered"

  # One element whatever the value: the inline row places it in a grid cell of its own.
  defp outcome(assigns) do
    ~H"""
    <span
      :if={@value == "connected" && @invocation}
      class={["q-outcome", answer_tone(@status)]}
      title={@status && gettext("The tool answered %{status}.", status: @status)}
    >
      {if @status,
        do: gettext("Answered %{status}", status: @status),
        else: gettext("Handed over")}
    </span>
    <span :if={@value == "connected" && !@invocation} class={["q-outcome", answer_tone(@status)]}>
      {gettext("Connected")}<span
        :if={@status}
        class="q-status"
        title={gettext("The host answered %{status}.", status: @status)}
      >{@status}</span>
    </span>
    <span :if={@value == "dial_failed"} class="q-outcome q-outcome-dial">
      {gettext("Dial failed")}
    </span>
    <span :if={@value == "refused"} class="q-outcome q-outcome-refused">{gettext("Refused")}</span>
    <span :if={@value not in ~w(connected dial_failed refused)} class="text-xs text-faint">
      {@value || gettext("n/a")}
    </span>
    """
  end

  # An answer that is an error, the host's or the tool's, is told apart at a glance.
  defp answer_tone(status) when is_integer(status) and status >= 400, do: "q-outcome-error"
  defp answer_tone(_status), do: nil

  attr :c, :map, required: true
  attr :started_at, :any, default: nil

  defp seen(%{started_at: %DateTime{}} = assigns) do
    ~H"""
    <.offset at={@c.first_seen_at} from={@started_at} class="!text-[12.5px] !text-muted" />
    <span :if={@c.first_seen_at != @c.last_seen_at}>
      <span class="text-faint">{gettext("to")}</span>
      <.offset at={@c.last_seen_at} from={@started_at} class="!text-[12.5px] !text-muted" />
    </span>
    """
  end

  defp seen(assigns) do
    ~H"""
    <.relative_time at={@c.first_seen_at} />
    <span :if={@c.first_seen_at != @c.last_seen_at}>
      <span class="text-faint">{gettext("to")}</span> <.relative_time at={@c.last_seen_at} />
    </span>
    """
  end

  ## Connections tables

  @doc """
  The table of a run's connections (`variant="table"`, C1) or of the workspace's across
  runs (`variant="workspace"`, C2), the content of a Network access page or tab. `rows`
  are connections as `<.connection_row>` reads them; `row_id` gives each its DOM id
  (`"cx-<id>"` for a projection row, `"dst-<hash>"` for a destination).

  Both are on the row spec, with no tint, and fit their width: columns join as the table's
  own width grows (a container query, as `CoreComponents.table/1`'s `from`), so nothing is
  cut at the right. The workspace's: the reason from 600 px (below it, a line under the
  destination), the last seen from 780, the runs from 840, the attempts and the outcome
  from 1300; the destination and its split never go. A run's: the attempts, the reason and
  the outcome from 600, the allowed and the times from 1000; the destination and the
  denied never go.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the accessible name of the scroll region"
  attr :rows, :list, required: true
  attr :variant, :string, default: "table", values: ~w(table workspace)
  attr :started_at, :any, default: nil
  attr :row_id, :any, default: nil

  attr :open, :map,
    default: %{},
    doc: "workspace: `destination_key/1` of an open destination => %{runs, total}"

  attr :run_path, :any, default: nil

  attr :host_path, :any,
    default: nil,
    doc: "a function from a host to the list narrowed to it, for a row's menu; nil offers none"

  attr :acts, :map,
    default: nil,
    doc:
      "a row's DOM id => what it may ask of the policy (`rule_action/1`); nil leaves the slots empty"

  attr :security, :boolean,
    default: true,
    doc: "false: no Reason column, no column of rule actions, and `acts` is not read"

  attr :class, :any, default: nil

  def connections_table(assigns) do
    assigns =
      assigns
      |> assign(:row_id, assigns.row_id || (&default_row_id/1))
      |> assign(:outcome_tip, Gettext.gettext(ApiaryWeb.Gettext, @outcome_tip))

    ~H"""
    <div
      class={["q-tbl overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs", @class]}
      tabindex="0"
      role="region"
      aria-label={@label}
    >
      <table class={["table q-cxt", if(@variant == "workspace", do: "q-cxt-ws", else: "q-cxt-run")]}>
        <thead>
          <tr :if={@variant == "table"}>
            <th scope="col">{gettext("Destination")}</th>
            <th scope="col" class="q-num q-from-sm">{gettext("Attempts")}</th>
            <th scope="col" class="q-num q-from-md">{gettext("Allowed")}</th>
            <th scope="col" class="q-num">{gettext("Denied")}</th>
            <th :if={@security} scope="col" class="q-from-sm">{gettext("Reason")}</th>
            <th scope="col" class="q-from-sm">
              <.term
                word={gettext("Outcome")}
                standard={@outcome_tip}
                class="q-tip-wide tooltip-bottom"
              />
            </th>
            <th scope="col" class="q-from-md">{gettext("First and last seen")}</th>
            <th :if={@security} scope="col" class="q-cx-acts">
              <span class="sr-only">{gettext("Rule actions")}</span>
            </th>
          </tr>
          <tr :if={@variant == "workspace"}>
            <th scope="col" class="q-cx-ex"><span class="sr-only">{gettext("Open")}</span></th>
            <th scope="col">{gettext("Destination")}</th>
            <th scope="col" class="q-num q-cx-runs">{gettext("Runs")}</th>
            <th scope="col" class="q-num q-from-lg">{gettext("Attempts")}</th>
            <th scope="col">{gettext("Allowed / denied")}</th>
            <th :if={@security} scope="col" class="q-from-sm">{gettext("Reason")}</th>
            <th scope="col" class="q-from-lg">
              <.term
                word={gettext("Outcome")}
                standard={@outcome_tip}
                class="q-tip-wide tooltip-bottom"
              />
            </th>
            <th scope="col" class="q-cx-seen">{gettext("Last seen")}</th>
            <th :if={@security} scope="col" class="q-cx-acts">
              <span class="sr-only">{gettext("Rule actions")}</span>
            </th>
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
            host_path={@host_path}
            act={@security && @acts && @acts[@row_id.(row)]}
            security={@security}
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

  ## What a connection's row may ask of the policy (brief-policy.md)

  defp rule_action_attrs(act) do
    %{
      rule_option: act.rule_option,
      values: act[:values] || %{},
      rule_path: act[:rule_path],
      entry_host: act[:entry_host],
      expanded: act[:expanded] == true,
      expanded_action: act[:expanded_action],
      deny: act[:deny] == true,
      above: act[:above],
      allow_elsewhere: act[:allow_elsewhere],
      allow_path: act[:allow_path]
    }
  end

  @doc """
  A row's text action: what its rule option lets the reader ask of the policy, shown on
  hover, on focus inside the row and while its popover or menu is open, never a bordered
  button on every row (docs/ui.md, Lists). `:can_allow` is Allow and `:can_deny` Deny, each
  opening the popover; a `:can_allow` row with `deny`, which no rule decides yet, holds
  Deny before Allow. A locked rule of the workspace (`:locked_deny`, `:locked_allow`) is a
  faint lock, always shown, that opens the refusal; the wall's refusals (`:wall`) are a
  faint lock that says no rule changes this; a host no rule can name (`:unnameable`) says
  so to a screen reader alone; a rule that answers the row (`{:rule_added, _}`) links to
  it. The rest of a row's acts are its menu (`rule_menu/1`). `data-action` names what a
  text action asks.

  `values` ride on the `rule_open` event; they name the row and are looked up among the
  rows the page holds, never trusted.
  """
  attr :id, :string, required: true
  attr :connection, :map, required: true
  attr :rule_option, :any, required: true
  attr :values, :map, default: %{}
  attr :rule_path, :string, default: nil
  attr :entry_host, :string, default: nil, doc: "the host of the locked rule, for the tooltip"
  attr :expanded, :boolean, default: false
  attr :expanded_action, :atom, default: nil, doc: "which of two actions the open popover is of"
  attr :deny, :boolean, default: false, doc: "a `:can_allow` row no rule decides: Deny too"

  attr :above, :any,
    default: nil,
    doc: "`%{name:, action:}` where a rule of the level above the workspace decides the row"

  attr :allow_elsewhere, :any,
    default: nil,
    doc: "`%{name:}` where only the level above the workspace allows a host"

  attr :allow_path, :string,
    default: nil,
    doc: "the level above's page with the host, to allow it there"

  # Where the level above the workspace allows only its own hosts, Allow is a link to its
  # page, with the host, for a reader who may change it there, and a lock for the rest;
  # Deny stays where no rule decides the host.
  def rule_action(%{rule_option: :can_allow, allow_elsewhere: %{}} = assigns) do
    assigns =
      assign(assigns,
        tip:
          gettext("Only %{name}'s policy allows a host here", name: assigns.allow_elsewhere.name)
      )

    ~H"""
    <span id={"#{@id}-both"} class="q-acts-pair">
      <button
        :if={@deny}
        type="button"
        id={"#{@id}-deny"}
        class="q-act-t q-hov"
        data-action="deny"
        phx-click={JS.push("rule_open", value: Map.put(@values, "action", "deny"))}
        aria-haspopup="dialog"
        aria-expanded={to_string(@expanded and @expanded_action == :deny)}
        aria-label={gettext("Deny %{host}", host: @connection.host)}
      >
        {gettext("Deny")}
      </button>
      <.link
        :if={@allow_path}
        id={@id}
        navigate={@allow_path}
        class="q-act-t q-hov"
        aria-label={
          gettext("Allow %{host} in %{name}'s policy",
            host: @connection.host,
            name: @allow_elsewhere.name
          )
        }
      >
        {gettext("Allow")}
      </.link>
      <span :if={!@allow_path} id={@id} class="q-act-lock" title={@tip}>
        <.icon name="hero-lock-closed-micro" class="size-3.5" /><span class="sr-only">{@tip}</span>
      </span>
    </span>
    """
  end

  def rule_action(%{rule_option: :can_allow, deny: true} = assigns) do
    ~H"""
    <span id={"#{@id}-both"} class="q-acts-pair">
      <button
        type="button"
        id={"#{@id}-deny"}
        class="q-act-t q-hov"
        data-action="deny"
        phx-click={JS.push("rule_open", value: Map.put(@values, "action", "deny"))}
        aria-haspopup="dialog"
        aria-expanded={to_string(@expanded and @expanded_action == :deny)}
        aria-label={gettext("Deny %{host}", host: @connection.host)}
      >
        {gettext("Deny")}
      </button>
      <button
        type="button"
        id={@id}
        class="q-act-t q-hov"
        data-action="allow"
        phx-click={JS.push("rule_open", value: Map.put(@values, "action", "allow"))}
        aria-haspopup="dialog"
        aria-expanded={to_string(@expanded and @expanded_action != :deny)}
        aria-label={gettext("Allow %{host}", host: @connection.host)}
      >
        {gettext("Allow")}
      </button>
    </span>
    """
  end

  def rule_action(%{rule_option: rule_option} = assigns)
      when rule_option in [:can_allow, :can_deny] do
    assigns = assign(assigns, :action, if(rule_option == :can_allow, do: "allow", else: "deny"))

    ~H"""
    <button
      type="button"
      id={@id}
      class="q-act-t q-hov"
      data-action={@action}
      phx-click={JS.push("rule_open", value: Map.put(@values, "action", @action))}
      aria-haspopup="dialog"
      aria-expanded={to_string(@expanded)}
      aria-label={
        if @action == "deny",
          do: gettext("Deny %{host}", host: @connection.host),
          else: gettext("Allow %{host}", host: @connection.host)
      }
    >
      {if @action == "deny", do: gettext("Deny"), else: gettext("Allow")}
    </button>
    """
  end

  def rule_action(%{rule_option: rule_option} = assigns)
      when rule_option in [:locked_deny, :locked_allow] do
    assigns =
      assign(
        assigns,
        :tip,
        locked_tip(rule_option, assigns.entry_host || assigns.connection.host)
      )

    ~H"""
    <button
      type="button"
      id={@id}
      class="q-act-lock tooltip tooltip-left"
      data-tip={@tip}
      phx-click={
        JS.push("rule_open",
          value:
            Map.put(@values, "action", if(@rule_option == :locked_deny, do: "allow", else: "deny"))
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

  def rule_action(%{rule_option: {:rule_added, _action}} = assigns) do
    ~H"""
    <.link
      :if={@rule_path}
      id={@id}
      navigate={@rule_path}
      class="q-act-t q-hov"
      aria-label={gettext("The rule for %{host}", host: @connection.host)}
    >
      {gettext("Rule")}
    </.link>
    """
  end

  def rule_action(%{rule_option: :above_deny} = assigns) do
    assigns =
      assign(
        assigns,
        :tip,
        gettext("Decided by %{name}'s policy", name: (assigns.above && assigns.above.name) || "?")
      )

    ~H"""
    <span id={@id} class="q-act-lock" title={@tip}>
      <.icon name="hero-lock-closed-micro" class="size-3.5" /><span class="sr-only">{@tip}</span>
    </span>
    """
  end

  def rule_action(%{rule_option: :wall} = assigns) do
    ~H"""
    <span id={@id} class="q-act-lock" title={gettext("No rule changes this")}>
      <.icon name="hero-lock-closed-micro" class="size-3.5" /><span class="sr-only">{gettext(
        "No rule changes this"
      )}</span>
    </span>
    """
  end

  def rule_action(assigns) do
    ~H|<span id={@id} class="sr-only">{gettext("No rule can name this host")}</span>|
  end

  defp locked_tip(:locked_deny, host),
    do: gettext("A locked workspace rule denies %{host}", host: host)

  defp locked_tip(_locked_allow, host),
    do: gettext("A locked workspace rule allows %{host}", host: host)

  @doc """
  A row's ⋯ menu (`CoreComponents.row_menu/1`), beside its text action and shown with it:
  Allow… and Deny… where the row may ask for them, opening the same popover, anchored at
  the text action (`act_id`), and the rule in force that decides the row, where one does;
  where no one here changes what happened, why (the locked rule and who locked it, when the
  newest history says so, or the wall) with the way to the rule; the rule that answers the
  row; then Only this host, where the list can be narrowed to it (`host_path`), and Copy
  the host. A rule's link (`rule_path`) leads to the rule in its policy's Network access
  section.
  """
  attr :id, :string, required: true
  attr :act_id, :string, required: true, doc: "the row's text action, the popover's anchor"
  attr :connection, :map, required: true, doc: "the row's connection, as the row reads it"
  attr :act, :map, default: nil, doc: "the row's act, as `rule_action/1` reads it; nil for none"
  attr :host_path, :any, default: nil

  def rule_menu(assigns) do
    act = assigns.act || %{}
    option = act[:rule_option]

    assigns =
      assign(assigns,
        kind: menu_kind(option),
        option: option,
        values: act[:values] || %{},
        rule_path: act[:rule_path],
        locked: act[:locked],
        both: option == :can_allow and act[:deny] == true,
        entry_host: act[:entry_host] || assigns.connection.host,
        above: act[:above],
        above_linked: act[:above_linked] == true,
        above_can_change: act[:above_can_change] == true,
        allow_elsewhere: act[:allow_elsewhere],
        allow_path: act[:allow_path]
      )

    ~H"""
    <.row_menu
      id={@id}
      class="q-hov"
      label={gettext("Actions for %{label}", label: @connection.host)}
    >
      <%= case @kind do %>
        <% :above -> %>
          <.menu_heading
            title={gettext("%{name}'s policy denies %{host}", name: @above.name, host: @entry_host)}
            sub={gettext("No workspace or target rule can allow it.")}
          />
          <.menu_item :if={@rule_path} id={"#{@id}-rule"} navigate={@rule_path}>
            {cond do
              @above_can_change -> gettext("Change in %{name}'s policy", name: @above.name)
              @above_linked -> gettext("View in %{name}'s policy", name: @above.name)
              true -> gettext("Show the rule")
            end}
          </.menu_item>
          <.menu_divider />
        <% :locked -> %>
          <.menu_heading title={locked_words(@locked)} sub={locked_holds(@option)} />
          <.menu_item :if={@rule_path} id={"#{@id}-rule"} navigate={@rule_path}>
            {gettext("Show the locked rule")}
          </.menu_item>
          <.menu_divider />
        <% :wall -> %>
          <.menu_heading
            title={gettext("No rule changes this")}
            sub={reason_title(@connection, false)}
          />
          <.menu_divider />
        <% :unnameable -> %>
          <.menu_heading title={gettext("No rule can name this host")} />
          <.menu_divider />
        <% :rule -> %>
          <.menu_item :if={@rule_path} id={"#{@id}-rule"} navigate={@rule_path}>
            {gettext("Show the rule")}
          </.menu_item>
          <.menu_divider :if={@rule_path} />
        <% :open -> %>
          <.menu_heading
            :if={@allow_elsewhere}
            title={gettext("%{name} allows only its own hosts", name: @allow_elsewhere.name)}
            sub={gettext("An allow of the workspace or of a target would not be in force.")}
          />
          <.menu_item :if={@allow_elsewhere && @allow_path} id={"#{@id}-allow"} navigate={@allow_path}>
            {gettext("Allow in %{name}'s policy", name: @allow_elsewhere.name)}
          </.menu_item>
          <.menu_item
            :if={@option == :can_allow && !@allow_elsewhere}
            id={"#{@id}-allow"}
            phx-click={JS.push("rule_open", value: Map.put(@values, "action", "allow"))}
            aria-haspopup="dialog"
          >
            {gettext("Allow…")}
          </.menu_item>
          <.menu_item
            :if={@option == :can_deny or @both}
            id={"#{@id}-deny"}
            phx-click={JS.push("rule_open", value: Map.put(@values, "action", "deny"))}
            aria-haspopup="dialog"
          >
            {gettext("Deny…")}
          </.menu_item>
          <.menu_item :if={@rule_path} id={"#{@id}-rule"} navigate={@rule_path}>
            {if @above && @above_linked,
              do: gettext("Show the rule in %{name}'s policy", name: @above.name),
              else: gettext("Show the rule")}
          </.menu_item>
          <.menu_divider />
        <% nil -> %>
      <% end %>
      <.menu_item :if={@host_path} id={"#{@id}-host"} patch={@host_path.(@connection.host)}>
        {gettext("Only this host")}
      </.menu_item>
      <.menu_item
        id={"#{@id}-copy"}
        phx-hook="CopyToClipboard"
        data-copy={@connection.host}
        data-copied-words={gettext("Copied")}
      >
        {gettext("Copy the host")}
      </.menu_item>
    </.row_menu>
    """
  end

  defp menu_kind(:above_deny), do: :above
  defp menu_kind(option) when option in [:locked_deny, :locked_allow], do: :locked
  defp menu_kind(option) when option in [:can_allow, :can_deny], do: :open
  defp menu_kind({:rule_added, _action}), do: :rule
  defp menu_kind(:wall), do: :wall
  defp menu_kind(:unnameable), do: :unnameable
  defp menu_kind(_none), do: nil

  # Who locked the rule and when, as a heading; the newest history may not say.
  defp locked_words(%{by: by, at: %DateTime{} = at}) when is_binary(by),
    do: gettext("Locked by %{name} on %{date}", name: by, date: Format.date(at))

  defp locked_words(%{by: by}) when is_binary(by), do: gettext("Locked by %{name}", name: by)
  defp locked_words(_unknown), do: gettext("A locked rule of the workspace")

  # What a locked rule means for the row, as the refusal says it.
  defp locked_holds(:locked_deny),
    do: gettext("It holds against every target, so no rule added here would change what happens.")

  defp locked_holds(_locked_allow),
    do: gettext("It holds against every target, so a deny added here would change nothing.")

  @doc """
  The line a row gains once a rule answers it. The row above it is the record and stays as
  it was. `line` is `%{action, level, version, by, at, state, reloaded_at}`; `state` is
  `:pending` (the run is alive and has not reported the digest in force), `:in_force` (it
  has: claimed from the record, never after a timer), `:ended`, `:machine` (the run takes
  no policy from this server) or `:workspace` (the workspace's page, which says nothing of
  a run).
  """
  attr :id, :string, required: true
  attr :line, :map, required: true

  def after_line(assigns) do
    ~H"""
    <div id={@id} class="q-after" data-state={@line.state}>
      <.badge color={after_color(@line.state)}>
        <.icon name="hero-shield-check-micro" class="size-3" />{if @line.state == :in_force,
          do: gettext("In force in this run"),
          else: gettext("Rule added")}
      </.badge>
      <span>
        <.rich text={after_head(@line)}>
          <:part name={:version}><.scoped_version version={@line.version} class="text-xs" /></:part>
        </.rich><span :if={@line.state != :in_force && @line.by}>{" " <>
          gettext("by %{name}", name: @line.by)}</span><span :if={
          @line.state != :in_force && @line.at
        }> · <.relative_time at={@line.at} /></span>. {after_sentence(@line)}
      </span>
    </div>
    """
  end

  defp after_color(:in_force), do: "success"
  defp after_color(:pending), do: "info"
  defp after_color(:workspace), do: "info"
  defp after_color(_state), do: "neutral"

  # The head of the line, with the version the rule is in when it is known.
  defp after_head(%{version: nil} = line), do: after_head_alone(line)

  defp after_head(%{action: :deny, level: :target}),
    do: rich_gettext("Denied for this target in %{version}", version: {:part, :version})

  defp after_head(%{action: :deny}),
    do: rich_gettext("Denied for the workspace in %{version}", version: {:part, :version})

  defp after_head(%{level: :target}),
    do: rich_gettext("Allowed for this target in %{version}", version: {:part, :version})

  defp after_head(_line),
    do: rich_gettext("Allowed for the workspace in %{version}", version: {:part, :version})

  defp after_head_alone(%{action: :deny, level: :target}), do: gettext("Denied for this target")
  defp after_head_alone(%{action: :deny}), do: gettext("Denied for the workspace")
  defp after_head_alone(%{level: :target}), do: gettext("Allowed for this target")
  defp after_head_alone(_line), do: gettext("Allowed for the workspace")

  defp after_sentence(%{state: :pending}), do: gettext("The run has not reloaded yet.")

  defp after_sentence(%{state: :in_force, reloaded_at: seq}) when is_integer(seq),
    do:
      gettext("The run reloaded at #%{seq}.",
        seq: seq |> Integer.to_string() |> String.pad_leading(4, "0")
      )

  defp after_sentence(%{state: :in_force}), do: gettext("The run has reported it.")

  defp after_sentence(%{state: :ended}),
    do: gettext("This run has ended; the next run of the target has it.")

  defp after_sentence(%{state: :machine}),
    do: gettext("This run uses its machine's policy and does not take this one.")

  defp after_sentence(_line), do: nil

  @doc """
  The popover of a row's Allow or Deny: a `popover` element in the top layer, so the
  table's scroll container cannot clip it, placed under its button by the `RulePopover`
  hook and a bottom sheet below 768 px. `popover` is the page's state of it:

      %{anchor:, action: :allow | :deny, host:, path:, page: :run | :workspace, level:,
        target: %{label:} | nil, targets: [%{id, label, runs}], choice:,
        what: %{target:, workspace:}, own_rule:, workspace:, alive:, fetched:, interval:, consequence:, error:,
        refusal: nil | %{rule_option:, rule:, locked_by:, locked_at:, owner:, rule_path:}}

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
          <.spliced text={
            if @popover.refusal.rule_option == :locked_deny,
              do: gettext("%{host} stays denied", host: hole()),
              else: gettext("%{host} stays allowed", host: hole())
          }>
            <span class="q-pop-host">{middle(@popover.host, 40)}</span>
          </.spliced>
        </h3>
      </header>
      <div class="q-pop-body">
        <.notice kind={:warning}>
          <span id={"#{@id}-refusal"}>
            <.spliced text={
              if @popover.refusal.rule_option == :locked_deny,
                do: gettext("A locked workspace rule denies %{rule}.", rule: hole()),
                else: gettext("A locked workspace rule allows %{rule}.", rule: hole())
            }>
              <.mono bare>{@popover.refusal.rule}</.mono>
            </.spliced>
            {if @popover.refusal.rule_option == :locked_deny,
              do:
                gettext(
                  "It holds against every target, so no rule added here would change what happens."
                ),
              else:
                gettext("It holds against every target, so a deny added here would change nothing.")}
            <span :if={@popover.refusal.locked_by}>
              {if @popover.refusal.locked_at,
                do:
                  gettext("Locked by %{name} on %{date}.",
                    name: @popover.refusal.locked_by,
                    date: Format.date(@popover.refusal.locked_at)
                  ),
                else: gettext("Locked by %{name}.", name: @popover.refusal.locked_by)}
            </span>
            {if @popover.refusal.owner,
              do: gettext("You can change or unlock it on the workspace's policy page."),
              else: gettext("Only an owner can change or unlock it.")}
          </span>
        </.notice>
      </div>
      <footer>
        <.button id={"#{@id}-close"} phx-click="rule_cancel" data-autofocus>
          {gettext("Close")}
        </.button>
        <.button id={"#{@id}-locked-rule"} navigate={@popover.refusal.rule_path}>
          {gettext("Show the locked rule")}
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
            <.spliced text={popover_title(@deny, @what && @what.kind == :path)}>
              <span
                class="q-pop-host"
                title={@popover.host}
              >{middle(@popover.host, 40)}</span>
            </.spliced>
          </h3>
        </header>
        <div class="q-pop-body">
          <div :if={@popover.error} id={"#{@id}-error"} role="alert">
            <.notice kind={:error}>{@popover.error}</.notice>
          </div>

          <fieldset :if={@what && @what.kind == :path} id={"#{@id}-what-set"}>
            <legend>
              {gettext("What. This host has path rules:")}
              <.mono :for={path <- Enum.take(@what.paths, 6)} bare class="q-rule">
                {middle(path, 40)}
              </.mono>
              <span :if={length(@what.paths) > 6}>
                {ngettext("and %{number} more", "and %{number} more", length(@what.paths) - 6,
                  number: Format.number(length(@what.paths) - 6)
                )}
              </span>
              <span :if={@what.paths == []}>{gettext("none, so no path is allowed")}</span>
            </legend>
            <p id={"#{@id}-what"} class="q-pop-what">
              <b>{gettext("This path")}</b>
              <.mono bare class="q-rule">{middle(@popover.path, 64)}</.mono>
              {if @deny,
                do: gettext("is taken out of the paths in force for the host."),
                else: gettext("is added to the paths in force for the host.")}
            </p>
          </fieldset>

          <fieldset>
            <legend>{gettext("For")}</legend>
            <label :if={@popover.page == :run and @popover.target} class="q-popt">
              <input
                type="radio"
                name="for"
                value="target"
                checked={@popover.level == :target}
              />
              <span>
                <b>{gettext("This target")}</b>
                <span class="font-mono text-xs text-muted">{middle(@popover.target.label, 48)}</span>
              </span>
              <small :if={@deny && @popover.consequence[:target]}>
                {@popover.consequence.target}
              </small>
            </label>
            <label :if={@popover.page == :workspace and @popover.targets != []} class="q-popt">
              <input
                type="radio"
                name="for"
                value="target"
                checked={@popover.level == :target}
              />
              <span><b>{gettext("One target")}</b></span>
              <small :if={@deny && @popover.consequence[:target]}>
                {@popover.consequence.target}
              </small>
            </label>
            <%!-- Outside the label: inside it, every option would be part of the radio's name. --%>
            <div
              :if={@popover.page == :workspace and @popover.targets != []}
              class="q-popt-more"
            >
              <select
                name="target"
                id={"#{@id}-target"}
                class="select select-sm q-pop-select"
                aria-label={gettext("Target")}
              >
                <option value="" selected={is_nil(@popover.choice)}>
                  {gettext("Choose a target")}
                </option>
                <option
                  :for={target <- @popover.targets}
                  value={target.id}
                  selected={@popover.choice == target.id}
                >
                  {middle(target.label, 56)} · {ngettext(
                    "%{number} run",
                    "%{number} runs",
                    target.runs,
                    number: Format.number(target.runs)
                  )}
                </option>
              </select>
            </div>
            <label class="q-popt">
              <input type="radio" name="for" value="workspace" checked={@popover.level == :workspace} />
              <span><b>{gettext("The whole workspace")}</b></span>
              <small>
                {gettext("Every target of %{workspace}.", workspace: @popover.workspace)} {if @deny,
                  do: @popover.consequence[:workspace]}
              </small>
              <small :if={@popover[:own_rule]} id={"#{@id}-own-rule"}>
                {if @popover.page == :run,
                  do: gettext("This target's own rule still decides here."),
                  else: gettext("A target's own rule for this host still decides there.")}
              </small>
            </label>
          </fieldset>

          <p class="q-pop-next">
            <.icon name="hero-arrow-path-micro" class="size-3.5" />
            <span id={"#{@id}-next"}>
              {gettext("Takes effect in running sessions within a heartbeat, about %{seconds} s.",
                seconds: Format.number(@popover.interval)
              )} {next_sentence(@popover)}
            </span>
          </p>
        </div>
        <footer>
          <.button id={"#{@id}-cancel"} type="button" phx-click="rule_cancel">
            {gettext("Cancel")}
          </.button>
          <.button
            id={"#{@id}-submit"}
            type="submit"
            variant={if @deny, do: "danger", else: "primary"}
            disabled={!@ready}
          >
            {submit_label(@deny, @popover)}
          </.button>
        </footer>
      </form>
    </div>
    """
  end

  # What the domain will do is said for the level chosen, and for no other.
  defp popover_what(%{level: level, what: what}) when is_map(what), do: what[level]
  defp popover_what(_popover), do: nil

  defp popover_ready?(%{level: :workspace}), do: true
  defp popover_ready?(%{level: :target, page: :run}), do: true
  defp popover_ready?(%{level: :target, choice: choice}) when is_binary(choice), do: true
  defp popover_ready?(_popover), do: false

  # Under observe an allow changes what the record says, not what the run does: the
  # connection is let through already. A deny holds in either mode, so its sentence is
  # the same under observe as under enforce.
  defp next_sentence(%{action: :allow, mode: "observe"}),
    do:
      gettext(
        "This run observes, so the connection is already let through: the rule records that it may be."
      )

  defp next_sentence(%{action: :deny}),
    do: gettext("Open connections to the host are closed at the reload.")

  defp next_sentence(%{page: :run, alive: true, fetched: true}),
    do: gettext("This run is alive: its next attempt can succeed.")

  defp next_sentence(%{page: :run, alive: true}),
    do: gettext("This run uses its machine's policy and does not take this one.")

  defp next_sentence(_popover), do: nil

  # The popover's title, with the host's element where `hole/0` stands.
  defp popover_title(true = _deny, true = _path), do: gettext("Deny on %{host}", host: hole())
  defp popover_title(true, _path), do: gettext("Deny %{host}", host: hole())
  defp popover_title(_deny, true), do: gettext("Allow on %{host}", host: hole())
  defp popover_title(_deny, _path), do: gettext("Allow %{host}", host: hole())

  defp submit_label(true = _deny, %{level: :workspace}), do: gettext("Deny for the workspace")
  defp submit_label(true, %{level: :target, page: :run}), do: gettext("Deny for this target")
  defp submit_label(true, %{level: :target}), do: gettext("Deny for the target")
  defp submit_label(true, _popover), do: gettext("Deny for …")
  defp submit_label(_deny, %{level: :workspace}), do: gettext("Allow for the workspace")
  defp submit_label(_deny, %{level: :target, page: :run}), do: gettext("Allow for this target")
  defp submit_label(_deny, %{level: :target}), do: gettext("Allow for the target")
  defp submit_label(_deny, _popover), do: gettext("Allow for …")

  @doc """
  A version named on a run's pages: the version link and, since versions count per holder
  (the baseline's apart from each target's), the words that say whose it is. `version` is
  `%{n, path, label}`; a missing label says nothing.
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
        title={@title || version_title(@version)}
      /><small :if={@version[:label]} class="q-sver-of" title={@version.label}><span aria-hidden="true"> · </span><span class="sr-only"> {gettext("of")} </span>{middle(
        @version.label,
        32
      )}</small>
    </span>
    """
  end

  defp version_title(%{n: n, label: label}) when is_binary(label),
    do: gettext("Version %{n} of %{holder}. Open the exact document.", n: n, holder: label)

  defp version_title(%{n: n}), do: gettext("Version %{n}. Open the exact document.", n: n)

  @doc "A version in a sentence: \"the workspace baseline's v3\", \"acme/shop's v1\"."
  def version_words(%{n: n, label: label}) when is_binary(label) do
    if baseline?(label),
      do: gettext("v%{n} of the workspace's policy", n: n),
      else: gettext("%{holder}'s v%{n}", holder: middle(label, 40), n: n)
  end

  def version_words(%{n: n}), do: gettext("v%{n}", n: n)
  def version_words(_version), do: gettext("another configuration")

  # The baseline's label is made elsewhere, in engine words or already in the domain's.
  defp baseline?(label),
    do:
      label in ["workspace baseline", "the workspace's policy", gettext("the workspace's policy")]

  ## The drift mark

  @doc """
  The mark of a run that is alive and last reported a run configuration other than the one
  in force for its target: an amber badge, a triangle and words, never a pulse. It is
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
      <.icon name="hero-exclamation-triangle-micro" class="size-[11px]" />{gettext("Behind v%{n}",
        n: @in_force.n
      )}<span
        :if={@in_force[:label]}
        class="q-drift-of"
      > · {middle(@in_force.label, 24)}</span>
    </span>
    """
  end

  defp drift_tip(reported, in_force, last_seq) do
    [
      if(is_integer(last_seq) and last_seq > 0,
        do:
          gettext("The run last reported %{version} at #%{seq}.",
            version: version_words(reported),
            seq: last_seq |> Integer.to_string() |> String.pad_leading(4, "0")
          ),
        else: gettext("The run last reported %{version}.", version: version_words(reported))
      ),
      gettext("%{version} has been in force since %{time}.",
        version: String.capitalize(version_words(in_force)),
        time: Format.clock(in_force.rendered_at)
      ),
      gettext("A run reloads at its next heartbeat.")
    ]
    |> Enum.join(" ")
  end

  ## New items pill

  @doc """
  The pill that counts what arrived while the reader was away from the live end. A button,
  not a live region. Hidden at zero. `on_click` is an event name or a `JS` command; the
  scroll container's selector rides on `data-target` for the hook that scrolls.
  """
  attr :id, :string, required: true
  attr :count, :integer, required: true
  attr :noun, :string, default: "event", values: ~w(event run line)
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
      <span>{new_words(@count, @noun)}</span>
    </button>
    """
  end

  defp new_words(count, "run"),
    do: ngettext("%{number} new run", "%{number} new runs", count, number: Format.number(count))

  defp new_words(count, "line"),
    do: ngettext("%{number} new line", "%{number} new lines", count, number: Format.number(count))

  defp new_words(count, _event),
    do:
      ngettext("%{number} new event", "%{number} new events", count, number: Format.number(count))
end
