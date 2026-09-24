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
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText

  import ApiaryWeb.CoreComponents,
    only: [badge: 1, icon: 1, notice: 1, empty_state: 1, listening: 1, term: 1]

  import ApiaryWeb.RunComponents,
    only: [connection_row: 1, tool_mark: 1, duration: 1, offset: 1, delimited: 1, middle: 2]

  alias ApiaryWeb.RunComponents

  alias Phoenix.LiveView.JS

  @background_tip gettext_noop(
                    "The runtime lists what is still running at the end of each turn. A task counts as running until a list leaves it out."
                  )

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
        {gettext("Main session")}
      <% else %>
        {@lane.type || gettext("Subagent")} <small>{@lane.id}</small>
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
      {if @lane.id == "main", do: gettext("Main session"), else: @lane.type || @lane.id}
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
          <span class={["font-mono text-[12.5px] text-muted", i == 0 && "ml-1.5"]}>{task.what ||
            task.type || gettext("task")}</span>
        </span>
        <span
          class="q-bgtasks-since tooltip tooltip-left q-tip-wide text-xs text-faint"
          tabindex="0"
          data-tip={@tip}
        >
          {gettext("%{task} %{id} · listed at #%{sequence}",
            task: task.type || gettext("task"),
            id: task.id,
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
      number: delimited(count)
    )
  end

  defp background_words(count, false) do
    ngettext(
      "%{number} task still running in the background",
      "%{number} tasks still running in the background",
      count,
      number: delimited(count)
    )
  end

  defp and_more(n),
    do: ngettext("and %{number} more", "and %{number} more", n, number: delimited(n))

  ## rd16. Limits

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

  def limits(%{variant: "notice"} = assigns) do
    ~H"""
    <.notice class="q-limits">
      <.limit_sentence reason={@reason} runtime={@runtime} />
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
      <.limit_sentence :if={@reason != :no_log} reason={@reason} runtime={@runtime} at={@at} />
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

  defp limit_sentence(%{reason: :pruned} = assigns) do
    ~H"""
    {gettext(
      "This run's events were pruned on %{date}, under the hive's retention. The run keeps its header, its counts and its connections; the timeline and the log output are gone.",
      date: ApiaryWeb.CoreComponents.short_date(@at)
    )}
    """
  end

  defp limit_sentence(%{reason: :log_pruned} = assigns) do
    ~H"""
    {gettext(
      "This run's log output was pruned on %{date}, under the hive's retention. The timeline and the connections are whole.",
      date: ApiaryWeb.CoreComponents.short_date(@at)
    )}
    """
  end

  defp limit_sentence(%{reason: :not_started} = assigns) do
    ~H"""
    {gettext("The runner has pinged. The run's first event has not arrived.")}
    """
  end

  defp limit_sentence(%{reason: :other_runtime} = assigns) do
    ~H"""
    <.rich text={
      rich_gettext(
        "Session events exist only for Claude Code. This run used %{runtime}, so it has a terminal and connections, and no timeline.",
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
      rich_gettext(
        "This run was behind a %{wall} on an engine inside a virtual machine, where the runtime's hook socket does not reach the runner. It has a terminal and connections, and no session timeline.",
        wall: {:part, :wall}
      )
    }>
      <:part name={:wall}>
        <.term
          word={gettext("wall")}
          standard={
            gettext(
              "The enclosure the agent runs in. Its only route out leads to the runner's proxy."
            )
          }
          class="q-tip-wide"
        />
      </:part>
    </.rich>
    """
  end

  defp limit_sentence(%{reason: :no_hooks} = assigns) do
    ~H"""
    {gettext(
      "No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its terminal and connections."
    )}
    """
  end

  defp limit_sentence(%{reason: :no_egress} = assigns) do
    ~H"""
    {gettext(
      "No connection went through the runner's proxy. Only programs that honour the proxy variables are seen."
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
        <.icon name="hero-arrow-up-micro" class="size-3" /> {earlier_events(@earlier)}
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
        <.icon name="hero-arrow-down-micro" class="size-3" /> {gettext("Load newer")}
        <span class="text-faint">· {later_events(@later)}</span>
      </button>
    </div>
    """
  end

  # "Oldest first" is only true of a list that starts at the start.
  defp timeline_label(0, 0), do: gettext("Session timeline, oldest first")

  defp timeline_label(earlier, 0) do
    gettext("Session timeline, in sequence order; %{earlier} not loaded",
      earlier: earlier_events(earlier)
    )
  end

  defp timeline_label(0, later) do
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
    do: ngettext("%{number} earlier event", "%{number} earlier events", n, number: delimited(n))

  defp later_events(n),
    do: ngettext("%{number} later event", "%{number} later events", n, number: delimited(n))

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
          {gettext("in %{agent} %{id}:",
            agent: @item.lane.type || gettext("subagent"),
            id: short_agent(@item.lane.id)
          )}
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

  defp node_look(%{kind: :policy_applied, again: true}),
    do: %{glyph: "hero-arrow-path-micro", shape: :square, tone: nil}

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
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Run started")}>
      {run_started_words(@item)}
    </.head>
    """
  end

  # pe6: a reload. What it changed is taken from the allow and deny lists of the two
  # events, which are the record's; the policy tables are not asked. Every host is a
  # runner's string. A deny chip carries the deny mark: a host that came into `deny` is
  # denied from this item on, in either mode.
  defp item_body(%{item: %{kind: :policy_applied, again: true}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      kind={pgettext("plain", "Policy applied again")}
    >
      {gettext("reloaded")} ·
      <%= if @item.was_mode do %>
        <b class="font-semibold text-base-content">{@item.mode || gettext("n/a")}</b> {gettext(
          "(was %{mode})",
          mode: @item.was_mode
        )}
      <% else %>
        {@item.mode || gettext("n/a")}
      <% end %>
      · {hosts_allowed(@item.allowed_hosts)}<span :if={@item.denied_hosts > 0}> · {hosts_denied(
        @item.denied_hosts
      )}</span>
      <:chips :if={@item.delta}>
        <span :for={host <- @item.delta.added} class="q-delta q-delta-add" title={host}>
          <span aria-hidden="true">+</span><span class="sr-only">{gettext("Added:")}</span> {middle(
            host,
            48
          )}
        </span>
        <span :for={host <- @item.delta.removed} class="q-delta q-delta-del" title={host}>
          <span aria-hidden="true">−</span><span class="sr-only">{gettext("Removed:")}</span> {middle(
            host,
            48
          )}
        </span>
        <span
          :for={host <- @item.delta.deny_added}
          class="q-delta q-delta-deny q-delta-deny-add"
          title={gettext("Denied from here: %{host}", host: host)}
        >
          <span aria-hidden="true">+</span><.icon name="hero-no-symbol-micro" class="size-3" /><span class="sr-only">{gettext(
            "Deny added:"
          )}</span> {middle(
            host,
            48
          )}
        </span>
        <span
          :for={host <- @item.delta.deny_removed}
          class="q-delta q-delta-deny q-delta-deny-del"
          title={gettext("No longer denied: %{host}", host: host)}
        >
          <span aria-hidden="true">−</span><.icon name="hero-no-symbol-micro" class="size-3" /><span class="sr-only">{gettext(
            "Deny removed:"
          )}</span> {middle(
            host,
            48
          )}
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
      kind={pgettext("plain", "Policy applied")}
    >
      <:version><.item_version version={@item[:version]} /></:version>
      {@item.mode || gettext("n/a")} · {hosts_allowed(@item.allowed_hosts)}<span :if={
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
              /><span class="font-mono text-[12.5px]">{tool.name}</span><span
                :if={tool.hosts != []}
                class="text-faint"
              > ({Enum.join(tool.hosts, ", ")})</span>
            </span>
          </:part>
        </.rich>
      </span>
      <span :if={@item.terminated != []}>
        ·
        <.rich text={rich_gettext("reads requests to %{hosts}", hosts: {:part, :hosts})}>
          <:part name={:hosts}>
            <span :for={{host, i} <- Enum.with_index(@item.terminated)}>
              {if i > 0, do: ", "}<span class="font-mono text-[12.5px]">{host}</span>
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
      kind={gettext("Session started")}
    >
      <span :if={@item.model}><.rich text={rich_gettext("model %{model}", model: {:part, :model})}>
        <:part name={:model}><span class="font-mono text-[12.5px]">{@item.model}</span></:part>
      </.rich></span>
      <span :if={@item.source}> · {@item.source}</span>
      <span :if={@item.cwd}> · <span class="font-mono text-[12.5px]">{@item.cwd}</span></span>
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :prompt}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Prompt")} />
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
        <.badge :if={@item.in_background} color="info" class="self-center">
          {gettext("In background")}
        </.badge>
        <.tail item={@item} started_at={@started_at} seq_path={@seq_path}>
          <span :if={@item.status == :failed} class="q-bad">{if @item.interrupted,
            do: gettext("Interrupted"),
            else: gettext("Failed")}</span>
          <span :if={@item.status == :open} class="q-running">{gettext("Running")}</span>
          <span :if={@item.status == :no_end} class="q-no-end">{gettext("No end recorded")}</span>
          <.duration :if={@item.duration_ms} ms={@item.duration_ms} precise class="q-d" />
        </.tail>
      </summary>
      <div :if={@item.connections != []} class="q-during">
        <small>
          {ngettext(
            "%{number} connection while this call was open",
            "%{number} connections while this call was open",
            @item.connections_count,
            number: delimited(@item.connections_count)
          )}
        </small>
        <.connection_row
          :for={cx <- @item.connections}
          id={"#{@id}-cx-#{cx.sequence}"}
          connection={cx}
          variant="inline"
          started_at={@started_at}
        />
        <small :if={@item.connections_count > length(@item.connections)}>
          {more_counted(@item.connections_count - length(@item.connections))}
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
        do: gettext("Subagent started"),
        else: gettext("Subagent finished")}</span>
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
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Notification")}>
      {[@item.notification_kind, @item.message] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :turn_finished}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Turn finished")} />
    <.say item={@item} />
    """
  end

  defp item_body(%{item: %{kind: :turn_failed}} = assigns) do
    ~H"""
    <.head
      item={@item}
      started_at={@started_at}
      seq_path={@seq_path}
      kind={gettext("Turn failed")}
      tone="error"
    >
      {[@item.error, @item.message] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
    </.head>
    <div :if={@item.wells != []} class="q-io">
      <.well :for={well <- @item.wells} well={well} seq={@item.sequence} full={@item.full} />
    </div>
    """
  end

  defp item_body(%{item: %{kind: :result}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Result")}>
      {result_words(@item)}
    </.head>
    <.say item={@item} />
    """
  end

  defp item_body(%{item: %{kind: :session_ended}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Session ended")}>
      {@item.reason}
    </.head>
    """
  end

  defp item_body(%{item: %{kind: :run_exited}} = assigns) do
    ~H"""
    <.head item={@item} started_at={@started_at} seq_path={@seq_path} kind={gettext("Run exited")}>
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
      caption={@item.open_calls > 1 && calls_open(@item.open_calls)}
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
        <span :if={@item.tool} class="q-dest q-dest-tool">
          <.tool_mark name={@item.tool} />
          <span class="q-on">{@item.host}:{@item.port}</span>
        </span>
        <span :if={!@item.tool} class="q-dest">
          {@item.host}<span class="q-port">:{@item.port}</span>
        </span>
        <span class="text-muted">
          · {if @item.tool,
            do:
              ngettext(
                "%{number} allowed request",
                "%{number} allowed requests",
                @item.connections_count,
                number: delimited(@item.connections_count)
              ),
            else:
              ngettext(
                "%{number} allowed connection",
                "%{number} allowed connections",
                @item.connections_count,
                number: delimited(@item.connections_count)
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
      <div class="q-during">
        <.connection_row
          :for={cx <- @item.connections}
          id={"#{@id}-cx-#{cx.sequence}"}
          connection={cx}
          variant="inline"
          started_at={@started_at}
        />
        <small :if={@item.connections_count > length(@item.connections)}>
          {more_counted(@item.connections_count - length(@item.connections))}
        </small>
      </div>
    </details>
    """
  end

  defp run_started_words(item) do
    bindings = [
      runtime: item.runtime || gettext("n/a"),
      version: item.runtime_version,
      host: item.host || gettext("n/a")
    ]

    if item.wall,
      do:
        gettext(
          "%{runtime} %{version} on %{host}, behind a %{wall} wall",
          [wall: item.wall] ++ bindings
        ),
      else: gettext("%{runtime} %{version} on %{host}, without a wall", bindings)
  end

  defp hosts_allowed(n),
    do: ngettext("%{number} host allowed", "%{number} hosts allowed", n, number: delimited(n))

  defp hosts_denied(n),
    do: ngettext("denies %{number} host", "denies %{number} hosts", n, number: delimited(n))

  defp more_counted(n) do
    ngettext(
      "%{number} more is counted on the Connections tab.",
      "%{number} more are counted on the Connections tab.",
      n,
      number: delimited(n)
    )
  end

  defp calls_open(n),
    do: ngettext("while %{count} call was open", "while %{count} calls were open", n)

  ## The head row

  attr :item, :map, required: true
  attr :started_at, :any, required: true
  attr :seq_path, :any, required: true
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
      <.tail item={@item} started_at={@started_at} seq_path={@seq_path}>
        {render_slot(@version)}
      </.tail>
    </div>
    """
  end

  attr :version, :any, default: nil, doc: "%{n, path} when the digest names a version here"

  # The version a policy applied names, when this hive rendered it: the link of pd1.
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
      "The runner fetched a new run configuration after the server's answer named a new digest."
    )
  end

  defp reload_sentence(%{source: "fetched"}),
    do: gettext("The runner fetched its run configuration again; the digest is the one it had.")

  defp reload_sentence(_item), do: pgettext("plain", "The runner applied a policy again.")

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
  defp hosts_words(n), do: ngettext("%{number} host", "%{number} hosts", n, number: delimited(n))

  defp hosts_or_none(0), do: gettext("none")
  defp hosts_or_none(n), do: hosts_words(n)

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
    {elem(@summary, 1)}
    <span class="text-faint">{pgettext("a pattern in a path", "in")}</span> {elem(
      @summary,
      2
    )}
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
    <button type="button" class="q-show-all" phx-click="show_all" phx-value-seq={@seq}>{gettext(
      "Show all %{size}",
      size: format_bytes(@bytes)
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
        size: format_bytes(bytes),
        lines: ngettext("%{number} line", "%{number} lines", lines, number: delimited(lines))
      )

  defp well_size(%{bytes: bytes}), do: format_bytes(bytes)

  @doc "A byte count in the words of the terminal's foot: \"812 B\", \"48.2 KB\", \"1.4 MB\"."
  def format_bytes(bytes) when bytes < 1024, do: gettext("%{number} B", number: bytes)

  def format_bytes(bytes) when bytes < 1024 * 1024,
    do: gettext("%{number} KB", number: Float.round(bytes / 1024, 1))

  def format_bytes(bytes),
    do: gettext("%{number} MB", number: Float.round(bytes / (1024 * 1024), 1))

  ## Words

  defp policy_source("fetched"), do: gettext("fetched from the run configuration")
  defp policy_source("config"), do: gettext("given to the runner as a policy document")
  defp policy_source("none"), do: gettext("no policy, every connection is observed")
  defp policy_source(_other), do: gettext("source n/a")

  @doc "The source of a policy in words, for the Details tab too."
  def policy_source_words(source), do: policy_source(source)

  defp exit_words(%{reason: "timeout"}), do: gettext("timeout")
  defp exit_words(%{reason: "runner_lost"}), do: gettext("runner lost")
  defp exit_words(%{signal: signal}) when is_binary(signal), do: signal

  defp exit_words(%{exit_code: code}) when is_integer(code),
    do: gettext("exit %{code}", code: code)

  defp exit_words(_item), do: gettext("n/a")

  defp result_words(item) do
    [
      item.outcome,
      item.turns &&
        ngettext("%{number} turn", "%{number} turns", item.turns, number: delimited(item.turns)),
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

  def pad(_sequence), do: gettext("n/a")

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
          ><:part name={:time}><time data-tick="seconds" data-since={DateTime.to_iso8601(@last_event_at)} aria-live="off">{ApiaryWeb.RunComponents.format_seconds(max(DateTime.diff(DateTime.utc_now(), @last_event_at), 0))}</time></:part></.rich>
        </span>
      </span>
    </p>
    """
  end

  def live_end(assigns) do
    ~H"""
    <p id="live-end" class="q-tail">
      {gettext("End of the record.")} {ngettext("%{number} event.", "%{number} events.", @events,
        number: delimited(@events)
      )}
    </p>
    """
  end

  ## rd14. Terminal

  @doc """
  The words the log's script says (`assets/js/hooks/terminal.js`), in the body's language,
  so the script holds none. A count's words are `[one, other]` with `%{number}` to fill:
  the script takes `one` for 1 and `other` for any other count, which is the plural rule
  of English and of the languages like it.
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
      dropped: gettext("The log stream dropped. Reconnecting.")
    }
  end

  defp forms(say), do: [say.(1), say.(2)]

  @doc """
  The terminal box: dark in both themes. The bar and the screen belong to the `Terminal`
  hook (`phx-update="ignore"`); the foot is the LiveView's, which sends numbers and never
  bytes. The hook reads the log from `src` and asks again when the LiveView says the log
  has advanced.

  `cols` and `rows` are the pseudo-terminal's size as the record last said it, or nil: a
  run on pipes, or one recorded before the runner reported the size. With a size the hook
  replays at the recorded size, each answer of `src` at the size its bytes were written
  to, and the box grows to the rows; without one it fits the screen to the box and offers
  to wrap.
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

  def terminal(assigns) do
    assigns = assign(assigns, :sized, is_integer(assigns.cols) and is_integer(assigns.rows))

    ~H"""
    <div
      id={@id}
      class="q-termbox"
      role="region"
      aria-label={gettext("Terminal output")}
      phx-hook="Terminal"
      data-src={@src}
      data-script={@script}
      data-stylesheet={@stylesheet}
      data-live={to_string(@live)}
      data-pty={to_string(@streams == ["terminal"])}
      data-through={@through}
      data-sized={to_string(@sized)}
      data-cols={@sized && @cols}
      data-rows={@sized && @rows}
      data-words={Jason.encode!(terminal_words())}
    >
      <div id={"#{@id}-bar"} class="q-term-bar" phx-update="ignore">
        <a class="sr-only focus:not-sr-only q-tbtn" href={@src <> "?download=1"} download>
          {gettext("Read the log as text")}
        </a>
        <div class="q-tseg" role="group" aria-label={gettext("Stream")}>
          <%= if length(@streams) > 1 do %>
            <button :for={stream <- @streams} type="button" data-stream={stream} aria-pressed="false">
              {stream}
            </button>
            <button type="button" data-stream="" aria-pressed="true">{gettext("both")}</button>
          <% else %>
            <span class="q-tseg-one">{List.first(@streams) || gettext("terminal")}</span>
          <% end %>
        </div>
        <label class="q-term-find">
          <.icon name="hero-magnifying-glass-micro" class="size-4" />
          <span class="sr-only">{gettext("Search the log")}</span>
          <input
            type="text"
            data-find
            spellcheck="false"
            autocomplete="off"
            placeholder={gettext("Search")}
          />
          <span data-find-count aria-live="polite"></span>
        </label>
        <button
          :if={!@sized}
          type="button"
          class="q-tbtn tooltip tooltip-left"
          data-tip={gettext("Wrap long lines")}
          aria-label={gettext("Wrap long lines")}
          aria-pressed="false"
          data-wrap
        >
          <.icon name="hero-bars-arrow-down-micro" class="size-4" />
        </button>
        <span
          :if={@sized}
          class="q-term-size tooltip tooltip-left"
          data-tip={gettext("The size the runtime ran at")}
          data-size
        >
          {@cols}×{@rows}
        </span>
        <a
          class="q-tbtn tooltip tooltip-left"
          data-tip={gettext("Download the raw bytes")}
          aria-label={gettext("Download the raw bytes")}
          href={@src <> "?download=1"}
          download
        >
          <.icon name="hero-arrow-down-tray-micro" class="size-4" />
        </a>
        <button type="button" class="q-tbtn" aria-pressed={to_string(@live)} data-follow>
          <.icon name="hero-arrow-down-micro" class="size-4" />
          <span class="q-tbtn-lbl" data-follow-label>{if @live,
            do: gettext("Following"),
            else: gettext("Jump to end")}</span>
        </button>
      </div>
      <div id={"#{@id}-screen"} class="q-term-screen" phx-update="ignore">
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
        <span>{format_bytes(@bytes)}</span>
        <span class="q-term-opt">
          {ngettext("%{number} chunk", "%{number} chunks", @chunks, number: delimited(@chunks))}
        </span>
        <span class="q-term-opt">{gettext("through #%{sequence}", sequence: pad(@through))}</span>
      </div>
    </div>
    <p class="mt-3 text-[12.5px] text-faint">
      {if @sized,
        do:
          gettext(
            "The bytes as the runtime wrote them, terminal escapes included, replayed at the size the runtime ran at. Nothing here is interpreted; the timeline is where the session is read."
          ),
        else:
          gettext(
            "The bytes as the runtime wrote them, terminal escapes included, fitted to this box. Nothing here is interpreted; the timeline is where the session is read."
          )}
    </p>
    """
  end
end
