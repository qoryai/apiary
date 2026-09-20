defmodule ApiaryWeb.RunPageComponents do
  @moduledoc """
  The components of the run page (`docs/design/brief-runs.md`, rd10, rd11, rd14, rd16): the
  session timeline with its lanes and items, the who chip, the background-task strip, the
  live end, the limits notice and the terminal box.

  An item is what `Apiary.Runs.Record.Timeline.build/3` made of a run's events. Everything
  in it came from a runner and is untrusted: it is interpolated, so it is escaped, and it
  is never `raw/1`. A link is built by the caller from a verified route and a sequence
  number, never from a string of the record. The terminal's bytes are not rendered here
  at all: the `Terminal` hook feeds them to xterm.js.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents,
    only: [badge: 1, icon: 1, notice: 1, empty_state: 1, listening: 1, term: 1]

  import ApiaryWeb.RunComponents,
    only: [connection_row: 1, duration: 1, offset: 1, count_noun: 2, delimited: 1]

  alias Phoenix.LiveView.JS

  @background_tip "The runtime lists what is still running at the end of each turn. A task counts as running until a list leaves it out."

  ## rd10. The lane key

  @doc """
  One toggle of the lane key: a ring in the lane's colour, the agent's type and its id.
  The key is the legend of the rails, so colour is never the only carrier.
  """
  attr :lane, :map, required: true, doc: "%{index, id, type, color}"
  attr :pressed, :boolean, default: true
  attr :patch, :string, required: true

  # A button that patches, so that it answers Space as well as Enter and the URL changes. The
  # DOM id is the lane's number in the run: an agent id is the runner's string.
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
        Main session
      <% else %>
        {@lane.type || "Subagent"} <small>{@lane.id}</small>
      <% end %>
    </button>
    """
  end

  ## rd11. Who

  @doc "The agent an item belongs to, in words, where a lane opens or closes."
  attr :lane, :map, required: true

  def who(assigns) do
    ~H"""
    <span class={["q-who", "q-lane-#{@lane.color}"]}>
      {if @lane.id == "main", do: "Main session", else: @lane.type || @lane.id}
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
    assigns = assign(assigns, shown: Enum.take(assigns.background.tasks, 3), tip: @background_tip)

    ~H"""
    <div
      :if={@background.count > 0}
      id={@id}
      class="q-bgtasks"
      role="status"
      aria-label="Background tasks"
    >
      <%= for {task, i} <- Enum.with_index(@shown) do %>
        <span class={["q-spin", @ended && "q-spin-still"]} aria-hidden="true"></span>
        <span class="truncate">
          <b :if={i == 0} class="font-medium">
            {count_noun(@background.count, "task")}
            {if @ended,
              do:
                "#{if @background.count == 1, do: "was", else: "were"} still listed when the run ended",
              else: "still running in the background"}
          </b>
          <span class={["font-mono text-[12.5px] text-muted", i == 0 && "ml-1.5"]}>{task.what ||
            task.type || "task"}</span>
        </span>
        <span
          class="q-bgtasks-since tooltip tooltip-left q-tip-wide text-xs text-faint"
          tabindex="0"
          data-tip={@tip}
        >
          {task.type || "task"} {task.id} · listed at #{pad(task.listed_at)}
        </span>
      <% end %>
      <span :if={@background.count > 3} class="col-start-2 text-xs text-faint">
        and {delimited(@background.count - 3)} more
      </span>
    </div>
    """
  end

  ## rd16. Limits

  @doc """
  A fact about the record: why a timeline, a log or a connection list is not there. An
  info notice above content that is there (`variant="notice"`), or the body of an empty
  state when it replaces content that is absent. Never a toast, never dismissible.
  """
  attr :reason, :atom,
    required: true,
    values: [:no_hooks, :vm_wall, :other_runtime, :not_started, :no_egress, :no_log]

  attr :variant, :string, default: "notice", values: ~w(notice empty)
  attr :runtime, :string, default: nil
  attr :live, :boolean, default: false
  attr :wall, :boolean, default: false
  attr :only_result, :boolean, default: false

  def limits(%{variant: "notice"} = assigns) do
    ~H"""
    <.notice class="q-limits">
      <.limit_sentence reason={@reason} runtime={@runtime} />
      <span :if={@only_result}>Only the result, read from the runtime's output, is shown.</span>
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
      <.limit_sentence :if={@reason != :no_log} reason={@reason} runtime={@runtime} />
      <.listening
        :if={@reason == :not_started or (@reason == :no_log and @live)}
        class="mt-3 justify-center"
      >
        {if @reason == :not_started,
          do: "Listening for the run's first event.",
          else: "Listening for the first bytes."}
      </.listening>
    </.empty_state>
    """
  end

  attr :reason, :atom, required: true
  attr :runtime, :string, default: nil

  defp limit_sentence(%{reason: :not_started} = assigns) do
    ~H"The runner has pinged. The run's first event has not arrived."
  end

  defp limit_sentence(%{reason: :other_runtime} = assigns) do
    ~H"""
    Session events exist only for Claude Code. This run used <code class="q-rule">{@runtime}</code>, so it has a terminal and connections, and no timeline.
    """
  end

  defp limit_sentence(%{reason: :vm_wall} = assigns) do
    ~H"""
    This run was behind a
    <.term
      word="wall"
      standard="The enclosure the agent runs in. Its only route out leads to the runner's proxy."
      class="q-tip-wide"
    />
    on an engine inside a virtual machine, where the runtime's hook socket does not reach the runner. It has a terminal and connections, and no session timeline.
    """
  end

  defp limit_sentence(%{reason: :no_hooks} = assigns) do
    ~H"No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its terminal and connections."
  end

  defp limit_sentence(%{reason: :no_egress} = assigns) do
    ~H"No connection went through the runner's proxy. Only programs that honour the proxy variables are seen."
  end

  defp limit_sentence(assigns), do: ~H""

  defp limit_title(:not_started, _live), do: "Waiting for the run to start"
  defp limit_title(:no_egress, _live), do: "No connections recorded"
  defp limit_title(:no_log, true), do: "No output yet"
  defp limit_title(:no_log, false), do: "This run wrote no output"
  defp limit_title(_reason, _live), do: "No session timeline"

  defp limit_icon(:not_started), do: "hero-play-circle"
  defp limit_icon(:no_egress), do: "hero-arrows-right-left"
  defp limit_icon(:no_log), do: "hero-command-line"
  defp limit_icon(_reason), do: "hero-list-bullet"

  ## rd10. The timeline

  @doc """
  The session timeline: one column in sequence order, a rail per agent in the gutter. The
  `<ol>` is a LiveView stream; it has no `aria-live`, new items are counted by the pill.

  `target` is the DOM id of the item `?seq=` points at and `isolate` the lane `?lane=`
  keeps; both are applied by the `TimelineKeys` hook, because a stream's items are not
  rendered again when a parameter changes.
  """
  attr :id, :string, required: true
  attr :stream, :any, required: true
  attr :rails, :integer, required: true, doc: "how many rails the gutter holds, 1 to 4"
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true, doc: "a function from a sequence to the item's permalink"
  attr :target, :string, default: nil
  attr :isolate, :string, default: nil
  attr :connections, :boolean, default: true, doc: "false hides every connection (?cx=0)"
  attr :earlier, :integer, default: 0, doc: "items before the window"
  attr :later, :integer, default: 0, doc: "items after the window that are not new arrivals"

  def timeline(assigns) do
    ~H"""
    <div class="grid">
      <button
        :if={@earlier > 0}
        id={"#{@id}-earlier"}
        type="button"
        class="q-tl-more"
        phx-click="load_earlier"
      >
        <.icon name="hero-arrow-up-micro" class="size-3" /> {count_noun(@earlier, "earlier event")}
      </button>
      <ol
        id={@id}
        class={["q-tl", "q-lanes-#{@rails}"]}
        aria-label={timeline_label(@earlier, @later)}
        phx-update="stream"
        phx-hook="TimelineKeys"
        phx-viewport-top={@earlier > 0 && "load_earlier"}
        phx-viewport-bottom={@later > 0 && "load_later"}
        data-target={@target}
        data-isolate={@isolate}
        data-cx={if @connections, do: "1", else: "0"}
        tabindex="0"
      >
        <.timeline_item
          :for={{dom_id, item} <- @stream}
          id={dom_id}
          item={item}
          started_at={@started_at}
          seq_path={@seq_path}
        />
      </ol>
      <button
        :if={@later > 0}
        id={"#{@id}-later"}
        type="button"
        class="q-tl-more"
        phx-click="load_later"
      >
        <.icon name="hero-arrow-down-micro" class="size-3" /> Load newer
        <span class="text-faint">· {count_noun(@later, "later event")}</span>
      </button>
    </div>
    """
  end

  # "Oldest first" is only true of a list that starts at the start.
  defp timeline_label(0, 0), do: "Session timeline, oldest first"

  defp timeline_label(earlier, later) do
    [
      "Session timeline, in sequence order",
      earlier > 0 && "#{count_noun(earlier, "earlier event")} not loaded",
      later > 0 && "#{count_noun(later, "later event")} not loaded"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  @doc """
  One item: the gutter with the rails open at its sequence and its node, then the body.
  A connection has no node: egress belongs to the run, not to an agent.
  """
  attr :id, :string, required: true, doc: "\"e-\#{sequence}\""
  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true

  def timeline_item(assigns) do
    ~H"""
    <li
      id={@id}
      class={["q-ti", connection?(@item) && "q-ti-cx"]}
      data-seq={@item.sequence}
      data-lane={@item.lane.id}
      data-denied={denied?(@item) && "1"}
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
          in {@item.lane.type || "subagent"} {short_agent(@item.lane.id)}:
        </span>
        <.item_body id={@id} item={@item} started_at={@started_at} seq_path={@seq_path} />
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

  defp node_look(%{kind: :policy_applied}),
    do: %{glyph: "hero-shield-check-micro", shape: :square, tone: nil}

  defp node_look(%{kind: :run_exited} = item) do
    if item.exit_code == 0 and is_nil(item.signal) and is_nil(item.reason),
      do: %{glyph: "hero-check-micro", shape: :square, tone: nil},
      else: %{glyph: "hero-x-mark-micro", shape: :square, tone: :fail}
  end

  defp node_look(%{kind: :session_started}),
    do: %{glyph: "hero-command-line-micro", shape: :round, tone: nil}

  defp node_look(%{kind: :prompt}),
    do: %{glyph: "hero-chat-bubble-left-micro", shape: :round, tone: :solid}

  defp node_look(%{kind: :tool, status: :failed}),
    do: %{glyph: "hero-x-mark-micro", shape: :round, tone: :fail}

  defp node_look(%{kind: :tool, status: :open}),
    do: %{glyph: :spinner, shape: :round, tone: :info}

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

  defp item_body(%{item: %{kind: :run_started}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Run started">
      {@item.runtime || "n/a"} {@item.runtime_version} on {@item.host || "n/a"}, {if @item.wall,
        do: "behind a #{@item.wall} wall",
        else: "without a wall"}
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :policy_applied}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Policy applied">
      {@item.mode || "n/a"} · {count_noun(@item.allowed_hosts, "host")} allowed · {policy_source(
        @item.source
      )}
      <span :if={@item.terminated != []}>
        · reads requests to
        <span :for={{host, i} <- Enum.with_index(@item.terminated)}>
          {if i > 0, do: ", "}<span class="font-mono text-[12.5px]">{host}</span>
        </span>
        <span :if={@item.terminated_count > length(@item.terminated)}>
          and {@item.terminated_count - length(@item.terminated)} more
        </span>
      </span>
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :session_started}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Session started">
      <span :if={@item.model}>model <span class="font-mono text-[12.5px]">{@item.model}</span></span>
      <span :if={@item.source}> · {@item.source}</span>
      <span :if={@item.cwd}> · <span class="font-mono text-[12.5px]">{@item.cwd}</span></span>
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :prompt}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Prompt" />
    <.say item={@item} class="q-say-prompt" />
    """
  end

  defp item_body(%{item: %{kind: :tool}} = assigns) do
    ~H"""
    <details
      id={"#{@id}-tool"}
      class="q-tool"
      open={@item.status == :failed or @item.denied_inside}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="q-hd">
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
        <span class="q-k q-k-mono">{@item.tool}</span>
        <.who :if={@item.who} lane={@item.lane} />
        <span class="q-s q-s-mono"><.tool_summary summary={@item.summary} /></span>
        <.badge :if={@item.in_background} color="info" class="self-center">In background</.badge>
        <.tail item={@item} started_at={@started_at} seq_path={@seq_path}>
          <span :if={@item.status == :failed} class="q-bad">{if @item.interrupted,
            do: "Interrupted",
            else: "Failed"}</span>
          <span :if={@item.status == :open} class="q-running">Running</span>
          <span :if={@item.status == :no_end} class="q-no-end">No end recorded</span>
          <.duration :if={@item.duration_ms} ms={@item.duration_ms} precise class="q-d" />
        </.tail>
      </summary>
      <div :if={@item.connections != []} class="q-during">
        <small>
          {count_noun(@item.connections_count, "connection")} while this call was open
        </small>
        <.connection_row
          :for={cx <- @item.connections}
          id={"#{@id}-cx-#{cx.sequence}"}
          connection={cx}
          variant="inline"
          started_at={@started_at}
        />
        <small :if={@item.connections_count > length(@item.connections)}>
          {delimited(@item.connections_count - length(@item.connections))} more are counted on the Connections tab.
        </small>
      </div>
      <div :if={@item.wells != []} class="q-io">
        <.well :for={well <- @item.wells} well={well} seq={@item.sequence} full={@item.full} />
      </div>
    </details>
    """
  end

  defp item_body(%{item: %{kind: kind}} = assigns)
       when kind in [:subagent_started, :subagent_finished] do
    ~H"""
    <div class="q-hd">
      <span class="q-k">{if @item.kind == :subagent_started,
        do: "Subagent started",
        else: "Subagent finished"}</span>
      <.who lane={@item.lane} />
      <span class="q-s font-mono text-xs">{if @item.kind == :subagent_started, do: @item.agent_id}</span>
      <.tail item={@item} started_at={@started_at} seq_path={@seq_path}>
        <.duration :if={@item.duration_ms} ms={@item.duration_ms} precise class="q-d" />
      </.tail>
    </div>
    <.say :if={@item.kind == :subagent_finished} item={@item} />
    """
  end

  defp item_body(%{item: %{kind: :notification}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Notification">
      {[@item.notification_kind, @item.message] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :turn_finished}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Turn finished" />
    <.say item={@item} />
    """
  end

  defp item_body(%{item: %{kind: :turn_failed}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Turn failed" tone="error">
      {[@item.error, @item.message] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
    </.head>
    <div :if={@item.wells != []} class="q-io">
      <.well :for={well <- @item.wells} well={well} seq={@item.sequence} full={@item.full} />
    </div>
    """
  end

  defp item_body(%{item: %{kind: :result}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Result">
      {result_words(@item)}
    </.head>
    <.say item={@item} />
    """
  end

  defp item_body(%{item: %{kind: :session_ended}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Session ended">
      {@item.reason}
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :run_exited}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind="Run exited">
      {exit_words(@item)}
      <span :if={@item.duration_ms}> · <.duration ms={@item.duration_ms} /></span>
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
      caption={@item.open_calls > 1 && "while #{@item.open_calls} calls were open"}
    />
    """
  end

  defp item_body(%{item: %{kind: :connection_group}} = assigns) do
    ~H"""
    <details
      id={"#{@id}-group"}
      class="q-tool q-cx-group"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="q-cx-sum">
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
        <span class="q-dest">{@item.host}<span class="q-port">:{@item.port}</span></span>
        <span class="text-muted">
          · {count_noun(@item.connections_count, "allowed connection")}
          <span :if={@item.open_calls > 1} class="text-faint">· while {@item.open_calls} calls were open</span>
        </span>
        <span class="q-cx-at ml-auto">
          <.offset at={@item.first_at} from={@started_at} /> to
          <.offset at={@item.last_at} from={@started_at} />
        </span>
      </summary>
      <div class="q-during">
        <.connection_row
          :for={cx <- @item.connections}
          id={"#{@id}-cx-#{cx.sequence}"}
          connection={cx}
          variant="inline"
          started_at={@started_at}
        />
        <small :if={@item.connections_count > length(@item.connections)}>
          {delimited(@item.connections_count - length(@item.connections))} more are counted on the Connections tab.
        </small>
      </div>
    </details>
    """
  end

  ## The head row

  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  attr :kind, :string, required: true
  attr :tone, :string, default: nil
  slot :inner_block

  defp head(assigns) do
    ~H"""
    <div class="q-hd">
      <span class={["q-k", @tone == "error" && "q-bad"]}>{@kind}</span>
      <.who :if={@item.who} lane={@item.lane} />
      <span class="q-s">{render_slot(@inner_block)}</span>
      <.tail item={@item} started_at={@started_at} seq_path={@seq_path} />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
  slot :inner_block

  defp tail(assigns) do
    ~H"""
    <span class="q-t">
      {render_slot(@inner_block)}
      <.offset at={@item.time} from={@started_at} class="q-t-at" />
      <.link patch={@seq_path.(@item.sequence)} class="q-q" tabindex="-1" data-permalink>#{pad(
        @item.sequence
      )}</.link>
    </span>
    """
  end

  attr :summary, :any, required: true

  defp tool_summary(%{summary: {:pattern, _pattern, _path}} = assigns) do
    ~H"""
    {elem(@summary, 1)} <span class="text-faint">in</span> {elem(@summary, 2)}
    """
  end

  defp tool_summary(%{summary: {:text, _text}} = assigns), do: ~H"{elem(@summary, 1)}"
  defp tool_summary(assigns), do: ~H""

  attr :item, :map, required: true
  attr :class, :any, default: nil

  defp say(assigns) do
    ~H"""
    <p :if={@item.text} class={["q-say", @class]} phx-no-format>{@item.text}<.show_all :if={@item.text_cut} seq={@item.sequence} bytes={@item.text_bytes} /></p>
    """
  end

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
      <pre :if={@well.format == :json} tabindex="0" phx-no-format><%= for {indent, key, rest} <- json_lines(@well.text) do %>{indent}<span :if={key} class="q-key">{key}</span>{rest}{"\n"}<% end %><.show_all :if={@well.cut} seq={@seq} bytes={@well.bytes} /></pre>
      <pre :if={@well.format == :text} tabindex="0" phx-no-format>{@well.text}<.show_all :if={@well.cut} seq={@seq} bytes={@well.bytes} /></pre>
    </div>
    """
  end

  attr :seq, :integer, required: true
  attr :bytes, :integer, required: true

  defp show_all(assigns) do
    ~H"""
    <button type="button" class="q-show-all" phx-click="show_all" phx-value-seq={@seq}>Show all {format_bytes(
      @bytes
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
    do: "#{format_bytes(bytes)} · #{count_noun(lines, "line")}"

  defp well_size(%{bytes: bytes}), do: format_bytes(bytes)

  @doc "A byte count in the words of the terminal's foot: \"812 B\", \"48.2 KB\", \"1.4 MB\"."
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  ## Words

  defp policy_source("fetched"), do: "fetched from the run configuration"
  defp policy_source("config"), do: "given to the runner as a policy document"
  defp policy_source("none"), do: "no policy, every connection is observed"
  defp policy_source(_other), do: "source n/a"

  @doc "The source of a policy in words, for the Details tab too."
  def policy_source_words(source), do: policy_source(source)

  defp exit_words(%{reason: "timeout"}), do: "timeout"
  defp exit_words(%{reason: "runner_lost"}), do: "runner lost"
  defp exit_words(%{signal: signal}) when is_binary(signal), do: signal
  defp exit_words(%{exit_code: code}) when is_integer(code), do: "exit #{code}"
  defp exit_words(_item), do: "n/a"

  defp result_words(item) do
    [
      item.outcome,
      item.turns && count_noun(item.turns, "turn"),
      item.duration_ms && ApiaryWeb.RunComponents.format_duration_ms(item.duration_ms),
      item.cost_usd && cost(item.cost_usd)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  # Two places, four when under a cent.
  defp cost(usd) when usd < 0.01, do: "$" <> :erlang.float_to_binary(usd / 1, decimals: 4)
  defp cost(usd), do: "$" <> :erlang.float_to_binary(usd / 1, decimals: 2)

  @doc "A sequence as the page writes it: four digits at least."
  def pad(sequence) when is_integer(sequence),
    do: sequence |> Integer.to_string() |> String.pad_leading(4, "0")

  def pad(_sequence), do: "n/a"

  ## P6. The live end

  @doc "Under the last item: listening while the run is alive, the end of the record after."
  attr :live, :boolean, required: true
  attr :events, :integer, required: true
  attr :last_sequence, :integer, default: nil
  attr :last_event_at, :any, default: nil

  def live_end(%{live: true} = assigns) do
    ~H"""
    <p id="live-end" class="q-tail">
      <span class="listening-dot mx-1" aria-hidden="true" />
      <span>
        Listening for the next batch.
        <span :if={@last_sequence}>
          Last event #{pad(@last_sequence)}<span :if={@last_event_at}>,
            <time data-tick="seconds" data-since={DateTime.to_iso8601(@last_event_at)} aria-live="off">{ApiaryWeb.RunComponents.format_seconds(
                max(DateTime.diff(DateTime.utc_now(), @last_event_at), 0)
              )}</time>
            ago</span>.
        </span>
      </span>
    </p>
    """
  end

  def live_end(assigns) do
    ~H"""
    <p id="live-end" class="q-tail">End of the record. {count_noun(@events, "event")}.</p>
    """
  end

  ## rd14. Terminal

  @doc """
  The terminal box: dark in both themes. The bar and the screen belong to the `Terminal`
  hook (`phx-update="ignore"`); the foot is the LiveView's, which sends numbers and never
  bytes. The hook reads the log from `src` and asks again when the LiveView says the log
  has advanced.
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

  def terminal(assigns) do
    ~H"""
    <div
      id={@id}
      class="q-termbox"
      role="region"
      aria-label="Terminal output"
      phx-hook="Terminal"
      data-src={@src}
      data-script={@script}
      data-stylesheet={@stylesheet}
      data-live={to_string(@live)}
      data-pty={to_string(@streams == ["terminal"])}
      data-through={@through}
    >
      <div id={"#{@id}-bar"} class="q-term-bar" phx-update="ignore">
        <a class="sr-only focus:not-sr-only q-tbtn" href={@src <> "?download=1"} download>
          Read the log as text
        </a>
        <div class="q-tseg" role="group" aria-label="Stream">
          <%= if length(@streams) > 1 do %>
            <button :for={stream <- @streams} type="button" data-stream={stream} aria-pressed="false">
              {stream}
            </button>
            <button type="button" data-stream="" aria-pressed="true">both</button>
          <% else %>
            <span class="q-tseg-one">{List.first(@streams) || "terminal"}</span>
          <% end %>
        </div>
        <label class="q-term-find">
          <.icon name="hero-magnifying-glass-micro" class="size-4" />
          <span class="sr-only">Search the log</span>
          <input type="text" data-find spellcheck="false" autocomplete="off" placeholder="Search" />
          <span data-find-count aria-live="polite"></span>
        </label>
        <button
          type="button"
          class="q-tbtn tooltip tooltip-left"
          data-tip="Wrap long lines"
          aria-label="Wrap long lines"
          aria-pressed="false"
          data-wrap
        >
          <.icon name="hero-bars-arrow-down-micro" class="size-4" />
        </button>
        <a
          class="q-tbtn tooltip tooltip-left"
          data-tip="Download the raw bytes"
          aria-label="Download the raw bytes"
          href={@src <> "?download=1"}
          download
        >
          <.icon name="hero-arrow-down-tray-micro" class="size-4" />
        </a>
        <button type="button" class="q-tbtn" aria-pressed={to_string(@live)} data-follow>
          <.icon name="hero-arrow-down-micro" class="size-4" />
          <span class="q-tbtn-lbl" data-follow-label>{if @live, do: "Following", else: "Jump to end"}</span>
        </button>
      </div>
      <div id={"#{@id}-screen"} class="q-term-screen" phx-update="ignore">
        <div data-screen role="log" aria-live="off" aria-label="Log"></div>
        <span class="sr-only" data-announce aria-live="polite"></span>
        <button type="button" class="q-newpill q-term-pill" data-pill tabindex="-1" aria-hidden="true">
          <.icon name="hero-arrow-down-micro" class="size-4" /> <span data-pill-text>New lines</span>
        </button>
        <div class="q-term-msg" data-message hidden>
          <p data-message-text></p>
          <button type="button" class="q-tbtn" data-retry hidden>Try again</button>
        </div>
      </div>
      <div class="q-term-foot">
        <span :if={@live} class="q-term-live"><i></i>Live</span>
        <span :if={!@live}>Ended</span>
        <span>{format_bytes(@bytes)}</span>
        <span class="q-term-opt">{count_noun(@chunks, "chunk")}</span>
        <span class="q-term-opt">through #{pad(@through)}</span>
      </div>
    </div>
    <p class="mt-3 text-[12.5px] text-faint">
      The bytes as the runtime wrote them, terminal escapes included. Nothing here is interpreted; the timeline is where the session is read.
    </p>
    """
  end
end
