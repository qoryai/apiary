defmodule ApiaryWeb.RunLive.Show do
  @moduledoc """
  One run, read as a record: the header from `run.started`, `run.exited` and the policy
  applied, and four tabs that are four live actions of this one LiveView, so that a tab is
  a `patch` and the header stays: Timeline, Terminal, Connections, Details.

  `:run_id` in the URL is the run's subject, the id the runner prints. A run that is not
  in the caller's hive renders the not-found state, whatever else it may be.

  The timeline is a stream over a window of the run's items (300 on mount, 200 more at
  either end, never more than 600 in the DOM); the layout of the whole run comes from
  `Apiary.Runs.Record.timeline/2`, so rails are right at a window's edge. The page follows
  the run's topic: projections are coalesced to one read per 250 ms, a changed item is
  updated in place, and a new item is inserted only while the reader is at the live end;
  away from it the pill counts. No log byte crosses the socket: the terminal reads
  `/hive/runs/:run_id/log`, and the LiveView only says how far the log has advanced.
  """
  use ApiaryWeb, :live_view

  import ApiaryWeb.RunPageComponents

  alias Apiary.Runs
  alias Apiary.Runs.{Record, Run}

  @window 300
  @page 200
  @max_dom 600
  @coalesce_ms 250
  @quiet_tick_ms 5_000
  @announce_every_ms 10_000
  @closable ~w(pending running lost)

  @wall_tip "The enclosure the agent runs in. Its only route out leads to the runner's proxy."
  @no_wall_tip "This run had no wall. A program that ignores the proxy is not seen."
  @mode_tip "Enforce: a connection no rule allows is denied. Observe: it is let through and recorded."
  @digest_tip "The sha256 of the policy this run ran under. Two runs with the same digest had the same policy."
  @terminated_tip "A host whose requests the proxy reads, because the run holds a credential or path rules for it. Every other host is a blind tunnel."
  @lane_tip "One agent's events: the main session, or a subagent from its start to its finish."

  @impl true
  def render(%{run: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:runs}
      width="full"
    >
      <.empty_state
        tone="neutral"
        icon="hero-magnifying-glass"
        heading="h1"
        title="This run is not in this hive"
      >
        The link may be for another <.term word="hive" />, or the run id is mistyped.
        <:actions>
          <.button navigate={~p"/hive/runs"}>Back to runs</.button>
        </:actions>
      </.empty_state>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:runs}
      width="full"
    >
      <div id="run-announcer" class="sr-only" aria-live="polite" aria-atomic="true">
        {@announcement}
      </div>

      <div class="q-run-head">
        <nav class="q-crumbs" aria-label="Breadcrumb">
          <.link navigate={~p"/hive/runs"}>Runs</.link>
          <%= if @run.forge && @run.repository do %>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <.link
              navigate={~p"/hive/runs?#{%{repo: "#{@run.forge}:#{@run.repository}"}}"}
              class="font-mono text-xs"
            >
              <span class="text-faint">{@run.forge}/</span>{@run.repository}
            </.link>
          <% end %>
          <.icon name="hero-chevron-right-micro" class="size-3" />
          <span class="font-mono text-xs" aria-current="page">{short_id(@run.run_id)}</span>
        </nav>

        <div class="q-run-title">
          <h1 :if={@run.task}>{@run.task}</h1>
          <h1 :if={!@run.task}>
            Run <span class="font-mono text-[17px]">{short_id(@run.run_id)}</span>
          </h1>
          <.run_state
            state={@run.state}
            exit_code={@run.exit_code}
            signal={@run.signal}
            quiet_for={@quiet_for}
            quiet_since={@run.last_heartbeat_at}
            interval={@run.heartbeat_interval_seconds}
            closed_at={@run.closed_at}
            note={false}
          />
          <span :if={@run.state == "pending"} class="text-[13px] text-faint">Ping only</span>
          <.alive
            state={@run.state}
            last_heartbeat_at={@run.last_heartbeat_at}
            last_event_at={@run.last_event_at}
            interval={@run.heartbeat_interval_seconds}
            quiet={@quiet_for != nil}
            run={@run}
          />
        </div>

        <.kvs id="run-facts">
          <.kv :if={ended?(@run)} label="Exit" mono>{exit_value(@run)}</.kv>
          <.kv label="Started">
            <.relative_time
              :if={@run.started_at}
              id="run-started"
              at={@run.started_at}
              format="clock"
            />
            <span :if={!@run.started_at} class="text-faint">n/a</span>
          </.kv>
          <.kv label="Duration">
            <.run_duration run={@run} quiet={@quiet_for != nil} />
          </.kv>
          <.kv label="Runtime" title={join([@run.runtime, @run.runtime_version])}>
            {@run.runtime || na()}
            <:sub :if={@run.runtime_version}>{@run.runtime_version}</:sub>
          </.kv>
          <.kv label="Host" mono title={@run.host}>{@run.host || na()}</.kv>
          <.kv label="Wall" tip={@tips.wall} title={join([@run.wall, @run.image])}>
            <%= cond do %>
              <% @run.wall -> %>
                {@run.wall}
              <% @run.state == "pending" -> %>
                {na()}
              <% true -> %>
                <span class="tooltip q-tip-wide" tabindex="0" data-tip={@tips.no_wall}>None</span>
            <% end %>
            <:sub :if={@run.wall && @run.image}>{@run.image}</:sub>
          </.kv>
          <.kv label="Policy">
            <.policy_value policy={@policy} digest={@run.policy_digest} tips={@tips} />
          </.kv>
        </.kvs>

        <div :if={ordered_labels(@run.labels) != []} class="q-labels">
          <span>Labels</span>
          <.label_chip
            :for={{key, value} <- ordered_labels(@run.labels)}
            key={to_string(key)}
            value={to_string(value)}
            navigate={label_path(@run, key, value)}
          />
        </div>
      </div>

      <.tabs id="run-tabs" label="Run">
        <:tab
          patch={tab_path(@run, :timeline, @timeline_query)}
          icon="hero-list-bullet-micro"
          current={@live_action == :timeline}
          count={@index.session_items > 0 && delimited(@index.session_items)}
        >
          Timeline
        </:tab>
        <:tab
          patch={tab_path(@run, :terminal)}
          icon="hero-command-line-micro"
          current={@live_action == :terminal}
        >
          Terminal
        </:tab>
        <:tab
          patch={tab_path(@run, :connections)}
          icon="hero-arrows-right-left-micro"
          current={@live_action == :connections}
          count={connections_count(@counts)}
          tone={@counts.denied > 0 && "error"}
        >
          Connections
        </:tab>
        <:tab
          patch={tab_path(@run, :details)}
          icon="hero-document-text-micro"
          current={@live_action == :details}
        >
          Details
        </:tab>
      </.tabs>

      <%= cond do %>
        <% @run.state == "pending" and @run.event_count <= 1 and @live_action != :details -> %>
          <.limits reason={:not_started} variant="empty" />
        <% @live_action == :timeline -> %>
          <.timeline_tab {assigns} />
        <% @live_action == :terminal -> %>
          <.terminal_tab run={@run} log={@log} />
        <% @live_action == :connections -> %>
          <.connections_tab
            run={@run}
            policy={@policy}
            connections={@connections}
            counts={@counts}
            decision={@decision}
          />
        <% @live_action == :details -> %>
          <.details_tab
            run={@run}
            policy={@policy}
            session_id={@session_id}
            closable={@run.state in @closable_states}
            tips={@tips}
          />
      <% end %>

      <.modal
        :if={@confirm_close}
        id="close-run"
        title="Close this run"
        on_cancel={JS.push("close_cancel")}
      >
        <p class="text-muted">
          The hive stops taking events for this run and the runner is told so on its next
          delivery. The record kept so far stays. A close is final: nothing reopens the run.
        </p>
        <:footer>
          <.button phx-click="close_cancel" data-autofocus>Cancel</.button>
          <.button variant="danger" phx-click="close_confirm" loading_text="Closing">Close run</.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  ## The tabs

  defp timeline_tab(assigns) do
    ~H"""
    <div id="run-timeline" class="grid gap-4" phx-hook="LiveEnd" data-live={to_string(alive?(@run))}>
      <div class="q-tl-bar" role="group" aria-label="Lanes">
        <.lane
          :for={lane <- @index.lanes}
          lane={lane}
          pressed={is_nil(@lane) or @lane == lane.id}
          patch={tab_path(@run, :timeline, lane_query(@timeline_query, @lane, lane.id))}
        />
        <span
          :if={length(@index.lanes) > 1}
          class="tooltip q-tip-wide text-faint"
          tabindex="0"
          data-tip={@tips.lane}
          aria-label={"lane (#{@tips.lane})"}
        >
          <.icon name="hero-information-circle-micro" class="size-4" />
        </span>
        <span class="flex-1"></span>
        <.shortcuts />
        <.link
          id="toggle-connections"
          patch={tab_path(@run, :timeline, cx_query(@timeline_query, @cx))}
          role="button"
          aria-pressed={to_string(@cx)}
          class={["q-chip", @cx && "q-chip-on q-chip-plain"]}
        >
          <.icon name="hero-arrows-right-left-micro" class="size-4" />Connections
          <b>{if @cx, do: "inline", else: "hidden"}</b>
        </.link>
      </div>

      <div :if={@unread > 0} id="unread-events">
        <.notice>
          {count_noun(@unread, "event has", "events have")} arrived and {if @unread == 1,
            do: "is",
            else: "are"} being read.
        </.notice>
      </div>

      <.limits
        :if={@limit}
        reason={@limit}
        runtime={@run.runtime}
        only_result={@limit == :vm_wall and @index.session_items > 0}
      />

      <.background_tasks background={@index.background} ended={!alive?(@run)} />

      <.timeline
        id="timeline"
        stream={@streams.items}
        rails={@index.rails}
        started_at={@run.started_at}
        seq_path={&tab_path(@run, :timeline, Map.put(@timeline_query, "seq", &1))}
        target={@target && "e-#{@target}"}
        isolate={@lane}
        connections={@cx}
        earlier={@earlier}
        later={max(@later - @new_count, 0)}
      />

      <.live_end
        live={alive?(@run)}
        events={@run.event_count}
        last_sequence={@run.projected_sequence > 0 && @run.projected_sequence}
        last_event_at={@run.last_event_at}
      />

      <.new_items
        id="new-events"
        count={@new_count}
        noun="event"
        target="#timeline"
        on_click="show_new"
      />
    </div>
    """
  end

  defp shortcuts(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button
        type="button"
        tabindex="0"
        class="btn btn-ghost btn-xs btn-square"
        aria-label="Keyboard shortcuts of the timeline"
      >
        <.icon name="hero-question-mark-circle-micro" class="size-4" />
      </button>
      <div tabindex="0" class="dropdown-content q-keys" role="note">
        <p class="font-medium">With focus in the timeline</p>
        <dl>
          <dt><kbd>j</kbd> <kbd>k</kbd></dt>
          <dd>next and previous item</dd>
          <dt><kbd>Enter</kbd></dt>
          <dd>open or close the item</dd>
          <dt><kbd>o</kbd></dt>
          <dd>open every tool call</dd>
          <dt><kbd>x</kbd> <kbd>Shift</kbd>+<kbd>x</kbd></dt>
          <dd>next and previous denied connection</dd>
          <dt><kbd>g</kbd> <kbd>e</kbd></dt>
          <dd>the live end</dd>
          <dt><kbd>g</kbd> <kbd>t</kbd></dt>
          <dd>the top</dd>
          <dt><kbd>c</kbd></dt>
          <dd>copy the item's link</dd>
        </dl>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :log, :map, required: true

  defp terminal_tab(assigns) do
    ~H"""
    <div>
      <.limits :if={@log.chunks == 0} reason={:no_log} variant="empty" live={alive?(@run)} />
      <.terminal
        :if={@log.chunks > 0}
        id="terminal"
        src={~p"/hive/runs/#{@run.run_id}/log"}
        script={~p"/assets/js/terminal.js"}
        stylesheet={~p"/assets/js/terminal.css"}
        streams={@log.streams}
        live={alive?(@run)}
        bytes={@log.bytes}
        chunks={@log.chunks}
        through={@log.through}
      />
    </div>
    """
  end

  attr :run, :map, required: true
  attr :policy, :any, required: true
  attr :connections, :list, required: true
  attr :counts, :map, required: true
  attr :decision, :string, default: nil

  defp connections_tab(assigns) do
    ~H"""
    <div class="grid gap-4">
      <.limits :if={@counts.all == 0} reason={:no_egress} variant="empty" />
      <div :if={@counts.all > 0} class="q-filters" role="group" aria-label="Filters">
        <.segments id="decision" label="Decision">
          <:segment
            patch={tab_path(@run, :connections)}
            pressed={is_nil(@decision)}
            count={@counts.all}
          >
            All
          </:segment>
          <:segment
            patch={tab_path(@run, :connections, %{"decision" => "allowed"})}
            pressed={@decision == "allowed"}
            count={@counts.allowed}
          >
            Allowed
          </:segment>
          <:segment
            patch={tab_path(@run, :connections, %{"decision" => "denied"})}
            pressed={@decision == "denied"}
            count={@counts.denied}
          >
            Denied
          </:segment>
        </.segments>
        <span class="flex-1"></span>
        <span class="q-summary">
          <span>
            <b>{delimited(@counts.attempts)}</b>
            {if @counts.attempts == 1, do: "attempt", else: "attempts"} to
            <b>{delimited(@counts.all)}</b>
            {if @counts.all == 1, do: "destination", else: "destinations"}
          </span>
          <span :if={@policy}>
            policy <b>{@policy.data["mode"]}</b>
            <span :if={@run.policy_digest} class="font-mono text-[12.5px]" title={@run.policy_digest}>
              {String.slice(@run.policy_digest, 0, 12)}
            </span>
          </span>
        </span>
      </div>
      <.connections_table
        :if={@counts.all > 0}
        id="run-connections"
        label="Connections of this run"
        rows={shown_connections(@connections, @decision)}
        started_at={@run.started_at}
      />
      <p :if={@counts.all > length(@connections)} class="text-[12.5px] text-faint">
        Showing {delimited(length(@connections))} of {delimited(@counts.all)} destinations.
      </p>
      <p :if={@counts.all > 0} class="max-w-[80ch] text-[12.5px] text-faint">
        Counted per host, port and path from the run's egress events. The reason and outcome are
        those of the last attempt. Only programs that honour the proxy are seen; {if @run.wall,
          do: "behind a wall, anything else fails unseen.",
          else: "without a wall, anything else connects unseen."}
      </p>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :policy, :any, required: true
  attr :session_id, :string, default: nil
  attr :closable, :boolean, required: true
  attr :tips, :map, required: true

  defp details_tab(assigns) do
    ~H"""
    <div class="q-cards">
      <section class="q-card" aria-labelledby="card-command">
        <h2 id="card-command">Command</h2>
        <dl class="q-dl">
          <dt>Command</dt>
          <dd class="font-mono">{@run.command || na()}</dd>
          <dt>Arguments</dt>
          <dd class="font-mono">
            <span :if={@run.args == []} class="font-sans text-faint">none</span>
            <span :for={arg <- Enum.take(@run.args, 64)} class="q-arg">{middle(arg, 600)}</span>
            <span :if={length(@run.args) > 64} class="font-sans text-faint">and {length(@run.args) -
              64} more</span>
          </dd>
          <dt>Directory</dt>
          <dd class="font-mono">{@run.dir || na()}</dd>
          <dt>Interactive</dt>
          <dd>{interactive_words(@run.interactive)}</dd>
          <dt>Runtime</dt>
          <dd>
            {@run.runtime || na()} <span class="font-mono text-faint">{@run.runtime_version}</span>
          </dd>
          <dt>Runner</dt>
          <dd class="font-mono">
            {@run.runner_version || "n/a"}<span :if={@run.contract_version}> · contract {@run.contract_version}</span>
          </dd>
          <dt>Host</dt>
          <dd class="font-mono">{@run.host || na()}</dd>
          <dt>Wall</dt>
          <dd>
            {@run.wall || "None"}
            <span :if={@run.image} class="font-mono text-faint">{@run.image}</span>
          </dd>
          <dt>Access key</dt>
          <dd>
            <%= if Ecto.assoc_loaded?(@run.access_key) && @run.access_key do %>
              {@run.access_key.label}
              <span class="font-mono text-faint">{@run.access_key.key_id}</span>
            <% else %>
              {na()}
            <% end %>
          </dd>
        </dl>
      </section>

      <section class="q-card" aria-labelledby="card-policy">
        <h2 id="card-policy">Policy in force</h2>
        <dl :if={@policy} class="q-dl">
          <dt>Mode</dt>
          <dd>
            <.term word={@policy.data["mode"] || "n/a"} standard={@tips.mode} class="q-tip-wide" />
          </dd>
          <dt>Source</dt>
          <dd>{policy_source_words(@policy.data["source"])}</dd>
          <dt><.term word="Digest" standard={@tips.digest} class="q-tip-wide tooltip-right" /></dt>
          <dd class="font-mono">
            {@run.policy_digest || "n/a"}
            <.copy_button
              :if={@run.policy_digest}
              id="copy-digest"
              text={@run.policy_digest}
              icon_only
              label="Copy the digest"
            />
          </dd>
          <dt>Run configuration</dt>
          <dd class="font-mono">
            {@run.run_configuration_digest || @run.reported_run_configuration_digest || "n/a"}
          </dd>
          <dt>Allowed hosts</dt>
          <dd class="font-mono">{strings(@policy.data["allow"]) || "none"}</dd>
          <dt>
            <.term
              word="Reads requests to"
              standard={@tips.terminated}
              class="q-tip-wide tooltip-right"
            />
          </dt>
          <dd class="font-mono">{strings(@policy.data["terminated"]) || "none"}</dd>
          <dt>Credentials</dt>
          <dd class="font-mono">{credential_names(@policy.data["credentials"]) || "none"}</dd>
          <dt>Applied at</dt>
          <dd class="font-mono">#{pad(@policy.sequence)}</dd>
        </dl>
        <p :if={!@policy} class="px-5 py-4 text-[13px] text-muted">
          No policy event has arrived for this run.
        </p>
      </section>

      <section class="q-card" aria-labelledby="card-record">
        <h2 id="card-record">Record</h2>
        <dl class="q-dl">
          <dt>Run id</dt>
          <dd class="font-mono">
            <span id="run-id">{@run.run_id}</span>
            <.copy_button id="copy-run-id" target="#run-id" icon_only label="Copy the run id" />
          </dd>
          <dt>State</dt>
          <dd>{state_label(@run.state)}<span :if={@run.reason}> · {@run.reason}</span></dd>
          <dt>Events</dt>
          <dd>
            {delimited(@run.event_count)}, projected through
            <span class="font-mono">#{pad(@run.projected_sequence)}</span>
          </dd>
          <dt>Last event</dt>
          <dd><.clock at={@run.last_event_at} id="last-event" /></dd>
          <dt>Last heartbeat</dt>
          <dd>
            <.clock at={@run.last_heartbeat_at} id="last-heartbeat" /><span :if={
              @run.heartbeat_interval_seconds
            }> · every {@run.heartbeat_interval_seconds} s</span><span :if={@run.elapsed_seconds}> · elapsed {@run.elapsed_seconds} s</span>
          </dd>
          <dt>Exited</dt>
          <dd><.clock at={@run.exited_at} id="exited-at" /></dd>
          <dt :if={@run.lost_at}>Lost</dt>
          <dd :if={@run.lost_at}><.clock at={@run.lost_at} id="lost-at" /></dd>
          <dt :if={@run.closed_at}>Closed</dt>
          <dd :if={@run.closed_at}><.clock at={@run.closed_at} id="closed-at" /> by a member</dd>
          <dt>Session</dt>
          <dd class="font-mono">{@session_id || "n/a"}</dd>
        </dl>
        <div :if={@closable} class="q-card-foot">
          <p>
            Closing tells the hive to take no more events for this run. It is for a run that went
            quiet and will not post its exit.
          </p>
          <.button id="close-run-button" variant="danger" phx-click="close">Close run</.button>
        </div>
      </section>
    </div>
    """
  end

  ## Small pieces of the header

  attr :run, :map, required: true
  attr :quiet, :boolean, required: true

  defp run_duration(assigns) do
    ~H"""
    <%= cond do %>
      <% is_integer(@run.duration_ms) -> %>
        <.duration ms={@run.duration_ms} />
      <% @run.state == "running" and not @quiet and @run.started_at != nil -> %>
        <.duration id="run-duration" running_since={@run.started_at} so_far />
      <% @run.state in ~w(running lost closed) and is_integer(@run.elapsed_seconds) -> %>
        <.duration at_least_seconds={@run.elapsed_seconds} />
      <% true -> %>
        <.duration />
    <% end %>
    """
  end

  attr :policy, :any, required: true
  attr :digest, :string, default: nil
  attr :tips, :map, required: true

  defp policy_value(%{policy: nil} = assigns), do: ~H|<span class="text-faint">n/a</span>|

  defp policy_value(%{policy: %{data: %{"source" => "none"}}} = assigns) do
    ~H"""
    <.term word="observe" standard={@tips.mode} class="q-tip-wide tooltip-left" />
    <small class="ml-1">no policy</small>
    """
  end

  defp policy_value(assigns) do
    ~H"""
    <.term word={@policy.data["mode"] || "n/a"} standard={@tips.mode} class="q-tip-wide tooltip-left" />
    <small :if={@digest} class="ml-1 font-mono" title={"sha256 #{@digest}"}>{String.slice(
      @digest,
      0,
      12
    )}</small>
    """
  end

  attr :at, :any, required: true
  attr :id, :string, required: true

  defp clock(assigns) do
    ~H"""
    <.relative_time :if={@at} id={@id} at={@at} format="clock" />
    <span :if={!@at} class="text-faint">n/a</span>
    """
  end

  defp na(assigns \\ %{}), do: ~H|<span class="text-faint">n/a</span>|

  ## Mount and parameters

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       run: nil,
       loaded_id: nil,
       page_title: "Run",
       tips: %{
         wall: @wall_tip,
         no_wall: @no_wall_tip,
         mode: @mode_tip,
         digest: @digest_tip,
         terminated: @terminated_tip,
         lane: @lane_tip
       },
       closable_states: @closable,
       confirm_close: false,
       announcement: nil,
       announced_at: nil,
       at_end: false,
       flush_scheduled: false,
       full: MapSet.new(),
       window_loaded: false
     )
     |> stream_configure(:items, dom_id: & &1.id)
     |> stream(:items, [])}
  end

  @impl true
  def handle_params(%{"run_id" => run_id} = params, _uri, socket) do
    socket = if socket.assigns.loaded_id == run_id, do: socket, else: load_run(socket, run_id)

    case socket.assigns.run do
      nil -> {:noreply, socket}
      %Run{} -> {:noreply, apply_params(socket, Map.delete(params, "run_id"))}
    end
  end

  defp load_run(socket, run_id) do
    scope = socket.assigns.current_scope

    case Record.fetch_run(scope, run_id) do
      {:ok, run} ->
        if connected?(socket) do
          Runs.subscribe(scope, run)
          Process.send_after(self(), :quiet_tick, @quiet_tick_ms)
        end

        socket
        |> assign(loaded_id: run_id, window_loaded: false, full: MapSet.new(), new_count: 0)
        |> assign_run(run)
        |> assign_record()

      :error ->
        assign(socket, run: nil, loaded_id: run_id, page_title: "Run not found")
    end
  end

  defp assign_run(socket, %Run{} = run) do
    assign(socket,
      run: run,
      quiet_for: quiet_for(run),
      page_title: "#{run.task || "Run #{short_id(run.run_id)}"} · Runs"
    )
  end

  # Everything read from the record beside the run row itself.
  defp assign_record(socket) do
    %{current_scope: scope, run: run} = socket.assigns
    connections = Record.connections(scope, run)

    assign(socket,
      index: Record.timeline(scope, run),
      policy: Record.policy(scope, run),
      session_id: Record.session_id(scope, run),
      log: Record.log_summary(scope, run),
      connections: connections,
      counts: connection_counts(connections)
    )
  end

  defp connection_counts(connections) do
    %{
      all: length(connections),
      allowed: Enum.count(connections, &(&1.allowed > 0)),
      denied: Enum.count(connections, &(&1.denied > 0)),
      attempts: connections |> Enum.map(& &1.attempts) |> Enum.sum()
    }
  end

  # Every parameter is validated against the record; what is not valid is dropped and the
  # URL is rewritten without it.
  defp apply_params(socket, params) do
    %{index: index, run: run, live_action: tab} = socket.assigns

    seq = tab == :timeline && sequence(params["seq"])
    target = seq && index.by_seq[seq]
    lane = tab == :timeline && Enum.find_value(index.lanes, &(&1.id == params["lane"] && &1.id))
    cx = not (tab == :timeline and params["cx"] == "0")

    decision =
      tab == :connections && params["decision"] in ~w(allowed denied) && params["decision"]

    timeline_query =
      %{}
      |> put_if("lane", lane || nil)
      |> put_if("cx", if(cx, do: nil, else: "0"))

    canonical =
      case tab do
        :timeline -> put_if(timeline_query, "seq", target && Integer.to_string(seq))
        :connections -> put_if(%{}, "decision", decision || nil)
        _ -> %{}
      end

    socket =
      assign(socket,
        target: target || nil,
        lane: lane || nil,
        cx: cx,
        decision: decision || nil,
        timeline_query: keep_timeline_query(socket, tab, timeline_query)
      )

    cond do
      canonical != params ->
        push_patch(socket, to: tab_path(run, tab, canonical), replace: true)

      tab == :timeline ->
        socket |> ensure_window() |> assign_window_counts()

      true ->
        assign(socket, window_loaded: false)
    end
  end

  # The other tabs link back to the timeline as the reader left it.
  defp keep_timeline_query(_socket, :timeline, query), do: query
  defp keep_timeline_query(socket, _tab, _query), do: socket.assigns[:timeline_query] || %{}

  defp sequence(value) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp sequence(_value), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp lane_query(query, current, lane_id) do
    if current == lane_id, do: Map.delete(query, "lane"), else: Map.put(query, "lane", lane_id)
  end

  defp cx_query(query, true), do: Map.put(query, "cx", "0")
  defp cx_query(query, false), do: Map.delete(query, "cx")

  defp tab_path(run, tab, query \\ %{})
  defp tab_path(%Run{run_id: id}, :timeline, query), do: ~p"/hive/runs/#{id}?#{query}"
  defp tab_path(%Run{run_id: id}, :terminal, query), do: ~p"/hive/runs/#{id}/terminal?#{query}"

  defp tab_path(%Run{run_id: id}, :connections, query),
    do: ~p"/hive/runs/#{id}/connections?#{query}"

  defp tab_path(%Run{run_id: id}, :details, query), do: ~p"/hive/runs/#{id}/details?#{query}"

  defp label_path(_run, "task", value), do: ~p"/hive/runs?#{%{task: value}}"

  defp label_path(%Run{forge: forge, repository: repository}, key, _value)
       when key in ~w(forge repository) and is_binary(forge) and is_binary(repository),
       do: ~p"/hive/runs?#{%{repo: "#{forge}:#{repository}"}}"

  defp label_path(_run, _key, _value), do: nil

  ## The window of the timeline

  # The stream holds a window of the index. It is loaded when the tab opens and when the
  # target is outside it; a parameter that only toggles a lane leaves it alone.
  defp ensure_window(socket) do
    %{target: target, window_loaded: loaded?} = socket.assigns

    cond do
      not loaded? -> reset_window(socket, target)
      target && not in_window?(socket, target) -> reset_window(socket, target)
      true -> socket
    end
  end

  defp in_window?(%{assigns: %{win_first: first, win_last: last}}, seq)
       when is_integer(first) and is_integer(last),
       do: seq >= first and seq <= last

  defp in_window?(_socket, _seq), do: false

  defp reset_window(socket, around) do
    items = socket.assigns.index.items

    start =
      case around && Enum.find_index(items, &(&1.seq == around)) do
        index when is_integer(index) -> max(index - div(@window, 2), 0)
        _ -> 0
      end

    put_window(socket, Enum.slice(items, start, @window))
  end

  defp reset_window_at_end(socket) do
    put_window(socket, Enum.take(socket.assigns.index.items, -@window))
  end

  defp put_window(socket, light) do
    socket
    |> stream(:items, build(socket, light), reset: true)
    |> assign(
      window_loaded: true,
      win_first: light |> List.first() |> then(&(&1 && &1.seq)),
      win_last: light |> List.last() |> then(&(&1 && &1.seq)),
      new_count: 0
    )
  end

  defp build(socket, light) do
    %{current_scope: scope, run: run, index: index, full: full} = socket.assigns
    Record.items(scope, run, index, light, full: MapSet.to_list(full))
  end

  defp assign_window_counts(socket) do
    %{index: index, win_first: first, win_last: last} = socket.assigns

    {earlier, later} =
      if is_integer(first),
        do:
          {Enum.count(index.items, &(&1.seq < first)), Enum.count(index.items, &(&1.seq > last))},
        else: {0, length(index.items)}

    unread = max(socket.assigns.run.event_count - socket.assigns.run.projected_sequence, 0)

    assign(socket,
      earlier: earlier,
      later: later,
      new_count: min(socket.assigns.new_count, later),
      unread: unread,
      limit: limit_reason(socket.assigns.run, index)
    )
  end

  # The window after items were added at one end: the DOM keeps #{@max_dom}, so the other
  # end moves in.
  defp trim_window(socket, :after_append) do
    %{index: index, win_last: last} = socket.assigns
    kept = index.items |> Enum.filter(&(&1.seq <= last)) |> Enum.take(-@max_dom)
    assign(socket, win_first: kept |> List.first() |> then(&(&1 && &1.seq)))
  end

  defp trim_window(socket, :after_prepend) do
    %{index: index, win_first: first} = socket.assigns
    kept = index.items |> Enum.filter(&(&1.seq >= first)) |> Enum.take(@max_dom)
    assign(socket, win_last: kept |> List.last() |> then(&(&1 && &1.seq)))
  end

  defp append(socket, light) do
    socket
    |> stream(:items, build(socket, light), at: -1, limit: -@max_dom)
    |> assign(
      win_last: List.last(light).seq,
      win_first: socket.assigns.win_first || hd(light).seq
    )
    |> trim_window(:after_append)
  end

  ## The limits of the record (P5), chosen from it in the brief's order

  defp limit_reason(%Run{state: "pending"}, _index), do: :not_started

  defp limit_reason(%Run{} = run, index) do
    settled? = not alive?(run) or older_than?(run.started_at, 60)

    cond do
      is_binary(run.runtime) and run.runtime != "claude" ->
        :other_runtime

      is_binary(run.wall) and index.hook_events == 0 and settled? ->
        :vm_wall

      run.runtime == "claude" and is_nil(run.wall) and index.session_items == 0 and settled? ->
        :no_hooks

      true ->
        nil
    end
  end

  defp older_than?(%DateTime{} = at, seconds), do: DateTime.diff(DateTime.utc_now(), at) > seconds
  defp older_than?(_at, _seconds), do: false

  ## Events from the page

  @impl true
  def handle_event("load_earlier", _params, socket) do
    %{index: index, win_first: first} = socket.assigns
    light = index.items |> Enum.filter(&(&1.seq < first)) |> Enum.take(-@page)

    socket =
      if light == [] do
        socket
      else
        socket
        # Prepending one by one reverses a list, so it is handed over reversed.
        |> stream(:items, socket |> build(light) |> Enum.reverse(), at: 0, limit: @max_dom)
        |> assign(win_first: hd(light).seq)
        |> trim_window(:after_prepend)
      end

    {:noreply, assign_window_counts(socket)}
  end

  def handle_event("load_later", _params, socket) do
    %{index: index, win_last: last} = socket.assigns
    light = index.items |> Enum.filter(&(&1.seq > (last || 0))) |> Enum.take(@page)
    socket = if light == [], do: socket, else: append(socket, light)
    {:noreply, assign_window_counts(socket)}
  end

  def handle_event("show_new", _params, socket) do
    %{index: index, win_last: last} = socket.assigns
    tail = Enum.filter(index.items, &(&1.seq > (last || 0)))
    first_new = tail |> Enum.take(-max(socket.assigns.new_count, 1)) |> List.first()

    socket =
      cond do
        tail == [] -> socket
        length(tail) <= @window -> append(socket, tail)
        true -> reset_window_at_end(socket)
      end

    {:noreply,
     socket
     |> assign(new_count: 0)
     |> assign_window_counts()
     |> push_event("timeline:end", %{focus: first_new && "e-#{first_new.seq}"})}
  end

  def handle_event("live_end", %{"at_end" => at_end}, socket) when is_boolean(at_end) do
    {:noreply, assign(socket, at_end: at_end)}
  end

  def handle_event("show_all", %{"seq" => seq}, socket) do
    with seq when is_integer(seq) <- sequence(seq),
         %{} = light <- Enum.find(socket.assigns.index.items, &(&1.seq == seq)),
         true <- in_window?(socket, seq) do
      socket = assign(socket, full: MapSet.put(socket.assigns.full, seq))
      {:noreply, stream(socket, :items, build(socket, [light]))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, confirm_close: socket.assigns.run.state in @closable)}
  end

  def handle_event("close_cancel", _params, socket),
    do: {:noreply, assign(socket, confirm_close: false)}

  def handle_event("close_confirm", _params, socket) do
    %{current_scope: scope, run: run} = socket.assigns

    socket =
      case Runs.close_run(scope, run) do
        {:ok, closed} ->
          socket |> follow_run(closed) |> put_flash(:info, "Run closed.")

        {:error, :unauthorized} ->
          put_flash(socket, :error, "You are no longer a member of this hive.")

        {:error, :not_found} ->
          put_flash(socket, :error, "This run is no longer in this hive.")
      end

    {:noreply, assign(socket, confirm_close: false)}
  end

  ## The run's topic

  @impl true
  def handle_info({:run_changed, %Run{} = run}, socket), do: {:noreply, follow_run(socket, run)}

  # At most one read per run per #{@coalesce_ms} ms, however many batches land.
  def handle_info({:run_projected, %Run{} = run, _first, _last}, socket) do
    socket = follow_run(socket, run)

    if socket.assigns.flush_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :flush, @coalesce_ms)
      {:noreply, assign(socket, flush_scheduled: true)}
    end
  end

  def handle_info(:flush, socket) do
    {:noreply, socket |> assign(flush_scheduled: false) |> refresh_record()}
  end

  # Quiet is the server's word: recomputed on a timer and on every batch, never by the page.
  def handle_info(:quiet_tick, socket) do
    Process.send_after(self(), :quiet_tick, @quiet_tick_ms)

    case socket.assigns.run do
      %Run{} = run ->
        was = socket.assigns.quiet_for
        now = quiet_for(run)

        socket =
          cond do
            is_nil(was) and now != nil -> announce(socket, "No heartbeat for #{now} s.", :now)
            true -> socket
          end

        socket = assign(socket, quiet_for: now)

        {:noreply,
         if(socket.assigns.live_action == :timeline and socket.assigns.window_loaded,
           do: assign(socket, limit: limit_reason(run, socket.assigns.index)),
           else: socket
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp follow_run(%{assigns: %{run: %Run{id: id} = old}} = socket, %Run{id: id} = run) do
    # The broadcast carries the row; the key it was posted with does not change.
    run = %{run | access_key: old.access_key}
    was_quiet? = socket.assigns.quiet_for != nil

    socket
    |> assign_run(run)
    |> announce_change(old, run, was_quiet?)
  end

  defp follow_run(socket, _run), do: socket

  defp announce_change(socket, %Run{state: state}, %Run{state: state} = run, was_quiet?) do
    if was_quiet? and is_nil(quiet_for(run)) and state == "running",
      do: announce(socket, "Heartbeats resumed.", :now),
      else: socket
  end

  defp announce_change(socket, _old, %Run{} = run, _was_quiet?) do
    announce(socket, state_sentence(run), :now)
  end

  defp state_sentence(%Run{state: "exited", duration_ms: ms}) when is_integer(ms),
    do: "Run exited after #{format_duration_ms(ms)}."

  defp state_sentence(%Run{state: "exited"}), do: "Run exited."

  defp state_sentence(%Run{state: "failed", signal: signal}) when is_binary(signal),
    do: "Run failed with #{signal}."

  defp state_sentence(%Run{state: "failed", exit_code: code}) when is_integer(code),
    do: "Run failed with exit #{code}."

  defp state_sentence(%Run{state: "failed"}), do: "Run failed."
  defp state_sentence(%Run{state: "timed_out"}), do: "Run timed out."

  defp state_sentence(%Run{state: "lost", heartbeat_interval_seconds: interval})
       when is_integer(interval),
       do: "Run lost. No heartbeat for #{interval * 3} s."

  defp state_sentence(%Run{state: "lost"}), do: "Run lost."
  defp state_sentence(%Run{state: "closed"}), do: "Run closed."
  defp state_sentence(%Run{state: "running"}), do: "Run started."
  defp state_sentence(%Run{}), do: nil

  defp announce(socket, nil, _when), do: socket
  # A state change is said at once, and holds the floor: "n new events" waits its turn.
  defp announce(socket, text, :now),
    do: assign(socket, announcement: text, announced_at: System.monotonic_time(:millisecond))

  # "n new events" is said at most once every ten seconds.
  defp announce(socket, text, :throttled) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.announced_at

    if is_nil(last) or now - last >= @announce_every_ms,
      do: assign(socket, announcement: text, announced_at: now),
      else: socket
  end

  # After a projection: the record is read again, and the timeline follows by difference.
  defp refresh_record(%{assigns: %{run: %Run{}}} = socket) do
    old = socket.assigns.index
    old_through = socket.assigns.log.through
    socket = assign_record(socket)

    socket =
      if socket.assigns.log.through > old_through,
        do: push_event(socket, "log_advanced", %{through: socket.assigns.log.through}),
        else: socket

    if socket.assigns.live_action == :timeline and socket.assigns.window_loaded,
      do: socket |> follow_timeline(old) |> assign_window_counts(),
      else: socket
  end

  defp refresh_record(socket), do: socket

  defp follow_timeline(socket, old) do
    %{index: new, win_first: first, win_last: last} = socket.assigns
    old_by_seq = Map.new(old.items, &{&1.seq, &1})
    new_seqs = MapSet.new(new.items, & &1.seq)
    old_last = old.items |> List.last() |> then(&((&1 && &1.seq) || 0))

    arrived = Enum.reject(new.items, &is_map_key(old_by_seq, &1.seq))
    {appended, inside} = Enum.split_with(arrived, &(&1.seq > old_last))

    cond do
      is_nil(first) ->
        # Nothing was on the page yet: the window starts with what arrived.
        reset_window(socket, socket.assigns.target)

      Enum.any?(inside, &(&1.seq > first and &1.seq < last)) ->
        # An event arrived late, inside the window: order is the sequence, so the window
        # is read again rather than patched.
        reset_window(socket, first)

      true ->
        gone =
          for item <- old.items,
              item.seq not in new_seqs,
              in_window?(socket, item.seq),
              do: item.seq

        changed =
          for item <- new.items,
              in_window?(socket, item.seq),
              old_by_seq[item.seq] != item,
              do: item

        socket = Enum.reduce(gone, socket, &stream_delete_by_dom_id(&2, :items, "e-#{&1}"))

        socket =
          if changed == [], do: socket, else: stream(socket, :items, build(socket, changed))

        at_tail? = last == old_last

        cond do
          appended == [] ->
            socket

          at_tail? and socket.assigns.at_end and socket.assigns.new_count == 0 ->
            append(socket, appended)

          true ->
            socket
            |> assign(new_count: socket.assigns.new_count + length(appended))
            |> announce("#{count_noun(length(appended), "new event")}.", :throttled)
        end
    end
  end

  ## Words

  defp alive?(%Run{state: state}), do: state in Run.alive_states()
  defp ended?(%Run{state: state}), do: state in ~w(exited failed timed_out)

  defp exit_value(%Run{reason: "timeout"}), do: "timeout"
  defp exit_value(%Run{reason: "runner_lost"}), do: "runner lost"
  defp exit_value(%Run{signal: signal}) when is_binary(signal) and signal != "", do: signal
  defp exit_value(%Run{exit_code: code}) when is_integer(code), do: Integer.to_string(code)
  defp exit_value(_run), do: "n/a"

  defp connections_count(%{denied: denied}) when denied > 0, do: "#{delimited(denied)} denied"
  defp connections_count(%{all: all}) when all > 0, do: delimited(all)
  defp connections_count(_counts), do: nil

  defp shown_connections(connections, "allowed"), do: Enum.filter(connections, &(&1.allowed > 0))
  defp shown_connections(connections, "denied"), do: Enum.filter(connections, &(&1.denied > 0))
  defp shown_connections(connections, _all), do: connections

  defp interactive_words(true), do: "Yes, on a pseudo-terminal"
  defp interactive_words(false), do: "No, on pipes"
  defp interactive_words(_unknown), do: "n/a"

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  # A list of strings from an event, bounded, joined for one cell.
  defp strings(list) when is_list(list) do
    strings = Enum.filter(list, &is_binary/1)

    case Enum.take(strings, 50) do
      [] ->
        nil

      shown when length(strings) > 50 ->
        Enum.join(shown, ", ") <> " and #{length(strings) - 50} more"

      shown ->
        Enum.join(shown, ", ")
    end
  end

  defp strings(_other), do: nil

  # Credentials by name, where each goes. Never a value: the event carries none.
  defp credential_names(list) when is_list(list) do
    list
    |> Enum.filter(&(is_map(&1) and is_binary(&1["name"])))
    |> Enum.take(20)
    |> Enum.map(fn credential ->
      hosts = strings(credential["hosts"])
      if hosts, do: "#{credential["name"]} (#{hosts})", else: credential["name"]
    end)
    |> case do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp credential_names(_other), do: nil
end
