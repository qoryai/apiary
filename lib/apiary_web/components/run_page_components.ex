defmodule ApiaryWeb.RunPageComponents do
  @moduledoc """
  The components of the run page (`docs/ui.md`): what the run is about, as the header's
  line and the rail's About; the session timeline with its lanes and items, the who chip,
  the background-task strip, the live end, the limits notice and the terminal box.

  An item is what `Apiary.Runs.Record.Timeline.build/3` made of a run's events. Everything
  in it came from Forager and is untrusted: it is interpolated, so it is escaped, and it
  is never `raw/1`. Its texts are shown as a page shows a text an external system sent
  (`Apiary.ExternalText`), and one that was sent but has nothing left to show is marked
  (`Apiary.ExternalText.marked/1`), but for a session's reason, a signal and a folded
  group's tool, which then read as none. A link is built by the caller from a verified
  route and a sequence number, never from a string of the record. The terminal's bytes
  are not rendered here at all: the `Terminal` hook feeds them to xterm.js.

  `security={false}` is an instance without `security`: the timeline's connections say
  what Forager reported and nothing of a rule. The run page leaves the policy's items
  out of the index it hands over, so none reaches a component here.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText
  import ApiaryWeb.ExternalText, only: [external_text: 1]

  import ApiaryWeb.CoreComponents,
    only: [
      badge: 1,
      icon: 1,
      notice: 1,
      empty_state: 1,
      external_link: 1,
      listening: 1,
      term: 1
    ]

  import ApiaryWeb.RunComponents,
    only: [
      connection_row: 1,
      tool_mark: 1,
      duration: 1,
      offset: 1,
      middle: 2,
      subject_name: 1,
      subject_tip: 1,
      work_item_name: 1
    ]

  alias Apiary.ExternalText
  alias Apiary.Runs.Record.Timeline
  alias Apiary.Runs.RunApi
  alias ApiaryWeb.Format
  alias ApiaryWeb.RunComponents

  alias Phoenix.LiveView.JS

  @background_tip gettext_noop(
                    "The runtime lists what is still running at the end of each turn. A task counts as running until a list leaves it out."
                  )

  ## The lane key

  @doc """
  One toggle of the lane key: a ring in the lane's colour, the agent's type and its id.
  The key is the legend of the rails, so colour is never the only carrier.
  """
  attr :lane, :map, required: true, doc: "%{index, id, type, color}"
  attr :pressed, :boolean, default: true
  attr :patch, :string, required: true

  # A button that patches, so that it answers Space as well as Enter and the URL changes. The
  # DOM id is the lane's number in the run: an agent id is Forager's string.
  def lane(assigns) do
    ~H"""
    <button
      type="button"
      id={"lane-#{@lane.index}"}
      phx-click={JS.patch(@patch)}
      class={["q-lanekey", "q-lane-#{@lane.color}"]}
      aria-pressed={to_string(@pressed)}
    >
      <i aria-hidden="true"></i>
      <%= if @lane.id == "main" do %>
        {gettext("Main session")}
      <% else %>
        <.external_text text={@lane.type} />{if !sent(@lane.type), do: gettext("Subagent")}
        <small><.external_text text={@lane.id} /></small>
      <% end %>
    </button>
    """
  end

  ## Who

  @doc "The agent an item belongs to, in words, where a lane opens or closes."
  attr :lane, :map, required: true
  attr :rest, :global

  def who(assigns) do
    ~H"""
    <span class={["q-who", "q-lane-#{@lane.color}"]} {@rest}>
      <bdi>{if @lane.id == "main",
        do: gettext("Main session"),
        else: sent(@lane.type) || sent(@lane.id)}</bdi>
    </span>
    """
  end

  ## P7. Background tasks

  @doc """
  The tasks the runtime last listed as still running. No duration and no clock: the record
  has none for them. `ended` turns "still running" into "was still listed when the run ended".
  """
  attr :id, :string, default: "background-tasks"
  attr :background, :map, required: true, doc: "%{tasks: [...], count: n} of the timeline index"
  attr :ended, :boolean, default: false

  def background_tasks(assigns) do
    assigns =
      assign(assigns,
        shown: Enum.take(assigns.background.tasks, 3),
        tip: Gettext.gettext(ApiaryWeb.Gettext, @background_tip)
      )

    ~H"""
    <div
      :if={@background.count > 0}
      id={@id}
      class="q-bgtasks"
      role="status"
      aria-label={gettext("Background tasks")}
    >
      <%= for {task, i} <- Enum.with_index(@shown) do %>
        <span class={["q-spin", @ended && "q-spin-still"]} aria-hidden="true"></span>
        <span class="truncate">
          <b :if={i == 0} class="font-medium">
            {background_words(@background.count, @ended)}
          </b>
          <span class={["font-mono text-[12.5px] text-muted", i == 0 && "ml-1.5"]}><bdi>{sent(
            task.what
          ) ||
            sent(task.type) || gettext("task")}</bdi></span>
        </span>
        <span
          class="q-bgtasks-since tooltip tooltip-left q-tip-wide text-xs text-faint"
          tabindex="0"
          data-tip={@tip}
        >
          {gettext("%{task} %{id} · listed at #%{sequence}",
            task: sent(task.type) || gettext("task"),
            id: sent(task.id),
            sequence: pad(task.listed_at)
          )}
        </span>
      <% end %>
      <span :if={@background.count > 3} class="col-start-2 text-xs text-faint">
        {and_more(@background.count - 3)}
      </span>
    </div>
    """
  end

  defp background_words(count, true) do
    ngettext(
      "%{number} task was still listed when the run ended",
      "%{number} tasks were still listed when the run ended",
      count,
      number: Format.number(count)
    )
  end

  defp background_words(count, false) do
    ngettext(
      "%{number} task still running in the background",
      "%{number} tasks still running in the background",
      count,
      number: Format.number(count)
    )
  end

  defp and_more(n),
    do: ngettext("and %{number} more", "and %{number} more", n, number: Format.number(n))

  ## Limits

  @doc """
  A fact about the record: why a timeline, a log or a connection list is not there. An
  info notice above content that is there (`variant="notice"`), or the body of an empty
  state when it replaces content that is absent. Never a toast, never dismissible.
  """
  attr :reason, :atom,
    required: true,
    values: [
      :no_hooks,
      :vm_wall,
      :other_runtime,
      :not_started,
      :no_egress,
      :no_log,
      :pruned,
      :log_pruned
    ]

  attr :variant, :string, default: "notice", values: ~w(notice empty)
  attr :runtime, :string, default: nil
  attr :live, :boolean, default: false
  attr :wall, :boolean, default: false
  attr :only_result, :boolean, default: false
  attr :at, :any, default: nil, doc: "when retention pruned, for `:pruned` and `:log_pruned`"

  attr :registered, :boolean,
    default: false,
    doc: "for `:not_started`: whether the run registered, else it only pinged"

  attr :sentence, :boolean,
    default: true,
    doc: "false leaves the sentence out, for a queued run, which has not pinged"

  attr :terminal, :boolean,
    default: true,
    doc:
      "whether the reader is shown the run's terminal (`run.read_log`): a sentence " <>
        "that includes the terminal is shown only then"

  def limits(%{variant: "notice"} = assigns) do
    ~H"""
    <.notice class="q-limits">
      <.limit_sentence
        reason={@reason}
        runtime={@runtime}
        registered={@registered}
        terminal={@terminal}
      />
      <span :if={@only_result}>
        {gettext("Only the result, read from the runtime's output, is shown.")}
      </span>
    </.notice>
    """
  end

  def limits(%{variant: "empty"} = assigns) do
    ~H"""
    <.empty_state
      tone="neutral"
      icon={limit_icon(@reason)}
      title={limit_title(@reason, @live)}
      class="q-limits"
    >
      <.limit_sentence
        :if={@reason != :no_log and @sentence}
        reason={@reason}
        runtime={@runtime}
        at={@at}
        registered={@registered}
        terminal={@terminal}
      />
      <.listening
        :if={@reason == :not_started or (@reason == :no_log and @live)}
        class="mt-3 justify-center"
      >
        {if @reason == :not_started,
          do: gettext("Listening for the run's first event."),
          else: gettext("Listening for the first bytes.")}
      </.listening>
    </.empty_state>
    """
  end

  attr :reason, :atom, required: true
  attr :runtime, :string, default: nil
  attr :at, :any, default: nil
  attr :registered, :boolean, default: false
  attr :terminal, :boolean, default: true

  defp limit_sentence(%{reason: :pruned} = assigns) do
    ~H"""
    {gettext(
      "This run's events were pruned on %{date}, under the workspace's retention. The run keeps its header, its counts and its connections; the timeline and the log output are gone.",
      date: Format.date(@at)
    )}
    """
  end

  defp limit_sentence(%{reason: :log_pruned} = assigns) do
    ~H"""
    {gettext(
      "This run's log output was pruned on %{date}, under the workspace's retention. The timeline and the connections are whole.",
      date: Format.date(@at)
    )}
    """
  end

  # A run stored before the registration replaced the ping has only pinged.
  defp limit_sentence(%{reason: :not_started, registered: true} = assigns) do
    ~H"""
    {gettext("The run is registered. Its first event has not arrived.")}
    """
  end

  defp limit_sentence(%{reason: :not_started} = assigns) do
    ~H"""
    {gettext("Forager has pinged. The run's first event has not arrived.")}
    """
  end

  defp limit_sentence(%{reason: :other_runtime} = assigns) do
    ~H"""
    <.rich text={
      if @terminal,
        do:
          rich_gettext(
            "Only Claude Code sends session events. This session ran %{runtime}: its output is under Terminal, and its connections under Network access.",
            runtime: {:part, :runtime}
          ),
        else:
          rich_gettext(
            "Only Claude Code sends session events. This session ran %{runtime}: its connections are under Network access.",
            runtime: {:part, :runtime}
          )
    }>
      <:part name={:runtime}><code class="q-rule">{@runtime}</code></:part>
    </.rich>
    """
  end

  defp limit_sentence(%{reason: :vm_wall} = assigns) do
    ~H"""
    <.rich text={
      if @terminal,
        do:
          rich_gettext(
            "This run's session events could not be recorded: the %{wall} it ran behind runs inside a virtual machine. The run has a terminal and connections, and no session timeline.",
            wall: {:part, :wall}
          ),
        else:
          rich_gettext(
            "This run's session events could not be recorded: the %{wall} it ran behind runs inside a virtual machine. The run has connections and no session timeline.",
            wall: {:part, :wall}
          )
    }>
      <:part name={:wall}>
        <.term
          word={gettext("wall")}
          standard={
            gettext("The enclosure the agent runs in. Its only route out leads to the gateway.")
          }
          class="q-tip-wide"
        />
      </:part>
    </.rich>
    """
  end

  defp limit_sentence(%{reason: :no_hooks} = assigns) do
    ~H"""
    {if @terminal,
      do:
        gettext(
          "No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its terminal and connections."
        ),
      else:
        gettext(
          "No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its connections."
        )}
    """
  end

  defp limit_sentence(%{reason: :no_egress} = assigns) do
    ~H"""
    {gettext(
      "No connection went through the gateway. Only programs that honour the proxy variables are seen."
    )}
    """
  end

  defp limit_sentence(assigns), do: ~H""

  defp limit_title(:pruned, _live), do: gettext("Events pruned")
  defp limit_title(:log_pruned, _live), do: gettext("Log output pruned")
  defp limit_title(:not_started, _live), do: gettext("Waiting for the run to start")
  defp limit_title(:no_egress, _live), do: gettext("No connections recorded")
  defp limit_title(:no_log, true), do: gettext("No output yet")
  defp limit_title(:no_log, false), do: gettext("This run wrote no output")
  defp limit_title(_reason, _live), do: gettext("No session timeline")

  defp limit_icon(:pruned), do: "hero-archive-box-x-mark"
  defp limit_icon(:log_pruned), do: "hero-archive-box-x-mark"
  defp limit_icon(:not_started), do: "hero-play-circle"
  defp limit_icon(:no_egress), do: "hero-arrows-right-left"
  defp limit_icon(:no_log), do: "hero-command-line"
  defp limit_icon(_reason), do: "hero-list-bullet"

  ## The timeline

  @doc """
  The session timeline: one column in sequence order, a rail per agent in the gutter. The
  `<ol>` is a LiveView stream; it has no `aria-live`, new items are counted by the pill.

  `target` is the DOM id of the item `?seq=` points at and `isolate` the lane `?lane=`
  keeps; both are applied by the `TimelineKeys` hook, because a stream's items are not
  rendered again when a parameter changes.

  A row ends with its time since the run started, how long it took, and its event number.
  A row with `terminal_seq` links to that line of the Terminal
  (`Apiary.Runs.Record.Overview.terminal_seq/2`) while `terminal_path` is set.
  """
  attr :id, :string, required: true
  attr :stream, :any, required: true
  attr :rails, :integer, required: true, doc: "how many rails the gutter holds, 1 to 4"
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true, doc: "a function from a sequence to the item's permalink"
  attr :target, :string, default: nil
  attr :isolate, :string, default: nil

  attr :connections, :boolean,
    default: false,
    doc: "true shows the allowed connections too (?cx=1); a denied one always shows"

  attr :terminal_path, :any,
    default: nil,
    doc:
      "a function from a sequence to the item in the Terminal, nil for a reader without the log"

  attr :earlier, :integer, default: 0, doc: "items before the window"
  attr :later, :integer, default: 0, doc: "items after the window that are not new arrivals"
  attr :earlier_events, :integer, default: 0, doc: "the items with a sequence among `earlier`"
  attr :later_events, :integer, default: 0, doc: "the items with a sequence among `later`"

  attr :until, :integer,
    default: nil,
    doc: "the sequence of the window's last item while items follow it, nil at the tab's end"

  attr :security, :boolean, default: true, doc: "false: connections without rules or modes"
  attr :legend, :boolean, default: false, doc: "whether a row is there for the legend to label"

  attr :keep, :any,
    default: nil,
    doc: "a function true of each item of `stream` this list shows; nil: every item"

  def timeline(assigns) do
    ~H"""
    <div class="grid q-took">
      <div :if={@legend} class="q-tlegend" aria-hidden="true">
        <span class="q-tc1">{gettext("Since run start")}</span>
        <span class="q-tct">{gettext("Took")}</span>
        <span class="q-tc2">{gettext("Event")}</span>
      </div>
      <button
        :if={@earlier > 0}
        id={"#{@id}-earlier"}
        type="button"
        class="q-tl-more"
        phx-click="load_earlier"
      >
        <.icon name="hero-arrow-up-micro" class="size-3" />
        {if @earlier_events > 0,
          do: earlier_events(@earlier_events),
          else: gettext("Load earlier")}
      </button>
      <ol
        id={@id}
        class={["q-tl", "q-lanes-#{@rails}"]}
        aria-label={timeline_label(@earlier > 0 && @earlier_events, @later > 0 && @later_events)}
        phx-update="stream"
        phx-hook="TimelineKeys"
        data-target={@target}
        data-isolate={@isolate}
        data-cx={if @connections, do: "1", else: "0"}
        data-until={@until}
        tabindex="0"
      >
        <.timeline_item
          :for={{dom_id, item} <- @stream}
          :if={is_nil(@keep) or @keep.(item)}
          id={dom_id}
          item={item}
          started_at={@started_at}
          seq_path={@seq_path}
          terminal_path={@terminal_path}
          security={@security}
        />
      </ol>
      <button
        :if={@later > 0}
        id={"#{@id}-later"}
        type="button"
        class="q-tl-more"
        phx-click="load_later"
      >
        <.icon name="hero-arrow-down-micro" class="size-3" /> {gettext("Load newer")}
        <span :if={@later_events > 0} class="text-faint">· {later_events(@later_events)}</span>
      </button>
      <span id={"#{@id}-push"} phx-hook="TimelinePush" hidden></span>
    </div>
    """
  end

  @doc """
  The Timeline's light items with each subagent (`ApiaryWeb.TranscriptComponents.subagents/2`)
  folded into its start, in sequence order. The start, the head, has `sub`: its subagent
  with `open`; `lines`, how many items of its lane come after the start; and
  `hidden_denied`, the sequences of the denied calls left out while it is closed. The head
  has `seqs` with its finish too, whose message and time it shows. A closed subagent's
  items after its start are left out, and so is its rail from the start through its
  finish, except on the rows of another agent whose node sits on that rail: an agent that
  starts while every rail is taken shares the last one (`Apiary.Runs.Record.Timeline`).
  The rail keeps its place in the gutter, so a later subagent's rail does not move. When
  the record's last item is left out, the last row left ends the rails as that item does:
  faded while the record is being written, else with main's rail ending at it.

  A subagent is open as the reader chose in `choices` (a head's sequence to true or false),
  else while it has not finished.
  """
  def fold(items, subs, _choices) when map_size(subs) == 0, do: items

  def fold(items, subs, choices) do
    lines =
      Enum.frequencies(
        for item <- items,
            sub = in_sub(item, subs),
            sub != nil and item.seq > sub.seq,
            do: item.lane.index
      )

    # The denied calls after each subagent's start, which `x` and `Shift+x` reach in a
    # closed subagent too (`TimelineKeys`).
    denied =
      Enum.group_by(
        for(
          item <- items,
          sub = in_sub(item, subs),
          sub != nil and item.seq > sub.seq and denied_light?(item),
          do: item
        ),
        & &1.lane.index,
        & &1.seq
      )

    open =
      Map.new(subs, fn {lane, sub} ->
        {lane,
         case choices[sub.seq] do
           choice when is_boolean(choice) -> choice
           nil -> sub.state != :finished
         end}
      end)

    # The rails of the closed subagents that have one, each with its lane and the
    # sequences it spans.
    shut =
      for item <- items,
          sub = in_sub(item, subs),
          sub != nil and item.seq == sub.seq,
          not open[item.lane.index],
          item.link,
          do: {item.link.rail, item.lane.index, sub.seq, sub.finished_seq}

    items
    |> Enum.flat_map(fn item ->
      sub = in_sub(item, subs)

      cond do
        sub != nil and item.seq == sub.seq ->
          [
            item
            |> Map.merge(%{
              sub:
                Map.merge(sub, %{
                  open: open[item.lane.index],
                  lines: Map.get(lines, item.lane.index, 0),
                  hidden_denied:
                    if(open[item.lane.index], do: [], else: Map.get(denied, item.lane.index, []))
                }),
              seqs: Enum.uniq(item.seqs ++ List.wrap(sub.finished_seq))
            })
            |> without_rails(shut)
          ]

        sub != nil and item.seq > sub.seq and not open[item.lane.index] ->
          []

        true ->
          [without_rails(item, shut)]
      end
    end)
    |> end_rails(List.last(items))
  end

  # A light item that `denied?/1` is true of once it is built.
  defp denied_light?(%{kind: :connection} = item), do: item[:decision] == "denied"
  defp denied_light?(%{kind: :tool, denied_inside: true}), do: true
  defp denied_light?(_item), do: false

  # The subagent whose lane the item is in, nil for an item of main or of an agent the
  # record opened no lane for.
  defp in_sub(item, subs) do
    lane = item.lane[:index]
    if is_integer(lane), do: subs[lane]
  end

  defp without_rails(item, []), do: item

  defp without_rails(item, shut) do
    gone =
      for {rail, lane, from, through} <- shut,
          spanned?(item, from, through),
          # An agent that shares the closed subagent's rail keeps it under its node.
          item.lane.rail != rail or item.lane[:index] == lane,
          do: rail

    if gone == [], do: item, else: %{item | rails: Enum.reject(item.rails, &(&1.rail in gone))}
  end

  # Whether a row is on a closed subagent's rail, from its start through its finish. A
  # row with no sequence (`Apiary.Runs.Record.Overview.list/2`) sits right after the row
  # of the sequence its `pos` starts with.
  defp spanned?(%{seq: seq}, from, through) when is_integer(seq),
    do: seq >= from and (is_nil(through) or seq <= through)

  defp spanned?(%{pos: {after_seq, _}}, from, through),
    do: after_seq >= from and (is_nil(through) or after_seq < through)

  # The last row ends the rails as the record's last item does (`Timeline.index/2`), when
  # that item is left out: every rail faded while main's is (the record is being written),
  # else main's rail ending. A rail that starts or ends at the row keeps its part.
  defp end_rails([], _last), do: []

  defp end_rails(rows, last) do
    case List.last(rows) do
      %{seq: seq} when seq == last.seq ->
        rows

      row ->
        live? = Enum.any?(last.rails, &(&1.rail == 0 and &1.part == :live))

        rails =
          Enum.map(row.rails, fn rail ->
            cond do
              rail.part in [:from, :to] -> rail
              live? -> %{rail | part: :live}
              rail.rail == 0 -> %{rail | part: :to}
              true -> rail
            end
          end)

        List.replace_at(rows, -1, %{row | rails: rails})
    end
  end

  # "Oldest first" is only true of a list that starts at the start. `earlier` and `later` are
  # the events outside the window, false while no item is there, and 0 while only Main
  # session or Pushed rows are there: the label then has no count for that side.
  defp timeline_label(false, false), do: gettext("Session timeline, oldest first")

  defp timeline_label(earlier, later) when earlier in [false, 0] and later in [false, 0],
    do: gettext("Session timeline, in sequence order")

  defp timeline_label(0, later), do: timeline_label(false, later)
  defp timeline_label(earlier, 0), do: timeline_label(earlier, false)

  defp timeline_label(earlier, false) do
    gettext("Session timeline, in sequence order; %{earlier} not loaded",
      earlier: earlier_events(earlier)
    )
  end

  defp timeline_label(false, later) do
    gettext("Session timeline, in sequence order; %{later} not loaded",
      later: later_events(later)
    )
  end

  defp timeline_label(earlier, later) do
    gettext("Session timeline, in sequence order; %{earlier} not loaded; %{later} not loaded",
      earlier: earlier_events(earlier),
      later: later_events(later)
    )
  end

  defp earlier_events(n),
    do:
      ngettext("%{number} earlier event", "%{number} earlier events", n, number: Format.number(n))

  defp later_events(n),
    do: ngettext("%{number} later event", "%{number} later events", n, number: Format.number(n))

  @doc """
  One item: the gutter with the rails open at its sequence and its node, then the body.
  A connection has no node: egress belongs to the run, not to an agent.
  """
  attr :id, :string, required: true, doc: "\"e-\#{sequence}\""
  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  attr :terminal_path, :any, default: nil
  attr :security, :boolean, default: true

  def timeline_item(assigns) do
    ~H"""
    <li
      id={@id}
      class={["q-ti", connection?(@item) && "q-ti-cx"]}
      data-seq={@item.sequence}
      data-lane={@item.lane.id}
      data-denied={denied?(@item) && "1"}
      data-hidden-denied={hidden_denied(@item)}
      tabindex="-1"
    >
      <div class="q-g" aria-hidden="true">
        <span
          :for={rail <- @item.rails}
          class={["q-r", "q-rail-#{rail.rail}", "q-lane-#{rail.color}", "q-r-#{rail.part}"]}
        ></span>
        <span
          :if={@item.link}
          class={["q-h", "q-rail-#{@item.link.rail}", "q-lane-#{@item.link.color}"]}
        ></span>
        <.item_node :if={!connection?(@item)} item={@item} />
      </div>
      <div class={["q-b", connection?(@item) && "q-b-cx"]}>
        <span :if={@item.lane.id != "main"} class="sr-only">
          {gettext("in %{agent} %{id}:",
            agent: sent(@item.lane.type) || gettext("subagent"),
            id: short_agent(sent(@item.lane.id))
          )}
        </span>
        <.item_body
          id={@id}
          item={@item}
          started_at={@started_at}
          seq_path={@seq_path}
          terminal_path={@terminal_path}
          security={@security}
        />
      </div>
    </li>
    """
  end

  # Enough of an agent's id to tell two agents of one type apart when read aloud.
  defp short_agent(id) when is_binary(id), do: String.slice(id, -8, 8)
  defp short_agent(_id), do: ""

  defp connection?(item), do: item.kind in [:connection, :connection_group]

  defp denied?(%{kind: :connection, connection: %{decision: "denied"}}), do: true
  defp denied?(%{kind: :tool, denied_inside: true}), do: true
  defp denied?(_item), do: false

  # The sequences of the denied calls a closed subagent's head stands for.
  defp hidden_denied(%{sub: %{hidden_denied: [_ | _] = seqs}}), do: Enum.join(seqs, " ")
  defp hidden_denied(_item), do: nil

  attr :item, :map, required: true

  defp item_node(assigns) do
    assigns = assign(assigns, :look, node_look(assigns.item))

    ~H"""
    <span class={[
      "q-n",
      "q-rail-#{@item.lane.rail}",
      "q-lane-#{@item.lane.color}",
      @look.shape == :square && "q-n-sys",
      @look.tone == :fail && "q-n-fail",
      @look.tone == :warn && "q-n-warn",
      @look.tone == :solid && "q-n-solid",
      @look.tone == :info && "q-n-run"
    ]}>
      <span :if={@look.glyph == :spinner} class="q-spin"></span>
      <.icon :if={@look.glyph != :spinner} name={@look.glyph} class="size-3" />
    </span>
    """
  end

  defp node_look(%{kind: :run_started}),
    do: %{glyph: "hero-play-micro", shape: :square, tone: :info}

  defp node_look(%{kind: :policy_applied, again: true}),
    do: %{glyph: "hero-arrow-path-micro", shape: :square, tone: nil}

  defp node_look(%{kind: :policy_applied}),
    do: %{glyph: "hero-shield-check-micro", shape: :square, tone: nil}

  # The run's end is marked as its state is: a check for Completed, a neutral stop for
  # Cancelled, a neutral pause for Paused, an amber signal-slash for Lost, a red x-mark for
  # Failed.
  defp node_look(%{kind: :run_exited, state: "completed"}),
    do: %{glyph: "hero-check-micro", shape: :square, tone: nil}

  defp node_look(%{kind: :run_exited, state: "cancelled"}),
    do: %{glyph: "hero-stop-micro", shape: :square, tone: nil}

  defp node_look(%{kind: :run_exited, state: "paused"}),
    do: %{glyph: "hero-pause-micro", shape: :square, tone: nil}

  defp node_look(%{kind: :run_exited, state: "lost"}),
    do: %{glyph: "hero-signal-slash-micro", shape: :square, tone: :warn}

  defp node_look(%{kind: kind}) when kind in [:run_exited, :run_refused],
    do: %{glyph: "hero-x-mark-micro", shape: :square, tone: :fail}

  defp node_look(%{kind: :session_started}),
    do: %{glyph: "hero-command-line-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :prompt}),
    do: %{glyph: "hero-chat-bubble-left-micro", shape: :round, tone: :solid}

  defp node_look(%{kind: :main_session}),
    do: %{glyph: "hero-command-line-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :pushed}),
    do: %{glyph: "hero-arrow-up-tray-micro", shape: :round, tone: :info}

  defp node_look(%{kind: :tool, status: :failed}),
    do: %{glyph: "hero-x-mark-micro", shape: :round, tone: :fail}

  defp node_look(%{kind: :tool, status: :open}),
    do: %{glyph: :spinner, shape: :round, tone: :info}

  defp node_look(%{kind: :tool, status: :denied}),
    do: %{glyph: "hero-no-symbol-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :tool, status: :no_end}),
    do: %{glyph: "hero-ellipsis-horizontal-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :tool}),
    do: %{glyph: "hero-code-bracket-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :subagent_started}),
    do: %{glyph: "hero-share-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :subagent_finished}),
    do: %{glyph: "hero-check-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :notification}),
    do: %{glyph: "hero-bell-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :text}),
    do: %{glyph: "hero-bars-3-bottom-left-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :turn_finished}),
    do: %{glyph: "hero-bars-3-bottom-left-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :turn_failed}),
    do: %{glyph: "hero-x-mark-micro", shape: :round, tone: :fail}

  defp node_look(%{kind: :result}), do: %{glyph: "hero-flag-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :session_ended}),
    do: %{glyph: "hero-stop-micro", shape: :round, tone: nil}

  ## Item bodies

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  attr :terminal_path, :any, default: nil
  attr :security, :boolean, default: true

  defp item_body(%{item: %{kind: :run_started}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Run started")}
    >
      {run_started_words(@item)}
    </.head>
    """
  end

  # A reload. What it changed is taken from the allow and deny lists of the two events,
  # which are the record's; the policy tables are not asked. Every host is Forager's
  # string. A deny chip carries the deny mark: a host that came into `deny` is denied from
  # this item on, in either mode.
  defp item_body(%{item: %{kind: :policy_applied, again: true}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={pgettext("plain", "Policy applied again")}
    >
      {gettext("reloaded")} ·
      <%= if @item.was_mode do %>
        <b class="font-semibold text-base-content">{sent(@item.mode) || gettext("n/a")}</b> {gettext(
          "(was %{mode})",
          mode: sent(@item.was_mode)
        )}
      <% else %>
        {sent(@item.mode) || gettext("n/a")}
      <% end %>
      · {hosts_allowed(@item.allowed_hosts)}<span :if={@item.denied_hosts > 0}> · {hosts_denied(
        @item.denied_hosts
      )}</span>
      <:chips :if={@item.delta}>
        <span :for={host <- @item.delta.added} class="q-delta q-delta-add" title={sent(host)}>
          <span aria-hidden="true">+</span><span class="sr-only">{gettext("Added:")}</span>
          <bdi>{middle(
            sent(host),
            48
          )}</bdi>
        </span>
        <span :for={host <- @item.delta.removed} class="q-delta q-delta-del" title={sent(host)}>
          <span aria-hidden="true">−</span><span class="sr-only">{gettext("Removed:")}</span>
          <bdi>{middle(
            sent(host),
            48
          )}</bdi>
        </span>
        <span
          :for={host <- @item.delta.deny_added}
          class="q-delta q-delta-deny q-delta-deny-add"
          title={gettext("Denied from here: %{host}", host: sent(host))}
        >
          <span aria-hidden="true">+</span><.icon name="hero-no-symbol-micro" class="size-3" /><span class="sr-only">{gettext(
            "Deny added:"
          )}</span>
          <bdi>{middle(
            sent(host),
            48
          )}</bdi>
        </span>
        <span
          :for={host <- @item.delta.deny_removed}
          class="q-delta q-delta-deny q-delta-deny-del"
          title={gettext("No longer denied: %{host}", host: sent(host))}
        >
          <span aria-hidden="true">−</span><.icon name="hero-no-symbol-micro" class="size-3" /><span class="sr-only">{gettext(
            "Deny removed:"
          )}</span>
          <bdi>{middle(
            sent(host),
            48
          )}</bdi>
        </span>
        <span :if={delta_more(@item.delta) > 0} class="text-xs text-faint">
          {and_more(delta_more(@item.delta))}
        </span>
      </:chips>
      <:version><.item_version version={@item[:version]} /></:version>
    </.head>
    <p id={"#{@id}-reload"} class="q-reload-say">
      {reload_sentence(@item)}
      <span :if={@item.previous_seq}>
        <.rich
          text={
            rich_pgettext("plain", "Compared with the policy applied at %{sequence}: %{difference}",
              sequence: {:part, :sequence},
              difference: delta_words(@item.delta)
            )
          }
          phx-no-format
        ><:part name={:sequence}><.link patch={@seq_path.(@item.previous_seq)} class="q-link font-mono text-xs">#{pad(@item.previous_seq)}</.link></:part></.rich>
      </span>
      <span :if={@item[:previous_version]}>
        {gettext("Connections before this item were decided by %{version}.",
          version: RunComponents.version_words(@item.previous_version)
        )}
      </span>
    </p>
    """
  end

  defp item_body(%{item: %{kind: :policy_applied}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={pgettext("plain", "Policy applied")}
    >
      <:version><.item_version version={@item[:version]} /></:version>
      {sent(@item.mode) || gettext("n/a")} · {hosts_allowed(@item.allowed_hosts)}<span :if={
        @item.denied_hosts > 0
      }> · {hosts_denied(@item.denied_hosts)}</span>
      · {policy_source(@item.source)}
      <span :if={@item.tools != []} id={"#{@id}-tools"}>
        ·
        <.rich text={rich_gettext("tools %{tools}", tools: {:part, :tools})}>
          <:part name={:tools}>
            <span :for={{tool, i} <- Enum.with_index(@item.tools)}>
              {if i > 0, do: ", "}<.icon
                name="hero-wrench-screwdriver-micro"
                class="q-tool-icon size-3.5"
              /><span class="font-mono text-[12.5px]"><.external_text text={tool.name} /></span><span :if={
                tool[:argument]
              }>{" "}<code
                class="q-rule"
                title={sent(tool.argument)}
              ><bdi>{sent(tool.argument_shown)}</bdi></code></span><span
                :if={tool.hosts != []}
                class="text-faint"
              > ({Enum.map_join(tool.hosts, ", ", &sent/1)})</span>
            </span>
          </:part>
        </.rich>
      </span>
      <span :if={@item.terminated != []}>
        ·
        <.rich text={rich_gettext("reads requests to %{hosts}", hosts: {:part, :hosts})}>
          <:part name={:hosts}>
            <span :for={{host, i} <- Enum.with_index(@item.terminated)}>
              {if i > 0, do: ", "}<span class="font-mono text-[12.5px]"><.external_text text={host} /></span>
            </span>
            <span :if={@item.terminated_count > length(@item.terminated)}>
              {and_more(@item.terminated_count - length(@item.terminated))}
            </span>
          </:part>
        </.rich>
      </span>
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :session_started}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Session started")}
    >
      <span :if={@item.model}><.rich text={rich_gettext("model %{model}", model: {:part, :model})}>
        <:part name={:model}>
          <span class="font-mono text-[12.5px]"><.external_text text={@item.model} /></span>
        </:part>
      </.rich></span>
      <span :if={@item.source}> · <.external_text text={@item.source} /></span>
      <span :if={@item.cwd}> · <span class="font-mono text-[12.5px]"><.external_text text={@item.cwd} /></span></span>
    </.head>
    """
  end

  # The prompt on the label's line, its line breaks as spaces, cut at the row's end.
  defp item_body(%{item: %{kind: :prompt}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Prompt")}
    >
      <bdi>{one_line(@item.text)}</bdi>
    </.head>
    """
  end

  # A text of the session: its first line, without its Markdown marks.
  defp item_body(%{item: %{kind: :text}} = assigns) do
    ~H"""
    <div class="q-hd">
      <span class="q-k">{gettext("Text")}</span>
      <.who :if={@item.who} lane={@item.lane} />
      <span class="q-s q-s-fit"><bdi>{sent(@item.first_line)}</bdi></span>
      <.tail
        item={@item}
        started_at={@started_at}
        seq_path={@seq_path}
        terminal_path={@terminal_path}
      />
    </div>
    """
  end

  # The main agent's row (`Apiary.Runs.Record.Overview`): its calls, in the words of a
  # subagent's head, and the first line of its last text. Its items are not folded under
  # it, so it has no chevron, and its words keep the place of one.
  defp item_body(%{item: %{kind: :main_session}} = assigns) do
    assigns =
      assign(assigns,
        words:
          %{state: :finished, calls: assigns.item.calls}
          |> ApiaryWeb.TranscriptComponents.subagent_words(nil)
          |> String.replace_prefix(" · ", "")
      )

    ~H"""
    <div class="q-hd">
      <span class="q-sub-caret" aria-hidden="true"><span class="size-3"></span></span>
      <span class="q-sub-said">
        <span class="q-k">{gettext("Main session")}</span>{" "}<span class="q-s q-s-fit">{@words}</span>
      </span>
      <span :if={@item[:words]} class="q-s"><bdi>{sent(@item.words)}</bdi></span>
      <.tail
        item={@item}
        started_at={@started_at}
        seq_path={@seq_path}
        terminal_path={@terminal_path}
      />
    </div>
    """
  end

  # A version of an artifact the run pushed: the artifact's type and name, the type alone
  # while it has no name, and the version's number. No event has its place, so it has no
  # event number.
  defp item_body(%{item: %{kind: :pushed}} = assigns) do
    assigns =
      assign(assigns,
        artifact: Enum.join(Enum.reject([assigns.item.type, assigns.item[:name]], &is_nil/1), "/")
      )

    ~H"""
    <div class="q-hd">
      <span class="q-k">{gettext("Pushed")}</span>
      <span class="q-s"><bdi>{gettext("%{artifact} version %{number}",
        artifact: @artifact,
        number: Format.number(@item.number)
      )}</bdi></span>
      <.tail
        item={@item}
        started_at={@started_at}
        seq_path={@seq_path}
        terminal_path={@terminal_path}
      />
    </div>
    """
  end

  # A call that opens has its Terminal link outside the `<summary>`, as a link there would
  # be a control inside a control: the summary keeps an empty place for it, and a line
  # laid over the summary (`q-tool-over`) has the link at that place. That line has the
  # summary's cells before and after the link too, hidden, so that it wraps where the
  # summary wraps.
  #
  # For a reader without the log (no `terminal_path`), a call's input and output are
  # blank (`ApiaryWeb.RunLive.Concealed`): a call with no connection then has nothing to
  # open, and its row is a line with no arrow. A row for a reader of the log, or with
  # input or output to show, opens as before.
  defp item_body(%{item: %{kind: :tool} = item} = assigns) do
    assigns =
      assign(
        assigns,
        :opens,
        is_function(assigns.terminal_path) or item.connections != [] or item.wells != []
      )

    ~H"""
    <div :if={!@opens} id={"#{@id}-tool"} class="q-hd">
      <.tool_head
        item={@item}
        started_at={@started_at}
        seq_path={@seq_path}
        terminal_path={@terminal_path}
      />
    </div>
    <div :if={@opens} class="q-tool-box">
      <details
        id={"#{@id}-tool"}
        class="q-tool"
        open={@item.status == :failed or @item.denied_inside}
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary class="q-hd">
          <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
          <.tool_head
            item={@item}
            started_at={@started_at}
            seq_path={@seq_path}
            terminal_path={@terminal_path}
            in_summary
          />
        </summary>
        <div
          :if={@item.connections != [] or @item.wells != []}
          class={["q-xb", (@item.status == :failed or @item.denied_inside) && "q-xb-bad"]}
        >
          <div :if={@item.connections != []} class="q-during">
            <small>
              {ngettext(
                "%{number} connection while this call was open",
                "%{number} connections while this call was open",
                @item.connections_count,
                number: Format.number(@item.connections_count)
              )}
            </small>
            <.connection_row
              :for={cx <- @item.connections}
              id={"#{@id}-cx-#{cx.sequence}"}
              connection={cx}
              variant="inline"
              started_at={@started_at}
              security={@security}
            />
            <small :if={@item.connections_count > length(@item.connections)}>
              {more_counted(@item.connections_count - length(@item.connections))}
            </small>
          </div>
          <div :if={@item.wells != []} class="q-io">
            <.well :for={well <- @item.wells} well={well} seq={@item.sequence} full={@item.full} />
          </div>
        </div>
      </details>
      <div
        :if={@terminal_path && @item[:terminal_seq]}
        class="q-hd q-tool-over"
      >
        <span class="q-chev size-3" aria-hidden="true"></span>
        <.tool_head
          item={@item}
          started_at={@started_at}
          seq_path={@seq_path}
          terminal_path={@terminal_path}
          over
        />
      </div>
    </div>
    """
  end

  # A subagent's start folded with its items (`fold/3`): the chevron that opens or closes
  # them, the agent type, whether it runs and its calls, in the Transcript's words, and the
  # first line of its last message; how long it ran is in the Took column. A subagent with
  # no items after its start has no chevron, and its words keep their place.
  defp item_body(%{item: %{kind: :subagent_started, sub: %{} = sub}} = assigns) do
    assigns =
      assign(assigns,
        said: "#{assigns.id}-said",
        words:
          sub
          |> ApiaryWeb.TranscriptComponents.subagent_words(nil)
          |> String.replace_prefix(" · ", "")
      )

    ~H"""
    <div class="q-hd">
      <button
        :if={@item.sub.lines > 0}
        type="button"
        class="q-sub-caret"
        phx-click="subagent_toggle"
        phx-value-seq={@item.sequence}
        aria-expanded={to_string(@item.sub.open)}
        aria-labelledby={@said}
      >
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
      </button>
      <span :if={@item.sub.lines == 0} class="q-sub-caret" aria-hidden="true">
        <span class="size-3"></span>
      </span>
      <span id={@said} class="q-sub-said">
        <%!-- The space parts the type from the words in the chevron's name. --%>
        <span class="q-k"><.external_text text={@item.sub.type || @item.agent_type || ""} /></span>{" "}<span class="q-s q-s-fit">{@words}</span>
      </span>
      <span :if={@item[:text]} class="q-s"><bdi>{sent(Timeline.first_line(@item.text))}</bdi></span>
      <.tail
        item={@item}
        started_at={@started_at}
        seq_path={@seq_path}
        terminal_path={@terminal_path}
      />
    </div>
    """
  end

  defp item_body(%{item: %{kind: kind}} = assigns)
       when kind in [:subagent_started, :subagent_finished] do
    ~H"""
    <div class="q-hd">
      <span class="q-k">{if @item.kind == :subagent_started,
        do: gettext("Subagent started"),
        else: gettext("Subagent finished")}</span>
      <.who lane={@item.lane} />
      <span class="q-s font-mono text-xs"><.external_text
        :if={@item.kind == :subagent_started}
        text={@item.agent_id}
      /></span>
      <span :if={@item.kind == :subagent_finished} class="q-s"><bdi>{sent(
        Timeline.first_line(@item.text)
      )}</bdi></span>
      <.tail
        item={@item}
        started_at={@started_at}
        seq_path={@seq_path}
        terminal_path={@terminal_path}
      />
    </div>
    """
  end

  defp item_body(%{item: %{kind: :notification}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Notification")}
    >
      {said([@item.notification_kind, @item.message])}
    </.head>
    """
  end

  # The turn's last message is the text item before it: the row shows the label "Turn
  # finished" and its time, and no text.
  defp item_body(%{item: %{kind: :turn_finished}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Turn finished")}
    />
    """
  end

  defp item_body(%{item: %{kind: :turn_failed}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Turn failed")}
      tone="error"
    >
      {said([@item.error, @item.message])}
    </.head>
    <div :if={@item.wells != []} class="q-xb q-xb-bad">
      <div class="q-io">
        <.well :for={well <- @item.wells} well={well} seq={@item.sequence} full={@item.full} />
      </div>
    </div>
    """
  end

  defp item_body(%{item: %{kind: :result}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Result")}
    >
      {result_words(Map.put(@item, :duration_ms, nil))}
    </.head>
    """
  end

  # The end of a session: the reason the runtime gave, a text the run's report sent, shown
  # as one (`Apiary.ExternalText.present/1`); one with nothing left to show, or only
  # whitespace, is no reason, and the item says nothing after its kind, as without one.
  defp item_body(%{item: %{kind: :session_ended}} = assigns) do
    assigns = assign(assigns, :reason, ExternalText.present(assigns.item.reason))

    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Session ended")}
    >
      <.external_text text={@reason} />
    </.head>
    """
  end

  # Every end of a run: why it ended, in words, else the program's exit. How long it ran is
  # in the Took column.
  defp item_body(%{item: %{kind: :run_exited}} = assigns) do
    {words, signal} = end_words(assigns.item)
    assigns = assign(assigns, words: words, signal: signal)

    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Run ended")}
    >
      {@words}<.external_text text={@signal} />
    </.head>
    """
  end

  # A run refused at its start: the refusal's code as given, an earlier name read as the new
  # one.
  defp item_body(%{item: %{kind: :run_refused}} = assigns) do
    assigns = assign(assigns, :code, RunComponents.refusal_code(assigns.item.code))

    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      kind={gettext("Run did not start")}
    >
      <span :if={@code} class="font-mono">{@code}</span>
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :connection}} = assigns) do
    ~H"""
    <.connection_row
      id={"#{@id}-cx"}
      connection={@item.connection}
      variant="inline"
      started_at={@started_at}
      caption={@item.open_calls > 1 && calls_open(@item.open_calls)}
      security={@security}
    />
    """
  end

  # A run of allowed connections to one destination, folded. The summary's host and tool
  # are texts Forager sent, shown as such (`Apiary.ExternalText`). A host with nothing
  # left to show is marked (`sent/1`), since it was sent, and one never sent reads n/a,
  # as for a connection that sent none (`Apiary.Runs.Record.Timeline`). A tool with
  # nothing left to show, or only whitespace, reads as no tool
  # (`Apiary.ExternalText.present/1`), so the summary leads with the host and counts
  # connections. A group of requests to the run API shows the instance's host, with no
  # port (`Apiary.Runs.RunApi`).
  defp item_body(%{item: %{kind: :connection_group}} = assigns) do
    run_api = Enum.any?(assigns.item.connections, &RunApi.run_api?(&1[:rule]))

    assigns =
      assign(assigns,
        host: if(run_api, do: RunApi.host(), else: sent(assigns.item.host) || gettext("n/a")),
        port: if(run_api, do: nil, else: assigns.item.port),
        tool: ExternalText.present(assigns.item.tool)
      )

    ~H"""
    <details
      id={"#{@id}-group"}
      class="q-tool q-cx-group"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="q-cx-sum">
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
        <span :if={@tool} class="q-dest q-dest-tool">
          <.tool_mark name={@tool} />
          <span class="q-on"><bdi>{@host}</bdi>{@port && ":#{@port}"}</span>
        </span>
        <span :if={!@tool} class="q-dest">
          <bdi>{@host}</bdi><span :if={@port} class="q-port">:{@port}</span>
        </span>
        <span class="text-muted">
          · {if @tool,
            do:
              ngettext(
                "%{number} allowed request",
                "%{number} allowed requests",
                @item.connections_count,
                number: Format.number(@item.connections_count)
              ),
            else:
              ngettext(
                "%{number} allowed connection",
                "%{number} allowed connections",
                @item.connections_count,
                number: Format.number(@item.connections_count)
              )}
          <span :if={@item.open_calls > 1} class="text-faint">· {calls_open(@item.open_calls)}</span>
        </span>
        <span class="q-cx-at ml-auto">
          <.rich text={rich_gettext("%{from} to %{to}", from: {:part, :from}, to: {:part, :to})}>
            <:part name={:from}>
              <.offset
                at={@item.first_at}
                from={@started_at}
              />
            </:part><:part name={:to}><.offset at={@item.last_at} from={@started_at} /></:part>
          </.rich>
        </span>
      </summary>
      <div class="q-xb">
        <div class="q-during">
          <.connection_row
            :for={cx <- @item.connections}
            id={"#{@id}-cx-#{cx.sequence}"}
            connection={cx}
            variant="inline"
            started_at={@started_at}
            security={@security}
          />
          <small :if={@item.connections_count > length(@item.connections)}>
            {more_counted(@item.connections_count - length(@item.connections))}
          </small>
        </div>
      </div>
    </details>
    """
  end

  # What is not known stays out of the sentence. The runtime comes with the first session and
  # the host is absent from a run with a run key outside a pool. `run.started` has no `wall`
  # when the run has none, so without a `wall` the run has no wall. A bare runtime has no
  # version, so `%{runtime}` is the runtime and its version, joined by `runtime_words/1`.
  defp run_started_words(item) do
    case {runtime_words(item), sent(item.host), sent(item.wall)} do
      {nil, nil, _wall} ->
        nil

      {nil, host, nil} ->
        gettext("on %{host}, without a wall", host: host)

      {nil, host, wall} ->
        gettext("on %{host}, behind a %{wall} wall", host: host, wall: wall)

      {runtime, nil, nil} ->
        gettext("%{runtime}, without a wall", runtime: runtime)

      {runtime, nil, wall} ->
        gettext("%{runtime}, behind a %{wall} wall", runtime: runtime, wall: wall)

      {runtime, host, nil} ->
        gettext("%{runtime} on %{host}, without a wall", runtime: runtime, host: host)

      {runtime, host, wall} ->
        gettext("%{runtime} on %{host}, behind a %{wall} wall",
          runtime: runtime,
          host: host,
          wall: wall
        )
    end
  end

  defp runtime_words(%{runtime: nil}), do: nil

  defp runtime_words(item) do
    [item.runtime, item.runtime_version]
    |> Enum.map(&sent/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp hosts_allowed(n),
    do: ngettext("%{number} host allowed", "%{number} hosts allowed", n, number: Format.number(n))

  defp hosts_denied(n),
    do: ngettext("denies %{number} host", "denies %{number} hosts", n, number: Format.number(n))

  defp more_counted(n) do
    ngettext(
      "%{number} more is counted on the Network access tab.",
      "%{number} more are counted on the Network access tab.",
      n,
      number: Format.number(n)
    )
  end

  defp calls_open(n),
    do:
      ngettext("while %{number} call was open", "while %{number} calls were open", n,
        number: Format.number(n)
      )

  ## The head row

  # A tool call's head row: its tool, agent, summary, state and times. A call with
  # connections inside was the only open call when each of them was made
  # (`Apiary.Runs.Record.Timeline`).
  #
  # With `over`, the cells of the line laid over a summary that set where its Terminal
  # link wraps: the summary's words and note are on lines after it, so they are left out.
  # Each cell is `aria-hidden`, as a screen reader reads it in the summary.
  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  attr :terminal_path, :any, default: nil
  attr :in_summary, :boolean, default: false
  attr :over, :boolean, default: false

  defp tool_head(assigns) do
    assigns = assign(assigns, :hide, assigns.over && "true")

    ~H"""
    <span class="q-k q-k-mono" aria-hidden={@hide}><.external_text text={@item.tool} /></span>
    <.who :if={@item.who} lane={@item.lane} aria-hidden={@hide} />
    <span :if={!@over} class="q-s q-s-mono"><.external_text text={@item.summary} /></span>
    <span :if={!@over and @item.connections_count > 0} class="q-only-open">
      {ngettext(
        "only open call at a connection",
        "only open call at %{number} connections",
        @item.connections_count,
        number: Format.number(@item.connections_count)
      )}
    </span>
    <.badge :if={@item.in_background and !@over} color="info" class="self-center">
      {gettext("In background")}
    </.badge>
    <span :if={@item.in_background and @over} class="flex self-center" aria-hidden="true">
      <.badge color="info">{gettext("In background")}</.badge>
    </span>
    <.tail
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      terminal_path={@terminal_path}
      in_summary={@in_summary}
      over={@over}
    >
      <span :if={@item.status == :failed} class="q-bad" aria-hidden={@hide}>{if @item.interrupted,
        do: gettext("Interrupted"),
        else: gettext("Failed")}</span>
      <span :if={@item.status == :open} class="q-running" aria-hidden={@hide}>{gettext("Running")}</span>
      <span :if={@item.status == :no_end} class="q-no-end" aria-hidden={@hide}>{gettext(
        "No end recorded"
      )}</span>
      <span :if={@item.status == :denied} class="q-no-end" aria-hidden={@hide}>{gettext(
        "Not run: denied"
      )}</span>
    </.tail>
    """
  end

  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  attr :terminal_path, :any, default: nil
  attr :kind, :string, required: true
  attr :tone, :string, default: nil
  slot :inner_block
  slot :chips, doc: "after the summary: the delta of a reload"
  slot :version, doc: "before the offset: the version link of a policy applied"

  defp head(assigns) do
    ~H"""
    <div class="q-hd">
      <span class={["q-k", @tone == "error" && "q-bad"]}>{@kind}</span>
      <.who :if={@item.who} lane={@item.lane} />
      <span class="q-s">{render_slot(@inner_block)}</span>
      {render_slot(@chips)}
      <.tail item={@item} started_at={@started_at} seq_path={@seq_path} terminal_path={@terminal_path}>
        {render_slot(@version)}
      </.tail>
    </div>
    """
  end

  attr :version, :any, default: nil, doc: "%{n, path} when the digest names a version here"

  # The version a policy applied names, when this workspace rendered it: the version link.
  defp item_version(%{version: %{n: _, path: _}} = assigns) do
    ~H"""
    <RunComponents.scoped_version version={@version} class="q-pv" />
    """
  end

  defp item_version(assigns), do: ~H""

  # "New" is said only of a digest that is not the one before it.
  defp reload_sentence(%{source: "fetched", digest: digest, previous_digest: previous})
       when is_binary(digest) and digest != previous do
    gettext(
      "The gateway fetched a new run configuration after Qory Apiary's answer named a new digest."
    )
  end

  defp reload_sentence(%{source: "fetched"}),
    do: gettext("The gateway fetched its run configuration again; the digest is the one it had.")

  defp reload_sentence(_item), do: pgettext("plain", "The gateway applied a policy again.")

  defp delta_more(delta) do
    delta.added_count - length(delta.added) + (delta.removed_count - length(delta.removed)) +
      (delta.deny_added_count - length(delta.deny_added)) +
      (delta.deny_removed_count - length(delta.deny_removed))
  end

  defp delta_words(nil), do: gettext("the lists are too long to compare here.")

  defp delta_words(delta) do
    same? = delta.added_count == 0 and delta.removed_count == 0
    denies? = delta.deny_added_count != 0 or delta.deny_removed_count != 0

    bindings = [
      added: hosts_words(delta.added_count),
      removed: hosts_or_none(delta.removed_count),
      deny_added: hosts_words(delta.deny_added_count),
      deny_removed: hosts_or_none(delta.deny_removed_count)
    ]

    case {same?, denies?} do
      {true, false} ->
        gettext("the same hosts are allowed.")

      {true, true} ->
        gettext(
          "the same hosts are allowed; denies %{deny_added} more and %{deny_removed} fewer.",
          deny_added: bindings[:deny_added],
          deny_removed: bindings[:deny_removed]
        )

      {false, false} ->
        gettext("%{added} added, %{removed} removed.",
          added: bindings[:added],
          removed: bindings[:removed]
        )

      {false, true} ->
        gettext(
          "%{added} added, %{removed} removed; denies %{deny_added} more and %{deny_removed} fewer.",
          bindings
        )
    end
  end

  defp hosts_words(0), do: gettext("no host")

  defp hosts_words(n),
    do: ngettext("%{number} host", "%{number} hosts", n, number: Format.number(n))

  defp hosts_or_none(0), do: gettext("none")
  defp hosts_or_none(n), do: hosts_words(n)

  # A row's end: its link to the Terminal, its time, how long it took and its number, the
  # permalink. Inside a `<summary>` neither is a link, since a link there would be a
  # control inside a control: the number is text with the path in `data-href`, which the
  # timeline's `c` copies, and the Terminal link's place is kept empty for the link laid
  # over it (`over`). A row with no event, a Pushed row, has an empty number cell.
  #
  # With `over`, the end is that line laid over a summary: the cells before the Terminal
  # link, the link, then the cells after it; all but the link hidden, which put the link
  # where the summary keeps its place.
  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  attr :terminal_path, :any, default: nil
  attr :in_summary, :boolean, default: false
  attr :over, :boolean, default: false
  slot :inner_block

  defp tail(assigns) do
    assigns =
      assign(assigns,
        took: took(assigns.item),
        numbered: is_integer(assigns.item.sequence),
        linked: is_function(assigns.terminal_path) and is_integer(assigns.item[:terminal_seq])
      )

    ~H"""
    <span class="q-t">
      {render_slot(@inner_block)}
      <span :if={@linked and @in_summary} class="q-to-term q-to-term-place" aria-hidden="true">
        {gettext("Terminal")} <span>›</span>
      </span>
      <.link
        :if={@linked and !@in_summary}
        patch={@terminal_path.(@item.terminal_seq)}
        class="q-to-term"
        aria-label={gettext("Show this in the Terminal")}
      >
        {gettext("Terminal")} <span aria-hidden="true">›</span>
      </.link>
      <.offset at={@item.time} from={@started_at} class="q-t-at q-tc1" />
      <span class="q-tct">
        <.duration :if={@took} ms={@took} precise={@item.kind == :tool} class="q-d" />
      </span>
      <span :if={!@numbered} class="q-tc2"></span>
      <span :if={@numbered and @over} class="q-q q-tc2">#{pad(@item.sequence)}</span>
      <span
        :if={@numbered and @in_summary}
        class="q-q q-tc2"
        data-permalink
        data-href={@seq_path.(@item.sequence)}
      >#{pad(@item.sequence)}</span>
      <.link
        :if={@numbered and !@in_summary and !@over}
        patch={@seq_path.(@item.sequence)}
        class="q-q q-tc2"
        tabindex="-1"
        data-permalink
      >#{pad(@item.sequence)}</.link>
    </span>
    """
  end

  # How long a row took, in its Took column: a tool call, a subagent, the main agent's
  # session, a result, and the run. No other row has a duration.
  @took [:tool, :subagent_started, :subagent_finished, :main_session, :result, :run_exited]

  defp took(%{kind: kind, duration_ms: ms}) when kind in @took and is_integer(ms), do: ms

  defp took(_item), do: nil

  # A text of several lines on one line: each run of whitespace a space.
  defp one_line(text) when is_binary(text),
    do: text |> sent_lines() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp one_line(_text), do: nil

  ## Code wells

  attr :well, :map, required: true
  attr :seq, :integer, required: true
  attr :full, :boolean, default: false

  defp well(assigns) do
    ~H"""
    <div class={["q-well", @well.tone == :error && "q-well-err"]}>
      <div>
        <span>{@well.label}</span>
        <span>{well_size(@well)}</span>
      </div>
      <pre :if={@well.format == :json} tabindex="0" phx-no-format><%= for {indent, key, rest} <- json_lines(ExternalText.lines(@well.text)) do %>{indent}<span :if={key} class="q-key">{key}</span>{rest}{"\n"}<% end %><.show_all :if={@well.cut} seq={@seq} bytes={@well.bytes} /></pre>
      <pre :if={@well.format == :text} tabindex="0" phx-no-format>{sent_lines(@well.text)}<.show_all :if={@well.cut} seq={@seq} bytes={@well.bytes} /></pre>
    </div>
    """
  end

  attr :seq, :integer, required: true
  attr :bytes, :integer, required: true

  @doc false
  def show_all(assigns) do
    ~H"""
    <button type="button" class="q-show-all" phx-click="show_all" phx-value-seq={@seq}>{gettext(
      "Show all %{size}",
      size: Format.bytes(@bytes)
    )}</button>
    """
  end

  # A line of pretty JSON as {indent, key or nil, rest}: the key is what the accent marks.
  # The text stays text; this only says where a key ends.
  @doc false
  def json_lines(text) do
    for line <- String.split(text, "\n") do
      case Regex.run(~r/\A(\s*)("(?:[^"\\]|\\.)*")(:.*)\z/s, line) do
        [_, indent, key, rest] -> {indent, key, rest}
        _ -> {"", nil, line}
      end
    end
  end

  defp well_size(%{lines: lines, bytes: bytes}) when is_integer(lines),
    do:
      gettext("%{size} · %{lines}",
        size: Format.bytes(bytes),
        lines: ngettext("%{number} line", "%{number} lines", lines, number: Format.number(lines))
      )

  defp well_size(%{bytes: bytes}), do: Format.bytes(bytes)

  ## Words

  defp policy_source("fetched"), do: gettext("fetched from the run configuration")
  defp policy_source("config"), do: gettext("given to Forager as a policy document")
  defp policy_source("none"), do: gettext("no policy, every connection is observed")
  defp policy_source(_other), do: gettext("source n/a")

  @doc "The source of a policy in words, for Details too."
  def policy_source_words(source), do: policy_source(source)

  # How the run ended, as `{words, signal}`, at most one of them set: why, in words
  # (`RunComponents.reason_words/1`), else the program's signal, else its exit code. The
  # signal is a text the run's report sent, shown as one (`Apiary.ExternalText.present/1`):
  # one with nothing left to show, or only whitespace, is no signal. `-1` with no signal is
  # the gateway's placeholder for an exit it wrote, not the program's, and an exit with
  # neither has none: nothing is said of either.
  defp end_words(item) do
    words = RunComponents.reason_words(item)
    signal = if is_nil(words), do: ExternalText.present(Map.get(item, :signal))

    cond do
      words -> {words, nil}
      signal -> {nil, signal}
      true -> {exit_code_words(item), nil}
    end
  end

  defp exit_code_words(%{exit_code: code}) when is_integer(code) and code != -1,
    do: gettext("exit %{code}", code: code)

  defp exit_code_words(_item), do: nil

  @doc "A result's head, `success · 6 turns · 14 s · $0.09`: what is known of it."
  def result_words(item) do
    [
      sent(item.outcome),
      item.turns &&
        ngettext("%{number} turn", "%{number} turns", item.turns,
          number: Format.number(item.turns)
        ),
      item.duration_ms && ApiaryWeb.RunComponents.format_duration_ms(item.duration_ms),
      item.cost_usd && cost(item.cost_usd)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  # A text the run's report sent, as the timeline shows it (`Apiary.ExternalText.sent/1`):
  # marked where nothing is left of it, since it was sent; nil where it sent none or an
  # empty text. A value that is no text is shown as it is.
  defp sent(text) when is_binary(text), do: ExternalText.sent(text)
  defp sent(text), do: text

  # The same for a text of several lines, which keeps its tabs and line breaks
  # (`Apiary.ExternalText.present_lines/1`).
  @doc false
  def sent_lines(text) when is_binary(text) and text != "",
    do: ExternalText.present_lines(text) || ExternalText.marked(text)

  def sent_lines(_text), do: nil

  # The texts an item said, each as `sent/1` shows it, joined by a middle dot.
  defp said(texts), do: texts |> Enum.map(&sent/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  # Two places, four when under a cent.
  defp cost(usd) when usd < 0.01, do: "$" <> Format.number(usd / 1, digits: 4)
  defp cost(usd), do: "$" <> Format.number(usd / 1, digits: 2)

  @doc "A sequence as the page writes it: four digits at least."
  def pad(sequence) when is_integer(sequence),
    do: sequence |> Integer.to_string() |> String.pad_leading(4, "0")

  def pad(_sequence), do: gettext("n/a")

  ## P6. The live end

  @doc """
  Under the last item: listening while the run is alive, the end of the record after.

  It has the `LiveEnd` hook (`assets/js/hooks/live_end.js`), outside the timeline's stream:
  LiveView locks a hook's element until the acknowledgement of the hook's event arrives,
  and a stream patched inside a locked element appends its new rows at the end of the list.
  """
  attr :live, :boolean, required: true
  attr :events, :integer, required: true
  attr :last_sequence, :integer, default: nil
  attr :last_event_at, :any, default: nil

  def live_end(%{live: true} = assigns) do
    ~H"""
    <p id="live-end" class="q-tail" phx-hook="LiveEnd">
      <span class="listening-dot mx-1" aria-hidden="true" />
      <span>
        {gettext("Listening for the next batch.")}
        <span :if={@last_sequence && !@last_event_at}>
          {gettext("Last event #%{sequence}.", sequence: pad(@last_sequence))}
        </span>
        <span :if={@last_sequence && @last_event_at}>
          <.rich
            text={
              rich_gettext("Last event #%{sequence}, %{time} ago.",
                sequence: pad(@last_sequence),
                time: {:part, :time}
              )
            }
            phx-no-format
          ><:part name={:time}><time data-tick="seconds" data-time-zone={Format.time_zone()} data-since={DateTime.to_iso8601(@last_event_at)} aria-live="off">{ApiaryWeb.RunComponents.format_seconds(max(DateTime.diff(DateTime.utc_now(), @last_event_at), 0))}</time></:part></.rich>
        </span>
      </span>
    </p>
    """
  end

  def live_end(assigns) do
    ~H"""
    <p id="live-end" class="q-tail" phx-hook="LiveEnd">
      {gettext("End of the record.")} {ngettext("%{number} event.", "%{number} events.", @events,
        number: Format.number(@events)
      )}
    </p>
    """
  end

  ## Terminal

  @doc """
  The words the log's script says (`assets/js/hooks/terminal.js`), in the domain's
  language, so the script holds none. A count's words are `[one, other]` with `%{number}`
  to fill: the script takes `one` for 1 and `other` for any other count, which is the
  plural rule of English and of the languages like it.
  """
  def terminal_words do
    %{
      log:
        forms(fn n ->
          ngettext("Log, %{number} line", "Log, %{number} lines", n, number: "%{number}")
        end),
      input:
        forms(fn n ->
          ngettext(
            "Log, %{number} line, read only. Slash searches, Enter and Shift Enter move between matches, Escape clears, End follows the output, Home goes to the start. The link before this box opens the log as text.",
            "Log, %{number} lines, read only. Slash searches, Enter and Shift Enter move between matches, Escape clears, End follows the output, Home goes to the start. The link before this box opens the log as text.",
            n,
            number: "%{number}"
          )
        end),
      newLines:
        forms(fn n ->
          ngettext("%{number} new line", "%{number} new lines", n, number: "%{number}")
        end),
      following: gettext("Following"),
      jumpToEnd: gettext("Jump to end"),
      found: gettext("%{index} of %{total}", index: "%{index}", total: "%{total}"),
      notLoaded: gettext("The log could not be loaded."),
      dropped: gettext("The log stream dropped. Reconnecting."),
      size: gettext("%{size} px", size: "%{size}"),
      bytes: gettext("%{number} B", number: "%{number}"),
      kilobytes: gettext("%{number} kB", number: "%{number}"),
      megabytes: gettext("%{number} MB", number: "%{number}"),
      fullScreen: gettext("Full screen"),
      leaveFullScreen: gettext("Leave full screen")
    }
  end

  defp forms(say), do: [say.(1), say.(2)]

  @doc """
  The terminal box: dark in both themes. It fills the window below the run page's tab bar,
  never under 380 px. It has two views: the Transcript (`transcript`, the LiveView's,
  `ApiaryWeb.TranscriptComponents`) and Raw, the log's bytes. The bar and Raw's screen
  belong to the `Terminal` hook (`phx-update="ignore"`); the foot is the LiveView's, which
  sends numbers and never bytes. The hook reads the log from `src` and asks again when the
  LiveView says the log has advanced. The view is the root's `data-view`, set from `view`
  on the first render and by the hook after it.

  `cols` and `rows` are the pseudo-terminal's size as the record last said it, or nil for
  a run on pipes. With a size the hook replays at the recorded size, each answer of `src`
  at the size its bytes were written to: the recorded columns are kept, drawn inside the
  box's dark ground, which fills the page's width. Without one it fits the screen to
  the box and offers to wrap.

  The bar's controls are the hook's, in two parts with `phx-update="ignore"`, with the
  `subagents` slot, drawn by the LiveView, between them. The bar: the view (Transcript or Raw, when the run
  has a Transcript and a log; on pipes the reader's preference kept in `localStorage`),
  the subagents' controls (Transcript only), the stream (Raw only), search, follow and
  wrap (on pipes; both Raw only), the text size (A−, A+ and, at a recorded size, Fit;
  11 to 18 px, the reader's preference kept in `localStorage`), the download, Focus (`f`:
  the terminal takes the window; Escape leaves) and Full screen (the browser's, where it
  has one). Without a log (`raw` false) the box has the Transcript alone.
  """
  attr :id, :string, required: true
  attr :src, :string, required: true
  attr :script, :string, required: true, doc: "the terminal bundle, loaded on first mount"
  attr :stylesheet, :string, required: true
  attr :streams, :list, required: true
  attr :live, :boolean, required: true
  attr :bytes, :integer, required: true
  attr :chunks, :integer, required: true
  attr :through, :integer, required: true
  attr :cols, :integer, default: nil
  attr :rows, :integer, default: nil
  attr :raw, :boolean, default: true, doc: "whether the log is there to show in Raw"
  attr :view, :string, default: "raw", doc: ~s("transcript" or "raw": the view it opens in)
  slot :transcript, doc: "the Transcript; none for a run with no runtime events"

  slot :subagents,
    doc:
      "the Transcript's controls of its subagents, in the bar after the view, drawn by the LiveView"

  def terminal(assigns) do
    pty = assigns.streams == ["terminal"]

    assigns =
      assign(assigns,
        sized: is_integer(assigns.cols) and is_integer(assigns.rows),
        pty: pty,
        both: assigns.raw and assigns.transcript != [],
        # A pseudo-terminal run opens in Raw, where its screen is.
        opening:
          cond do
            not assigns.raw -> "transcript"
            assigns.transcript == [] or pty -> "raw"
            true -> assigns.view
          end
      )

    ~H"""
    <div
      id={@id}
      class="q-termbox"
      role="region"
      aria-label={gettext("Terminal output")}
      phx-hook="Terminal"
      phx-mounted={JS.ignore_attributes(["data-view", "data-tr-wrap", "style"])}
      data-view={@opening}
      data-raw={to_string(@raw)}
      data-src={@src}
      data-script={@script}
      data-stylesheet={@stylesheet}
      data-live={to_string(@live)}
      data-pty={to_string(@pty)}
      data-through={@through}
      data-sized={to_string(@sized)}
      data-cols={@sized && @cols}
      data-rows={@sized && @rows}
      data-words={Jason.encode!(terminal_words())}
    >
      <div id={"#{@id}-bar"} class="q-term-bar">
        <div id={"#{@id}-bar-view"} class="contents" phx-update="ignore">
          <a
            :if={@raw}
            class="sr-only focus:not-sr-only q-tbtn"
            href={@src <> "?download=1"}
            download
          >
            {gettext("Read the log as text")}
          </a>
          <div :if={@both} class="q-tseg q-tview" role="group" aria-label={gettext("Log view")}>
            <button type="button" data-view-button="transcript" aria-pressed="false">
              {gettext("Transcript")}
            </button>
            <button type="button" data-view-button="raw" aria-pressed="false">{gettext("Raw")}</button>
          </div>
          <div :if={@raw} class="q-tseg q-term-raw" role="group" aria-label={gettext("Stream")}>
            <%= if length(@streams) > 1 do %>
              <button
                :for={stream <- @streams}
                type="button"
                data-stream={stream}
                aria-pressed="false"
              >
                {stream}
              </button>
              <button type="button" data-stream="" aria-pressed="true">{gettext("both")}</button>
            <% else %>
              <span class="q-tseg-one">{List.first(@streams) || gettext("terminal")}</span>
            <% end %>
          </div>
          <label :if={@raw} class="q-term-find">
            <.icon name="hero-magnifying-glass-micro" class="size-4" />
            <span class="sr-only">
              {if @both,
                do: gettext("Search the log. Searching shows the Raw view."),
                else: gettext("Search the log")}
            </span>
            <input
              type="text"
              data-find
              spellcheck="false"
              autocomplete="off"
              placeholder={gettext("Search the log")}
            />
            <span data-find-count aria-live="polite"></span>
          </label>
        </div>
        <div :if={@subagents != []} id={"#{@id}-subagents"} class="q-term-trv q-term-subs">
          {render_slot(@subagents)}
        </div>
        <div id={"#{@id}-bar-tools"} class="contents" phx-update="ignore">
          <span class="q-term-grow"></span>
          <span :if={@raw} class="q-term-hint q-term-raw">
            <.rich text={rich_gettext("%{key} leaves focus", key: {:part, :key})}>
              <:part name={:key}><kbd>{gettext("esc")}</kbd></:part>
            </.rich>
          </span>
          <button
            :if={@raw}
            type="button"
            class="q-tbtn q-term-raw"
            aria-pressed={to_string(@live)}
            title={gettext("Follow the end of the log (End)")}
            data-follow
          >
            <.icon name="hero-arrow-down-micro" class="size-4" />
            <span class="q-tbtn-lbl" data-follow-label>{if @live,
              do: gettext("Following"),
              else: gettext("Jump to end")}</span>
          </button>
          <button
            :if={!@sized and @raw}
            type="button"
            class="q-tbtn q-term-raw"
            title={gettext("Wrap long lines")}
            aria-pressed="false"
            data-wrap
          >
            <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
            <span class="q-tbtn-lbl">{gettext("Wrap")}</span>
          </button>
          <%!-- The Transcript's: its end, and whether a tool's line and its result wrap. --%>
          <button
            :if={@transcript != []}
            type="button"
            class="q-tbtn q-term-trv"
            aria-pressed={to_string(@live)}
            title={gettext("Follow the end of the log (End)")}
            data-tr-end
          >
            <.icon name="hero-arrow-down-micro" class="size-4" />
            <span class="q-tbtn-lbl" data-tr-end-label>{if @live,
              do: gettext("Following"),
              else: gettext("Jump to end")}</span>
          </button>
          <button
            :if={@transcript != []}
            type="button"
            class="q-tbtn q-term-trv"
            title={gettext("Wrap long lines")}
            aria-pressed="false"
            data-tr-wrap
          >
            <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
            <span class="q-tbtn-lbl">{gettext("Wrap")}</span>
          </button>
          <span class="q-term-sep" aria-hidden="true"></span>
          <div class="q-term-sizes" role="group" aria-label={gettext("Text size")}>
            <button
              type="button"
              class="q-tbtn"
              title={gettext("Smaller text")}
              aria-label={gettext("Smaller text")}
              data-size-step="-1"
            >
              {gettext("A−")}
            </button>
            <span class="q-term-px" data-size-label aria-live="polite"></span>
            <button
              type="button"
              class="q-tbtn"
              title={gettext("Larger text")}
              aria-label={gettext("Larger text")}
              data-size-step="1"
            >
              {gettext("A+")}
            </button>
            <button
              :if={@sized and @raw}
              type="button"
              class="q-tbtn q-term-raw"
              title={gettext("Fit the recorded columns to the width")}
              aria-pressed="false"
              data-size-fit
            >
              {gettext("Fit")}
            </button>
          </div>
          <span :if={@raw} class="q-term-sep" aria-hidden="true"></span>
          <a
            :if={@raw}
            class="q-tbtn"
            title={gettext("Download the raw bytes")}
            aria-label={gettext("Download the raw bytes")}
            href={@src <> "?download=1"}
            download
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-4" />
            <span class="q-tbtn-lbl" aria-hidden="true">{gettext("Download")}</span>
          </a>
          <button
            type="button"
            class="q-tbtn"
            title={gettext("Focus: the terminal takes the window (f)")}
            aria-pressed="false"
            aria-keyshortcuts="f"
            data-focus
          >
            <.icon name="hero-arrows-pointing-in-micro" class="size-4" />
            <span class="q-tbtn-lbl">{gettext("Focus")}</span>
          </button>
          <button
            type="button"
            class="q-tbtn"
            title={gettext("Full screen")}
            aria-label={gettext("Full screen")}
            aria-pressed="false"
            data-fullscreen
            hidden
          >
            <.icon name="hero-arrows-pointing-out-micro" class="size-4" />
          </button>
        </div>
      </div>
      <div
        :if={@transcript != []}
        id={"#{@id}-transcript"}
        class="q-term-tr"
        data-transcript-scroll
        tabindex="0"
      >
        {render_slot(@transcript)}
      </div>
      <div :if={@raw} id={"#{@id}-screen"} class="q-term-screen" phx-update="ignore">
        <div data-screen role="log" aria-live="off" aria-label={gettext("Log")}></div>
        <span class="sr-only" data-announce aria-live="polite"></span>
        <button type="button" class="q-newpill q-term-pill" data-pill tabindex="-1" aria-hidden="true">
          <.icon name="hero-arrow-down-micro" class="size-4" />
          <span data-pill-text>{gettext("New lines")}</span>
        </button>
        <div class="q-term-msg" data-message hidden>
          <p data-message-text></p>
          <button type="button" class="q-tbtn" data-retry hidden>{gettext("Try again")}</button>
        </div>
      </div>
      <div class="q-term-foot">
        <span :if={@live} class="q-term-live"><i></i>{gettext("Live")}</span>
        <span :if={!@live}>{gettext("Ended")}</span>
        <span :if={@raw}>{Format.bytes(@bytes)}</span>
        <span :if={@raw} class="q-term-opt">
          {ngettext("%{number} chunk", "%{number} chunks", @chunks, number: Format.number(@chunks))}
        </span>
        <span :if={@raw} class="q-term-opt">
          {gettext("through #%{sequence}", sequence: pad(@through))}
        </span>
        <span
          :if={@sized}
          class="q-term-size"
          title={gettext("The size the runtime ran at")}
          data-size
        >
          {@cols}×{@rows}
        </span>
      </div>
    </div>
    <p :if={@raw} class="q-term-note">
      {if @sized,
        do:
          gettext(
            "The bytes as the runtime wrote them, terminal escapes included, drawn at the columns they were recorded at. Nothing here is interpreted; the timeline is where the session is read."
          ),
        else:
          gettext(
            "The bytes as the runtime wrote them, terminal escapes included, fitted to this box. Nothing here is interpreted; the timeline is where the session is read."
          )}
    </p>
    """
  end

  ## About

  # What the run said it is about (`about` of its `run.started`, as `Apiary.Runs.Fold`
  # kept it). A subject is its type and ref as given, "ticket 412": Qory knows no
  # subject types. Its url is a link out only when it may be one (`external_link/1`). The
  # kind, a subject's type, ref and title, and the details' keys and values are texts the
  # run's report sent, shown as such (`Apiary.ExternalText`): a kind or a title with nothing
  # left to show, or only whitespace, is none, and what shows it is left out.

  @header_subjects 3

  @doc """
  The header's line under the title: the run's work item, as the runs list shows it
  (`ApiaryWeb.RunComponents.work_item_name/1`); the kind; then the first three subjects,
  each a link out with its title and its url's host as the tooltip (`subject_tip/1`), then
  how many more there are (all of them are in the rail's About). The subject of the work
  item, `work_item` and its public id, is left out here: the work item is first. Nothing
  when the run has no work item, no kind and no subject.
  """
  attr :run, :map, required: true
  attr :scope, :map, default: nil

  attr :work_item, :map,
    default: nil,
    doc: "the run's work item, as `Apiary.Runs.list_facts/2` reads it, or nil"

  attr :work_item_link, :boolean,
    default: false,
    doc: "whether the work item is a link to its page"

  def about_header(assigns) do
    subjects =
      for subject <- assigns.run.about_subjects || [],
          not work_item_subject?(subject, assigns.work_item),
          do: subject

    subjects = shown_subjects(subjects)

    assigns =
      assign(assigns,
        kind: ExternalText.present(assigns.run.about_kind),
        subjects: Enum.take(subjects, @header_subjects),
        more: max(length(subjects) - @header_subjects, 0)
      )

    ~H"""
    <p :if={@work_item || @kind || @subjects != []} id="run-about" class="q-run-about">
      <.work_item_name
        :if={@work_item}
        id="run-work-item"
        scope={@scope}
        work_item={@work_item}
        link={@work_item_link}
        link_class="q-run-wi"
      >
        <.icon name="hero-rectangle-stack-micro" class="size-3.5 align-[-2px]" />
      </.work_item_name>
      <span :if={@kind} id="run-about-kind"><.external_text text={@kind} /></span>
      <span :for={subject <- @subjects}>
        <.external_link href={subject["url"]} title={subject_tip(subject)}>
          <.subject_name subject={subject} />
        </.external_link>
      </span>
      <span :if={@more > 0} id="run-about-more">
        {ngettext("+%{number} more", "+%{number} more", @more, number: Format.number(@more))}
      </span>
    </p>
    """
  end

  # The subject a run of a work item reports for it: the type `work_item` and the work
  # item's public id (`Apiary.Dispatches.Handover`).
  defp work_item_subject?(%{"type" => "work_item", "ref" => ref}, %{public_id: ref})
       when is_binary(ref),
       do: true

  defp work_item_subject?(_subject, _work_item), do: false

  @doc """
  The rail's About, its first section: the kind; each subject, a link out with its title
  muted under it, cut to a line and whole in its tooltip; then the details, a mono row
  each (`about_details/1`). Nothing when the run names no kind, subject or detail; the
  title is the page's h1, and not repeated here.
  """
  attr :run, :map, required: true

  def about_section(assigns) do
    assigns =
      assign(assigns,
        kind: ExternalText.present(assigns.run.about_kind),
        subjects: shown_subjects(assigns.run.about_subjects),
        details: about_details(assigns.run.about_details)
      )

    ~H"""
    <section
      :if={@kind || @subjects != [] || @details != []}
      id="run-about-section"
      class="q-rail-sec"
      aria-labelledby="rail-about"
    >
      <h3 id="rail-about">{gettext("About")}</h3>
      <dl :if={@kind || @subjects != []} id="run-about-facts" class="q-rail-kv q-rail-about">
        <dt :if={@kind}>{gettext("Kind")}</dt>
        <dd :if={@kind}><.external_text text={@kind} /></dd>
        <dt :if={@subjects != []}>{gettext("Subjects")}</dt>
        <dd :for={subject <- @subjects} class="q-rail-subj">
          <.external_link href={subject["url"]} title={subject_tip(subject)}>
            <.subject_name subject={subject} />
          </.external_link>
          <span :if={subject["title"]} class="q-rail-sub" title={subject["title"]}>
            <.external_text text={subject["title"]} />
          </span>
        </dd>
      </dl>
      <dl
        :if={@details != []}
        id="run-about-details"
        class="q-rail-kv q-rail-kv-mono q-rail-about-details"
      >
        <%= for {key, value, form} <- @details do %>
          <%!-- A dotted key may break before each of its dots. A value wraps, never cut:
               text at its spaces, compact JSON anywhere. --%>
          <dt phx-no-format><%= for {part, index} <- Enum.with_index(String.split(key, ".")) do %><wbr :if={index > 0} />{if index > 0, do: "."}{part}<% end %></dt>
          <dd class={form == :json && "q-rail-json"}><.external_text text={value} /></dd>
        <% end %>
      </dl>
    </section>
    """
  end

  @doc """
  The details as `{key, value, form}` rows, by key. A top-level member is a row; one that
  is a non-empty object is instead a row per member of that object, keyed `outer.inner`, so a
  key has at most two segments. A value is shown as given when it is a string (`:text`),
  and as compact JSON otherwise (`:json`): a number, true, false, null, an array, and an
  object one level below that, or an empty one. An object nested deeper stays one JSON
  value, never more rows. A key and a value, JSON included, are shown as a text the run's
  report sent is (`Apiary.ExternalText.line/1`).
  """
  def about_details(%{} = details) do
    details
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn
      {key, %{} = inner} when map_size(inner) > 0 ->
        inner
        |> Enum.sort_by(fn {inner_key, _value} -> inner_key end)
        |> Enum.map(fn {inner_key, value} -> row("#{key}.#{inner_key}", value) end)

      {key, value} ->
        [row(key, value)]
    end)
  end

  def about_details(_details), do: []

  defp row(key, value) do
    {shown, form} = detail(value)
    {ExternalText.line(key), ExternalText.line(shown), form}
  end

  # The subjects as a page shows them: a type and a ref as a line each, and a title as a
  # line, or none where it has nothing left to show (`Apiary.ExternalText`). The url stays
  # as given: it is a link's address, not a text shown, and only a url that may be a link
  # out is one (`external_link/1`).
  defp shown_subjects(subjects) do
    for subject <- subjects || [] do
      Map.merge(subject, %{
        "type" => ExternalText.line(subject["type"]),
        "ref" => ExternalText.line(subject["ref"]),
        "title" => ExternalText.present(subject["title"])
      })
    end
  end

  defp detail(value) when is_binary(value), do: {value, :text}
  defp detail(value), do: {Jason.encode!(value), :json}
end
