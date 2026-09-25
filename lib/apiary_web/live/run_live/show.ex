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
  import ApiaryWeb.PolicyComponents, only: [short_digest: 1]

  alias Apiary.Policy
  alias Apiary.Runs
  alias Apiary.Runs.{Filters, Record, Run}
  alias Apiary.Runs.Record.Timeline
  alias ApiaryWeb.ConnectionLive.Rules

  @window 300
  @page 200
  @max_dom 600
  @coalesce_ms 250
  @quiet_tick_ms 5_000
  @announce_every_ms 10_000
  @max_versions 20
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
        title={gettext("This run is not in this hive")}
      >
        {gettext("The link may be for another hive, or the run id is mistyped.")}
        <:actions>
          <.button navigate={~p"/hive/runs"}>{gettext("Back to runs")}</.button>
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
        <nav class="q-crumbs" aria-label={gettext("Breadcrumb")}>
          <.link navigate={~p"/hive/runs"}>{gettext("Runs")}</.link>
          <%= if @run.target_system && @run.target_path do %>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <.link
              navigate={~p"/hive/runs?#{Filters.target_params(@run.target_system, @run.target_path)}"}
              class="font-mono text-xs"
            >
              <span class="text-faint">{@run.target_system}/</span>{@run.target_path}
            </.link>
          <% end %>
          <.icon name="hero-chevron-right-micro" class="size-3" />
          <span class="font-mono text-xs" aria-current="page">{short_id(@run.run_id)}</span>
        </nav>

        <div class="q-run-title">
          <h1 :if={@run.task} id="run-title" tabindex="-1" phx-hook="FocusOn">{@run.task}</h1>
          <h1 :if={!@run.task} id="run-title" tabindex="-1" phx-hook="FocusOn">
            <.rich text={
              rich_gettext("Run %{id}", id: {:m, short_id(@run.run_id), "font-mono text-[17px]"})
            } />
          </h1>
          <.run_state
            state={@run.state}
            exit_code={@run.exit_code}
            signal={@run.signal}
            quiet_for={@quiet_for}
            quiet_since={heard_at(@run)}
            interval={beat(@run)}
            closed_at={@run.closed_at}
            note={false}
          />
          <span :if={@run.state == "pending"} class="text-[13px] text-faint">
            {gettext("Ping only")}
          </span>
          <.alive
            state={@run.state}
            last_heartbeat_at={@run.last_heartbeat_at}
            last_event_at={@run.last_event_at}
            interval={beat(@run)}
            quiet={@quiet_for != nil}
            run={@run}
          />
        </div>

        <.kvs id="run-facts">
          <.kv :if={ended?(@run)} label={gettext("Exit")} mono>{exit_value(@run)}</.kv>
          <.kv label={gettext("Started")}>
            <.relative_time
              :if={@run.started_at}
              id="run-started"
              at={@run.started_at}
              format="clock"
            />
            <.na :if={!@run.started_at} />
          </.kv>
          <.kv label={gettext("Duration")}>
            <.run_duration run={@run} quiet={@quiet_for != nil} />
          </.kv>
          <.kv label={gettext("Runtime")} title={join([@run.runtime, @run.runtime_version])}>
            {@run.runtime || na()}
            <:sub :if={@run.runtime_version}>{@run.runtime_version}</:sub>
          </.kv>
          <.kv label={gettext("Host")} mono title={@run.host}>{@run.host || na()}</.kv>
          <.kv label={gettext("Wall")} tip={@tips.wall} title={join([@run.wall, @run.image])}>
            <%= cond do %>
              <% @run.wall -> %>
                {@run.wall}
              <% @run.state == "pending" -> %>
                {na()}
              <% true -> %>
                <span class="tooltip q-tip-wide" tabindex="0" data-tip={@tips.no_wall}>
                  {gettext("None")}
                </span>
            <% end %>
            <:sub :if={@run.wall && @run.image}>{@run.image}</:sub>
          </.kv>
          <.kv label={gettext("Policy")} class="q-kv-policy">
            <.policy_value
              policy={@policy}
              digest={@run.policy_digest}
              tips={@tips}
              version={@reported_version}
              reported={@digests.reported || @digests.applied}
              in_force={@in_force}
              last_seq={@run.projected_sequence}
            />
          </.kv>
        </.kvs>

        <.notice :if={@in_force} kind={:warning} class="max-w-[100ch]">
          <span id="run-behind">
            <b>{gettext("This run is behind the policy in force.")}</b>
            <.rich
              phx-no-format
              text={
                rich_gettext(
                  "It last reported %{reported}; %{in_force} is in force (%{since}).",
                  reported: {:part, :reported},
                  in_force: {:part, :in_force},
                  since: {:part, :since}
                )
              }
            >
              <:part name={:reported}>{version_words(@reported_version)}<span :if={@digests.reported}> <span class="font-mono text-xs">{short_digest(@digests.reported)}</span></span></:part>
              <:part name={:in_force}>{version_words(@in_force)} <span class="font-mono text-xs">{short_digest(@in_force.digest)}</span></:part>
              <:part name={:since}><.relative_time id="run-behind-since" at={@in_force.rendered_at} /></:part>
            </.rich>
            {if @reported_version,
              do:
                gettext(
                  "A run reloads at its next heartbeat; until it does, it decides by %{version}.",
                  version: version_words(@reported_version)
                ),
              else:
                gettext(
                  "A run reloads at its next heartbeat; until it does, it decides by what it holds."
                )}
          </span>
          <div class="mt-1">
            <.link
              id="run-behind-diff"
              navigate={behind_path(@reported_version, @in_force)}
              class="q-link"
            >
              {if comparable?(@reported_version, @in_force),
                do:
                  gettext("What changed between v%{from} and v%{to} of the %{label}",
                    from: @reported_version.n,
                    to: @in_force.n,
                    label: @in_force.label
                  ),
                else: gettext("Open %{version}", version: version_words(@in_force))}
            </.link>
          </div>
        </.notice>

        <div :if={ordered_labels(@run.labels) != []} class="q-labels">
          <span>{gettext("Labels")}</span>
          <.label_chip
            :for={{key, value} <- ordered_labels(@run.labels)}
            key={to_string(key)}
            value={to_string(value)}
            navigate={label_path(@run, key, value)}
          />
        </div>
      </div>

      <.tabs id="run-tabs" label={gettext("Run")}>
        <:tab
          patch={tab_path(@run, :timeline, @timeline_query)}
          icon="hero-list-bullet-micro"
          current={@live_action == :timeline}
          count={@index.session_items > 0 && delimited(@index.session_items)}
        >
          {gettext("Timeline")}
        </:tab>
        <:tab
          patch={tab_path(@run, :terminal)}
          icon="hero-command-line-micro"
          current={@live_action == :terminal}
        >
          {gettext("Terminal")}
        </:tab>
        <:tab
          patch={tab_path(@run, :connections)}
          icon="hero-arrows-right-left-micro"
          current={@live_action == :connections}
          count={connections_count(@counts)}
          tone={@counts.denied > 0 && "error"}
        >
          {gettext("Connections")}
        </:tab>
        <:tab
          patch={tab_path(@run, :details)}
          icon="hero-document-text-micro"
          current={@live_action == :details}
        >
          {gettext("Details")}
        </:tab>
      </.tabs>

      <%= cond do %>
        <% not @loaded -> %>
          <div
            id="run-loading"
            class="grid gap-3"
            aria-busy="true"
            aria-label={gettext("Reading the record")}
          >
            <span :for={width <- ~w(w-2/3 w-1/2 w-3/5 w-2/5 w-1/2)} class={["q-skel", width]}></span>
          </div>
        <% @run.state == "pending" and @index.items == [] and @live_action != :details -> %>
          <.limits reason={:not_started} variant="empty" />
        <% @run.events_pruned_at && @index.items == [] && @live_action == :timeline -> %>
          <.limits reason={:pruned} variant="empty" at={@run.events_pruned_at} />
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
            acts={@acts}
            version={@reported_version}
            in_force={@in_force}
          />
        <% @live_action == :details -> %>
          <.details_tab
            run={@run}
            policy={@policy}
            session_id={@session_id}
            closable={@run.state in Runs.closable_states()}
            tips={@tips}
            version={@reported_version}
            in_force={@in_force}
            digests={@digests}
          />
      <% end %>

      <.modal
        :if={@confirm_close}
        id="close-run"
        title={gettext("Close this run")}
        on_cancel={JS.push("close_cancel")}
      >
        <p class="text-muted">
          {gettext(
            "The hive stops taking events for this run and the runner is told so on its next delivery. The record kept so far stays. A close is final: nothing reopens the run."
          )}
        </p>
        <:footer>
          <.button phx-click="close_cancel" data-autofocus>{gettext("Cancel")}</.button>
          <.button variant="danger" phx-click="close_confirm" loading_text={gettext("Closing")}>
            {gettext("Close run")}
          </.button>
        </:footer>
      </.modal>

      <.rule_popover :if={@popover} popover={@popover} />
    </Layouts.app>
    """
  end

  ## The tabs

  defp timeline_tab(assigns) do
    ~H"""
    <div id="run-timeline" class="grid gap-4" phx-hook="LiveEnd" data-live={to_string(alive?(@run))}>
      <div class="q-tl-bar" role="group" aria-label={gettext("Lanes")}>
        <.lane
          :for={lane <- lane_chips(@index, @lane)}
          lane={lane}
          pressed={is_nil(@lane) or @lane == lane.id}
          patch={tab_path(@run, :timeline, lane_query(@timeline_query, @lane, lane.id))}
        />
        <span
          :if={@index.lane_count + 1 > length(@index.lanes)}
          id="more-lanes"
          class="text-xs text-faint"
        >
          {gettext("and %{number} more",
            number: delimited(@index.lane_count + 1 - length(@index.lanes))
          )}
        </span>
        <span
          :if={length(@index.lanes) > 1}
          class="tooltip q-tip-wide text-faint"
          tabindex="0"
          data-tip={@tips.lane}
          aria-label={gettext("lane (%{tip})", tip: @tips.lane)}
        >
          <.icon name="hero-information-circle-micro" class="size-4" />
        </span>
        <span class="flex-1"></span>
        <.shortcuts />
        <button
          type="button"
          id="toggle-connections"
          phx-click={JS.patch(tab_path(@run, :timeline, cx_query(@timeline_query, @cx)))}
          aria-pressed={to_string(@cx)}
          class={["q-chip", @cx && "q-chip-on q-chip-plain"]}
        >
          <.icon name="hero-arrows-right-left-micro" class="size-4" />{gettext("Connections")}
          <b>{if @cx, do: gettext("inline"), else: gettext("hidden")}</b>
        </button>
      </div>

      <div :if={@unread > 0} id="unread-events">
        <.notice>
          {ngettext(
            "%{number} event has arrived and is being read.",
            "%{number} events have arrived and are being read.",
            @unread,
            number: delimited(@unread)
          )}
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
        target={@focused && "e-#{@focused}"}
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
        aria-label={gettext("Keyboard shortcuts of the timeline")}
      >
        <.icon name="hero-question-mark-circle-micro" class="size-4" />
      </button>
      <div tabindex="0" class="dropdown-content q-keys" role="note">
        <p class="font-medium">{gettext("With focus in the timeline")}</p>
        <dl>
          <dt><kbd>j</kbd> <kbd>k</kbd></dt>
          <dd>{gettext("next and previous item")}</dd>
          <dt><kbd>{gettext("Enter")}</kbd></dt>
          <dd>{gettext("open or close the item")}</dd>
          <dt><kbd>o</kbd></dt>
          <dd>{gettext("open every tool call")}</dd>
          <dt><kbd>x</kbd> <kbd>{gettext("Shift")}</kbd>+<kbd>x</kbd></dt>
          <dd>{gettext("next and previous denied connection")}</dd>
          <dt><kbd>g</kbd> <kbd>e</kbd></dt>
          <dd>{gettext("the live end")}</dd>
          <dt><kbd>g</kbd> <kbd>t</kbd></dt>
          <dd>{gettext("the top")}</dd>
          <dt><kbd>c</kbd></dt>
          <dd>{gettext("copy the item's link")}</dd>
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
      <.limits
        :if={@log.chunks == 0 and is_nil(@run.log_pruned_at)}
        reason={:no_log}
        variant="empty"
        live={alive?(@run)}
      />
      <.limits
        :if={@log.chunks == 0 and @run.log_pruned_at}
        reason={if @run.events_pruned_at, do: :pruned, else: :log_pruned}
        variant="empty"
        at={@run.log_pruned_at}
      />
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
        cols={@run.terminal_cols}
        rows={@run.terminal_rows}
      />
    </div>
    """
  end

  attr :run, :map, required: true
  attr :policy, :any, required: true
  attr :connections, :list, required: true
  attr :counts, :map, required: true
  attr :decision, :string, default: nil
  attr :acts, :map, default: nil
  attr :version, :any, default: nil
  attr :in_force, :any, default: nil

  defp connections_tab(assigns) do
    ~H"""
    <div class="grid gap-4">
      <.limits :if={@counts.all == 0} reason={:no_egress} variant="empty" />
      <div :if={@counts.all > 0} class="q-filters" role="group" aria-label={gettext("Filters")}>
        <.segments id="decision" label={gettext("Decision")}>
          <:segment
            patch={tab_path(@run, :connections)}
            pressed={is_nil(@decision)}
            count={@counts.all}
          >
            {gettext("All")}
          </:segment>
          <:segment
            patch={tab_path(@run, :connections, %{"decision" => "allowed"})}
            pressed={@decision == "allowed"}
            count={@counts.allowed}
          >
            {gettext("Allowed")}
          </:segment>
          <:segment
            patch={tab_path(@run, :connections, %{"decision" => "denied"})}
            pressed={@decision == "denied"}
            count={@counts.denied}
          >
            {gettext("Denied")}
          </:segment>
        </.segments>
        <span class="flex-1"></span>
        <span class="q-summary">
          <span>
            <.rich text={
              rich_gettext("%{attempts} to %{destinations}",
                attempts:
                  rich_ngettext("%{number} attempt", "%{number} attempts", @counts.attempts,
                    number: {:b, delimited(@counts.attempts)}
                  ),
                destinations:
                  rich_ngettext("%{number} destination", "%{number} destinations", @counts.all,
                    number: {:b, delimited(@counts.all)}
                  )
              )
            } />
          </span>
          <span :if={@policy}>
            {gettext("policy")} <b>{@policy.mode}</b>
            <.scoped_version :if={@version} version={@version} />
            <span
              :if={!@version && @run.policy_digest}
              class="font-mono text-[12.5px]"
              title={@run.policy_digest}
            >
              {String.slice(@run.policy_digest, 0, 12)}
            </span>
            <.drift
              :if={@in_force}
              id="connections-drift"
              reported={@version}
              in_force={@in_force}
              last_seq={@run.projected_sequence}
            />
          </span>
        </span>
      </div>
      <.connections_table
        :if={@counts.all > 0}
        id="run-connections"
        label={gettext("Connections of this run")}
        rows={@connections.rows}
        started_at={@run.started_at}
        acts={@acts}
      />
      <div
        :if={@connections.total > 0}
        id="connections-pages"
        class="flex flex-wrap items-center justify-between gap-3"
      >
        <p class="text-[12.5px] text-faint">
          {gettext("Showing %{shown} of %{total}.",
            shown: delimited(length(@connections.rows)),
            total: delimited(@connections.total)
          )}
        </p>
        <div :if={@connections.pages > 1} class="flex gap-2">
          <.button
            :if={@connections.page > 1}
            patch={tab_path(@run, :connections, connections_query(@decision, @connections.page - 1))}
          >
            {gettext("Previous")}
          </.button>
          <.button
            :if={@connections.page < @connections.pages}
            patch={tab_path(@run, :connections, connections_query(@decision, @connections.page + 1))}
          >
            {gettext("Next")}
          </.button>
        </div>
      </div>
      <p :if={@counts.all > 0} id="connections-footnote" class="max-w-[80ch] text-[12.5px] text-faint">
        {gettext(
          "Counted per host, port and path from the run's egress events. The reason and outcome are those of the last attempt. A rule added here changes what happens next; what the record already says stays as it was."
        )}
      </p>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :policy, :any, required: true
  attr :session_id, :string, default: nil
  attr :closable, :boolean, required: true
  attr :tips, :map, required: true
  attr :version, :any, default: nil
  attr :in_force, :any, default: nil
  attr :digests, :map, required: true

  defp details_tab(assigns) do
    ~H"""
    <div class="q-cards">
      <section class="q-card" aria-labelledby="card-command">
        <h2 id="card-command">{gettext("Command")}</h2>
        <dl class="q-dl">
          <dt>{gettext("Command")}</dt>
          <dd class="font-mono">{@run.command || na()}</dd>
          <dt>{gettext("Arguments")}</dt>
          <dd class="font-mono">
            <span :if={@run.args == []} class="font-sans text-faint">{gettext("none")}</span>
            <span :for={arg <- Enum.take(@run.args, 64)} class="q-arg">{middle(arg, 600)}</span>
            <span :if={length(@run.args) > 64} class="font-sans text-faint">
              {gettext("and %{number} more", number: delimited(length(@run.args) - 64))}
            </span>
          </dd>
          <dt>{gettext("Directory")}</dt>
          <dd class="font-mono">{@run.dir || na()}</dd>
          <dt>{gettext("Interactive")}</dt>
          <dd>{interactive_words(@run.interactive)}</dd>
          <dt :if={@run.terminal_cols}>{gettext("Terminal")}</dt>
          <dd :if={@run.terminal_cols} class="font-mono">
            {@run.terminal_cols}×{@run.terminal_rows}
          </dd>
          <dt>{gettext("Runtime")}</dt>
          <dd>
            {@run.runtime || na()} <span class="font-mono text-faint">{@run.runtime_version}</span>
          </dd>
          <dt>{gettext("Runner")}</dt>
          <dd class="font-mono">
            {@run.runner_version || gettext("n/a")}<span :if={@run.contract_version}> · {gettext(
              "contract %{version}",
              version: @run.contract_version
            )}</span>
          </dd>
          <dt>{gettext("Host")}</dt>
          <dd class="font-mono">{@run.host || na()}</dd>
          <dt>{gettext("Wall")}</dt>
          <dd>
            {@run.wall || gettext("None")}
            <span :if={@run.image} class="font-mono text-faint">{@run.image}</span>
          </dd>
          <dt>{gettext("Access key")}</dt>
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
        <h2 id="card-policy">{gettext("Policy in force")}</h2>
        <dl :if={@policy} class="q-dl">
          <dt>{gettext("Mode")}</dt>
          <dd>
            <.term word={@policy.mode || gettext("n/a")} standard={@tips.mode} class="q-tip-wide" />
          </dd>
          <dt>{gettext("Source")}</dt>
          <dd>{policy_source_words(@policy.source)}</dd>
          <dt>
            <.term word={gettext("Digest")} standard={@tips.digest} class="q-tip-wide tooltip-right" />
          </dt>
          <dd class="font-mono">
            {@run.policy_digest || gettext("n/a")}
            <.copy_button
              :if={@run.policy_digest}
              id="copy-digest"
              text={@run.policy_digest}
              icon_only
              label={gettext("Copy the digest")}
            />
          </dd>
          <dt>{gettext("Run configuration")}</dt>
          <dd class="font-mono">
            {@run.run_configuration_digest || @run.reported_run_configuration_digest || gettext("n/a")}
          </dd>
          <dt :if={@version}>{gettext("Version")}</dt>
          <dd :if={@version} id="policy-version">
            <.scoped_version version={@version} />
          </dd>
          <dt :if={@version && @digests.in_force}>{gettext("In force now")}</dt>
          <dd :if={@version && @digests.in_force} id="policy-in-force">
            <.scoped_version :if={@in_force} version={@in_force} />
            <span :if={!@in_force && @digests.in_force == @version.digest}>{gettext("the same")}</span>
            <span :if={!@in_force && @digests.in_force != @version.digest} class="font-mono">
              {short_digest(@digests.in_force)}
            </span>
          </dd>
          <dt>{gettext("Allowed hosts")}</dt>
          <dd class="font-mono">{strings(@policy.allow, @policy.allow_count) || gettext("none")}</dd>
          <dt>{gettext("Denied hosts")}</dt>
          <dd class="font-mono">{strings(@policy.deny, @policy.deny_count) || gettext("none")}</dd>
          <dt>
            <.term
              word={gettext("Reads requests to")}
              standard={@tips.terminated}
              class="q-tip-wide tooltip-right"
            />
          </dt>
          <dd class="font-mono">
            {strings(@policy.terminated, @policy.terminated_count) || gettext("none")}
          </dd>
          <dt>{gettext("Credentials")}</dt>
          <dd class="font-mono">{named_hosts(@policy.credentials) || gettext("none")}</dd>
          <dt>
            <.term word={gettext("Tools")} standard={@tips.tools} class="q-tip-wide tooltip-right" />
          </dt>
          <dd id="policy-tools" class="font-mono">
            {named_hosts(@policy.tools) || gettext("none")}
          </dd>
          <dt>{pgettext("plain", "Applied at")}</dt>
          <dd class="font-mono">#{pad(@policy.sequence)}</dd>
        </dl>
        <p :if={!@policy} class="px-5 py-4 text-[13px] text-muted">
          {if @run.events_pruned_at,
            do:
              gettext("The policy event was pruned with the run's events on %{date}.",
                date: short_date(@run.events_pruned_at)
              ),
            else: gettext("No policy event has arrived for this run.")}
        </p>
      </section>

      <section class="q-card" aria-labelledby="card-record">
        <h2 id="card-record">{gettext("Record")}</h2>
        <dl class="q-dl">
          <dt>{gettext("Run id")}</dt>
          <dd class="font-mono">
            <span id="run-id">{@run.run_id}</span>
            <.copy_button
              id="copy-run-id"
              target="#run-id"
              icon_only
              label={gettext("Copy the run id")}
            />
          </dd>
          <dt>{gettext("State")}</dt>
          <dd>{state_label(@run.state)}<span :if={@run.reason}> · {@run.reason}</span></dd>
          <dt>{gettext("Events")}</dt>
          <dd>
            <.rich text={
              rich_gettext("%{number}, projected through %{sequence}",
                number: delimited(@run.event_count),
                sequence: {:m, "#" <> pad(@run.projected_sequence), "font-mono"}
              )
            } />
          </dd>
          <dt>{gettext("Last event")}</dt>
          <dd><.clock at={@run.last_event_at} id="last-event" /></dd>
          <dt>{gettext("Last heartbeat")}</dt>
          <dd>
            <.clock at={@run.last_heartbeat_at} id="last-heartbeat" /><span :if={
              @run.heartbeat_interval_seconds
            }> · {gettext("every %{seconds} s", seconds: @run.heartbeat_interval_seconds)}</span><span :if={
              @run.elapsed_seconds
            }> · {gettext("elapsed %{seconds} s", seconds: @run.elapsed_seconds)}</span>
          </dd>
          <dt>{gettext("Exited")}</dt>
          <dd><.clock at={@run.exited_at} id="exited-at" /></dd>
          <dt :if={@run.lost_at}>{gettext("Lost")}</dt>
          <dd :if={@run.lost_at}><.clock at={@run.lost_at} id="lost-at" /></dd>
          <dt :if={@run.closed_at}>{gettext("Closed")}</dt>
          <dd :if={@run.closed_at}>
            <.rich phx-no-format text={rich_gettext("%{time} by a member", time: {:part, :time})}><:part name={:time}><.clock at={@run.closed_at} id="closed-at" /></:part></.rich>
          </dd>
          <dt>{gettext("Session")}</dt>
          <dd class="font-mono">{@session_id || gettext("n/a")}</dd>
        </dl>
        <div :if={@closable} class="q-card-foot">
          <p>
            {gettext(
              "Closing tells the hive to take no more events for this run. It is for a run that went quiet and will not post its exit."
            )}
          </p>
          <.button id="close-run-button" variant="danger" phx-click="close">
            {gettext("Close run")}
          </.button>
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
      <% @run.state == "running" and not @quiet -> %>
        <%!-- The runner's own elapsed seconds plus this server's time since they were true. --%>
        <.duration
          id="run-duration"
          elapsed_seconds={elem(elapsed(@run), 0)}
          elapsed_at={elem(elapsed(@run), 1)}
          so_far
        />
      <% @run.state in ~w(running lost closed) and is_integer(@run.elapsed_seconds) -> %>
        <.duration at_least_seconds={@run.elapsed_seconds} />
      <% true -> %>
        <.duration />
    <% end %>
    """
  end

  # pd9. The mode, then the version the run last reported as a link to that exact version,
  # then its digest; the drift mark takes the digest's place while the run is behind.
  attr :policy, :any, required: true
  attr :digest, :string, default: nil, doc: "the runner's own digest of its policy document"
  attr :tips, :map, required: true

  attr :version, :any,
    default: nil,
    doc: "the version the reported digest names here, when one does"

  attr :reported, :string, default: nil, doc: "the run configuration digest the run reported"
  attr :in_force, :any, default: nil, doc: "the version in force, only while the run is behind"
  attr :last_seq, :integer, default: nil

  defp policy_value(%{policy: nil} = assigns), do: ~H|<.na />|

  defp policy_value(%{policy: %{source: "none"}} = assigns) do
    ~H"""
    <.term word="observe" standard={@tips.mode} class="q-tip-wide tooltip-left" />
    <small class="ml-1">{gettext("no policy")}</small>
    """
  end

  defp policy_value(assigns) do
    ~H"""
    <.term
      word={@policy.mode || gettext("n/a")}
      standard={@tips.mode}
      class="q-tip-wide tooltip-left"
    />
    <%= cond do %>
      <% @version -> %>
        <.scoped_version
          version={@version}
          class="ml-1"
          title={
            gettext(
              "Version %{n} of the %{label}, sha256 %{digest}. Open the exact document.",
              n: @version.n,
              label: @version.label,
              digest: short_digest(@version.digest)
            )
          }
        />
        <small :if={!@in_force} class="ml-1 font-mono" title={@version.digest}>
          {short_digest(@version.digest)}
        </small>
      <% @reported -> %>
        <span id="policy-unrendered" tabindex="0" title={@tips.unrendered}>
          <small class="ml-1 font-mono">{short_digest(@reported)}</small>
          <small>· {gettext("not rendered here")}</small>
        </span>
      <% @digest -> %>
        <small class="ml-1 font-mono" title={gettext("sha256 %{digest}", digest: @digest)}>
          {String.slice(@digest, 0, 12)}
        </small>
      <% true -> %>
    <% end %>
    <.drift :if={@in_force} reported={@version} in_force={@in_force} last_seq={@last_seq} />
    """
  end

  attr :at, :any, required: true
  attr :id, :string, required: true

  defp clock(assigns) do
    ~H"""
    <.relative_time :if={@at} id={@id} at={@at} format="clock" />
    <.na :if={!@at} />
    """
  end

  defp na(assigns \\ %{}), do: ~H|<span class="text-faint">{gettext("n/a")}</span>|

  # The tips of the page's terms, in the body's words.
  defp tips do
    %{
      wall:
        gettext(
          "The enclosure the agent runs in. Its only route out leads to the runner's proxy."
        ),
      no_wall: gettext("This run had no wall. A program that ignores the proxy is not seen."),
      mode:
        gettext(
          "Enforce: a connection no rule allows is denied. Observe: it is let through and recorded. A deny rule holds in either mode."
        ),
      digest:
        gettext(
          "The sha256 of the policy this run ran under. Two runs with the same digest had the same policy."
        ),
      terminated:
        gettext(
          "A host whose requests the proxy reads, because the run holds a credential, a tool or path rules for it. Every other host is a blind tunnel."
        ),
      tools:
        gettext(
          "Programs on the runner's machine that serve hosts. The proxy hands a request to such a host to its tool when the rules let it through: a tool invocation. One a path rule refused never reaches the tool."
        ),
      lane:
        gettext(
          "One agent's events: the main session, or a subagent from its start to its finish."
        ),
      unrendered:
        gettext(
          "The run reported a digest that matches no version rendered here: a policy file on the machine, or a run started with --local."
        )
    }
  end

  ## Mount and parameters

  @impl true
  def mount(_params, _session, socket) do
    # The policy's topic is followed from mount: the sidebar's hook looks, before the first
    # handle_params, at whether the page subscribed, and stops the message at itself when
    # it did not. Subscribing any later is both a second subscription and a deaf page.
    if connected?(socket), do: Policy.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       run: nil,
       loaded_id: nil,
       loaded: false,
       page_title: gettext("Run"),
       tips: tips(),
       confirm_close: false,
       announcement: nil,
       announced_at: nil,
       at_end: false,
       flush_scheduled: false,
       range: nil,
       full: MapSet.new(),
       window_loaded: false,
       index: Timeline.new(),
       policy: nil,
       target: nil,
       digests: %{in_force: nil, reported: nil, applied: nil, drift: false},
       reported_version: nil,
       in_force: nil,
       versions: %{},
       effective: nil,
       acts: nil,
       popover: nil,
       policy_flush_scheduled: false,
       session_id: nil,
       counts: %{all: 0, allowed: 0, denied: 0, attempts: 0},
       connections: %{rows: [], page: 1, pages: 1, total: 0},
       log: %{chunks: 0, bytes: 0, through: 0, streams: []},
       focused: nil,
       lane: nil,
       cx: true,
       decision: nil,
       timeline_query: %{},
       new_count: 0,
       earlier: 0,
       later: 0,
       unread: 0,
       limit: nil,
       win_first: nil,
       win_last: nil
     )
     |> stream_configure(:items, dom_id: & &1.id)
     |> stream(:items, [])}
  end

  @impl true
  def handle_params(%{"run_id" => run_id} = params, _uri, socket) do
    socket = if socket.assigns.loaded_id == run_id, do: socket, else: load_run(socket, run_id)

    case socket.assigns do
      %{run: %Run{}, loaded: true} ->
        {:noreply, apply_params(socket, Map.delete(params, "run_id"))}

      _ ->
        {:noreply, socket}
    end
  end

  # The run row is read for the first, static render too: it says found or not found, and
  # gives the header. Everything else waits for the socket, so that opening the page reads
  # the record once, not twice.
  defp load_run(socket, run_id) do
    scope = socket.assigns.current_scope

    case Record.fetch_run(scope, run_id) do
      {:ok, run} ->
        socket = socket |> assign(loaded_id: run_id, new_count: 0) |> assign_run(run)

        if connected?(socket) do
          # Subscribed before the read, so nothing projected after it is missed.
          Runs.subscribe(scope, run)
          Process.send_after(self(), :quiet_tick, @quiet_tick_ms)

          socket
          |> assign(
            loaded: true,
            window_loaded: false,
            full: MapSet.new(),
            index: Record.timeline(scope, run),
            policy: Record.policy(scope, run),
            counts: Record.connection_counts(scope, run),
            target: target_of(scope, run),
            versions: %{},
            effective: nil,
            acts: nil,
            popover: nil
          )
          |> assign_policy_facts()
        else
          socket
        end

      :error ->
        assign(socket, run: nil, loaded_id: run_id, page_title: gettext("Run not found"))
    end
  end

  defp assign_run(socket, %Run{} = run) do
    assign(socket,
      run: run,
      quiet_for: quiet_for(run),
      page_title:
        gettext("%{title} · Runs",
          title: run.task || gettext("Run %{id}", id: short_id(run.run_id))
        )
    )
  end

  # Every parameter is validated against the record; what is not valid is dropped and the
  # URL is rewritten without it.
  defp apply_params(socket, params) do
    %{index: index, run: run, live_action: tab} = socket.assigns

    seq = tab == :timeline && sequence(params["seq"])
    focused = seq && index.by_seq[seq]
    lane = tab == :timeline && Timeline.lane(index, params["lane"])
    cx = not (tab == :timeline and params["cx"] == "0")

    decision =
      tab == :connections && params["decision"] in ~w(allowed denied) && params["decision"]

    page = (tab == :connections && sequence(params["page"])) || 1

    timeline_query =
      %{}
      |> put_if("lane", lane && lane.id)
      |> put_if("cx", if(cx, do: nil, else: "0"))

    socket =
      socket
      |> assign(
        focused: focused || nil,
        lane: (lane && lane.id) || nil,
        cx: cx,
        decision: decision || nil,
        timeline_query: keep_timeline_query(socket, tab, timeline_query)
      )
      |> read_tab(tab, decision || nil, page)

    canonical =
      case tab do
        :timeline ->
          put_if(timeline_query, "seq", focused && Integer.to_string(seq))

        :connections ->
          page = socket.assigns.connections.page

          %{}
          |> put_if("decision", decision || nil)
          |> put_if("page", if(page > 1, do: Integer.to_string(page)))

        _ ->
          %{}
      end

    if canonical != params,
      do: push_patch(socket, to: tab_path(run, tab, canonical), replace: true),
      else: socket
  end

  # What a tab shows is read when the tab opens, and only then.
  defp read_tab(socket, :timeline, _decision, _page),
    do: socket |> ensure_window() |> assign_window_counts()

  defp read_tab(socket, :terminal, _decision, _page) do
    %{current_scope: scope, run: run} = socket.assigns
    assign(socket, window_loaded: false, log: Record.log_summary(scope, run))
  end

  defp read_tab(socket, :connections, decision, page) do
    %{current_scope: scope, run: run} = socket.assigns

    socket
    |> assign(
      window_loaded: false,
      counts: Record.connection_counts(scope, run),
      connections: Record.connections(scope, run, decision: decision, page: page),
      # The effective policy is read when the tab opens and when the policy changes, and
      # every row's standing is derived from it: no query per row (pj7).
      effective: socket.assigns.effective || Policy.effective(scope, socket.assigns.target)
    )
    |> assign_acts()
  end

  defp read_tab(socket, :details, _decision, _page) do
    %{current_scope: scope, run: run} = socket.assigns
    assign(socket, window_loaded: false, session_id: Record.session_id(scope, run))
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
  defp put_if(map, _key, false), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp lane_query(query, current, lane_id) do
    if current == lane_id, do: Map.delete(query, "lane"), else: Map.put(query, "lane", lane_id)
  end

  defp cx_query(query, true), do: Map.put(query, "cx", "0")
  defp cx_query(query, false), do: Map.delete(query, "cx")

  defp connections_query(decision, page) do
    %{}
    |> put_if("decision", decision)
    |> put_if("page", if(page > 1, do: Integer.to_string(page)))
  end

  defp tab_path(run, tab, query \\ %{})
  defp tab_path(%Run{run_id: id}, :timeline, query), do: ~p"/hive/runs/#{id}?#{query}"
  defp tab_path(%Run{run_id: id}, :terminal, query), do: ~p"/hive/runs/#{id}/terminal?#{query}"

  defp tab_path(%Run{run_id: id}, :connections, query),
    do: ~p"/hive/runs/#{id}/connections?#{query}"

  defp tab_path(%Run{run_id: id}, :details, query), do: ~p"/hive/runs/#{id}/details?#{query}"

  defp label_path(_run, "task", value), do: ~p"/hive/runs?#{%{task: value}}"

  defp label_path(%Run{target_system: system, target_path: path}, key, _value)
       when key in ~w(forge repository) and is_binary(system) and is_binary(path),
       do: ~p"/hive/runs?#{Filters.target_params(system, path)}"

  defp label_path(_run, _key, _value), do: nil

  # The chips of the lane key: the first dozen, and the isolated one wherever it is.
  defp lane_chips(index, isolated) do
    if is_nil(isolated) or Enum.any?(index.lanes, &(&1.id == isolated)),
      do: index.lanes,
      else: index.lanes ++ List.wrap(Timeline.lane(index, isolated))
  end

  ## The window of the timeline

  # The stream holds a window of the index. It is loaded when the tab opens and when the
  # focused item is outside it; a parameter that only toggles a lane leaves it alone.
  defp ensure_window(socket) do
    %{focused: focused, window_loaded: loaded?} = socket.assigns

    cond do
      not loaded? -> reset_window(socket, focused)
      focused && not in_window?(socket, focused) -> reset_window(socket, focused)
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
        # Around the focused item, and a whole window even when it is near the end.
        index when is_integer(index) ->
          (index - div(@window, 2)) |> min(length(items) - @window) |> max(0)

        _ ->
          0
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
    %{current_scope: scope, run: run, full: full} = socket.assigns

    scope
    |> Record.items(run, light, full: MapSet.to_list(full))
    |> with_versions(socket)
  end

  # The version each policy applied names, where this hive rendered it. The run's own are
  # held already; any other digest costs one indexed read, and a build asks for at most
  # #{@max_versions}, whatever a runner put in its events.
  defp with_versions(items, socket) do
    %{current_scope: scope, target: target, versions: known} = socket.assigns

    {items, _known} =
      Enum.map_reduce(items, known, fn
        %{kind: :policy_applied} = item, known ->
          {version, known} = lookup_version(known, scope, target, item[:digest])
          {previous, known} = lookup_version(known, scope, target, item[:previous_digest])
          {Map.merge(item, %{version: version, previous_version: previous}), known}

        item, known ->
          {item, known}
      end)

    items
  end

  defp lookup_version(known, _scope, _target, digest) when not is_binary(digest),
    do: {nil, known}

  defp lookup_version(known, scope, target, digest) do
    case known do
      %{^digest => version} ->
        {version, known}

      _ when map_size(known) >= @max_versions ->
        {nil, known}

      _ ->
        version = Rules.version(scope, target, digest)
        {version, Map.put(known, digest, version)}
    end
  end

  defp assign_window_counts(socket) do
    %{index: index, win_first: first, win_last: last, run: run} = socket.assigns

    {earlier, later} =
      if is_integer(first),
        do:
          {Enum.count(index.items, &(&1.seq < first)), Enum.count(index.items, &(&1.seq > last))},
        else: {0, length(index.items)}

    assign(socket,
      earlier: earlier,
      later: later,
      new_count: min(socket.assigns.new_count, later),
      unread: max(run.event_count - run.projected_sequence, 0),
      limit: limit_reason(run, index)
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
    # By this server's clock, from when it first heard of the run: never the runner's.
    settled? = not alive?(run) or older_than?(run.inserted_at, 60)

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
  def handle_event("load_earlier", _params, %{assigns: %{win_first: first}} = socket)
      when is_integer(first) do
    light = socket.assigns.index.items |> Enum.filter(&(&1.seq < first)) |> Enum.take(-@page)

    socket =
      if light == [] do
        socket
      else
        socket
        # Prepending one by one reverses a list, so it is handed over reversed.
        |> stream(:items, socket |> build(light) |> Enum.reverse(), at: 0, limit: @max_dom)
        |> assign(win_first: hd(light).seq)
        |> trim_window(:after_prepend)
        |> announce(
          ngettext(
            "%{number} earlier event loaded.",
            "%{number} earlier events loaded.",
            length(light),
            number: delimited(length(light))
          ),
          :now
        )
      end

    {:noreply, assign_window_counts(socket)}
  end

  def handle_event("load_later", _params, %{assigns: %{window_loaded: true}} = socket) do
    %{index: index, win_last: last} = socket.assigns
    light = index.items |> Enum.filter(&(&1.seq > (last || 0))) |> Enum.take(@page)
    socket = if light == [], do: socket, else: append(socket, light)
    {:noreply, assign_window_counts(socket)}
  end

  def handle_event("show_new", _params, %{assigns: %{window_loaded: true}} = socket) do
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

  def handle_event("show_all", %{"seq" => seq}, %{assigns: %{window_loaded: true}} = socket) do
    with seq when is_integer(seq) <- sequence(seq),
         true <- in_window?(socket, seq),
         %{} = light <- Enum.find(socket.assigns.index.items, &(&1.seq == seq)) do
      socket = assign(socket, full: MapSet.put(socket.assigns.full, seq))
      {:noreply, stream(socket, :items, build(socket, [light]))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, %{assigns: %{run: %Run{state: state}}} = socket) do
    {:noreply, assign(socket, confirm_close: state in Runs.closable_states())}
  end

  def handle_event("close_cancel", _params, socket),
    do: {:noreply, assign(socket, confirm_close: false)}

  # The context decides what may be closed; the page only asks.
  def handle_event("close_confirm", _params, %{assigns: %{run: %Run{} = run}} = socket) do
    socket =
      case Runs.close_run(socket.assigns.current_scope, run) do
        {:ok, closed} ->
          socket
          |> follow_run(closed)
          |> put_flash(:info, gettext("Run closed."))
          # The button that had focus is gone with the state it belonged to.
          |> push_event("run:focus", %{id: "run-title"})

        {:error, :not_closable} ->
          socket
          |> refresh_run()
          |> put_flash(:error, gettext("This run has ended; its record keeps the end it posted."))

        {:error, :unauthorized} ->
          put_flash(socket, :error, gettext("You are no longer a member of this hive."))

        {:error, :not_found} ->
          put_flash(socket, :error, gettext("This run is no longer in this hive."))
      end

    {:noreply, assign(socket, confirm_close: false)}
  end

  ## A row's Allow and Deny (pd8). What the browser names is looked up among the rows the
  ## page holds, which are the run's: an id of another run or another hive finds nothing.

  def handle_event("rule_open", %{"id" => id, "action" => action}, socket)
      when is_binary(id) and action in ~w(allow deny) do
    %{connections: %{rows: rows}, acts: acts, live_action: tab} = socket.assigns
    row = tab == :connections && Enum.find(rows, &(&1.id == id))
    act = row && acts && acts["cx-#{row.id}"]

    case {act, action} do
      {%{standing: :can_allow}, "allow"} ->
        {:noreply, open_popover(socket, row, act, :allow)}

      {%{standing: :can_deny}, "deny"} ->
        {:noreply, open_popover(socket, row, act, :deny)}

      # No rule decides the host: it can be denied outright as well as allowed.
      {%{standing: :can_allow, deny: true}, "deny"} ->
        {:noreply, open_popover(socket, row, act, :deny)}

      {%{standing: locked}, _} when locked in [:locked_deny, :locked_allow] ->
        {:noreply, open_refusal(socket, row, act)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "rule_change",
        params,
        %{assigns: %{popover: %{refusal: nil} = popover}} = socket
      ) do
    level =
      case params["for"] do
        "target" when not is_nil(popover.target) -> :target
        "hive" -> :hive
        _ -> popover.level
      end

    {:noreply, assign(socket, popover: %{popover | level: level, error: nil})}
  end

  def handle_event("rule_cancel", _params, socket), do: {:noreply, close_popover(socket)}

  # The rule is the domain's to make and to refuse: `rule_from_connection/4` and nothing
  # else, and what it refuses is said in its own sentence.
  def handle_event(
        "rule_submit",
        _params,
        %{assigns: %{popover: %{refusal: nil, level: level} = popover}} = socket
      )
      when level in [:target, :hive] do
    %{current_scope: scope, run: run} = socket.assigns

    # What the popover said was true of the policy it opened on. It is sent only while
    # that is still the policy: a stale Allow must not undo a deny made meanwhile.
    with :ok <- still(socket, popover),
         {:ok, connection} <- Record.connection(scope, run, popover.connection_id),
         {:ok, rule} <- Policy.rule_from_connection(scope, connection, popover.action, level) do
      {:noreply,
       socket
       |> close_popover()
       |> assign(effective: nil)
       |> refresh_policy()
       |> put_flash(:info, rule_toast(socket, popover, rule, level))
       |> announce(
         Rules.toast(
           rule,
           popover.action,
           popover.host,
           popover.path,
           if(level == :target, do: :this_target, else: :hive)
         ),
         :now
       )}
    else
      :stale ->
        {:noreply, socket |> assign(effective: nil) |> refresh_policy() |> policy_moved()}

      {:error, %Policy.Error{message: message}} ->
        {:noreply, assign(socket, popover: %{popover | error: message})}

      _not_found ->
        {:noreply,
         socket
         |> close_popover()
         |> put_flash(:error, gettext("This connection is no longer in this run."))}
    end
  end

  # A crafted event, or one for a page without a run: nothing to do.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp open_popover(socket, row, act, action) do
    %{run: run, target: target, current_scope: scope, effective: effective} =
      socket.assigns

    path = row.path || ""
    # The page holds the target's policy; the hive's is read when a popover opens,
    # since what a rule for the hive would be is decided by the hive's own paths.
    baseline = if target, do: Policy.effective(scope, nil), else: effective

    assign(socket,
      popover: %{
        anchor: "cx-#{row.id}-act",
        connection_id: row.id,
        action: action,
        host: act.host,
        path: path,
        mode: Rules.mode(row),
        page: :run,
        level: if(target, do: :target, else: :hive),
        target: target && %{label: "#{target.system}/#{target.path}"},
        targets: [],
        choice: nil,
        what: %{
          target: target && Rules.what(effective, act.host, path),
          hive: Rules.what(baseline, act.host, path)
        },
        own_rule: target != nil and Rules.own_rule?(effective, act.host),
        seen: {Rules.seen(effective, act.host), Rules.seen(baseline, act.host)},
        standing: act.standing,
        hive: scope.hive.name,
        alive: alive?(run),
        fetched: fetched?(socket),
        interval: beat(run),
        consequence: deny_consequence(act[:entry]),
        error: nil,
        refusal: nil
      }
    )
    |> mark_expanded()
  end

  defp open_refusal(socket, row, act) do
    scope = socket.assigns.current_scope
    locked = locked_change(scope, act.entry)

    assign(socket,
      popover: %{
        anchor: "cx-#{row.id}-act",
        host: act.host,
        refusal: %{
          standing: act.standing,
          rule: act.entry.host,
          locked_by: locked && locked.changed_by && locked.changed_by.email,
          locked_at: locked && locked.inserted_at,
          owner: owner?(scope),
          rule_path: Rules.rule_path(nil, act.entry.host)
        }
      }
    )
    |> mark_expanded()
  end

  defp close_popover(socket), do: socket |> assign(popover: nil) |> mark_expanded()

  # The slot's button says whether its popover is open.
  defp mark_expanded(%{assigns: %{acts: acts, popover: popover}} = socket) when is_map(acts) do
    open = popover && String.replace_suffix(popover.anchor, "-act", "")
    action = popover && popover[:action]

    assign(socket,
      acts:
        Map.new(acts, fn {id, act} ->
          {id, Map.merge(act, %{expanded: id == open, expanded_action: id == open && action})}
        end)
    )
  end

  defp mark_expanded(socket), do: socket

  # Who locked the rule and when, from the newest page of the hive's history; nil further back.
  defp locked_change(scope, entry) do
    scope
    |> Policy.list_changes(nil, 1)
    |> Map.get(:items, [])
    |> Enum.find(&(&1.action == "rule_locked" and &1.subject == entry.host))
  end

  defp owner?(%{membership: %{level: :owner}}), do: true
  defp owner?(_scope), do: false

  defp deny_consequence(%{source: :hive}) do
    %{
      target: gettext("Disables the hive's allow rule here. Other targets keep it."),
      hive: gettext("Replaces the hive's allow rule.")
    }
  end

  defp deny_consequence(%{source: :target}) do
    %{
      target: gettext("Replaces this target's allow rule."),
      hive: gettext("This target's own allow rule still holds here.")
    }
  end

  defp deny_consequence(_entry), do: %{}

  # Whether the policy is still the one the popover opened on, for the host it is about.
  defp still(socket, popover) do
    %{current_scope: scope, target: target, connections: %{rows: rows}} = socket.assigns
    effective = Policy.effective(scope, target)
    baseline = if target, do: Policy.effective(scope, nil), else: effective
    row = Enum.find(rows, &(&1.id == popover.connection_id))

    if (row && Rules.standing(row, effective, :run).standing == popover.standing) and
         {Rules.seen(effective, popover.host), Rules.seen(baseline, popover.host)} == popover.seen,
       do: :ok,
       else: :stale
  end

  defp policy_moved(socket) do
    socket
    |> close_popover()
    |> put_flash(:error, gettext("The policy changed; look at the row again."))
  end

  # A change of the policy under an open popover closes it when it touches its host.
  defp recheck_popover(%{assigns: %{popover: %{refusal: nil} = popover}} = socket) do
    if still(socket, popover) == :ok, do: socket, else: policy_moved(socket)
  end

  defp recheck_popover(%{assigns: %{popover: %{}}} = socket), do: close_popover(socket)
  defp recheck_popover(socket), do: socket

  defp rule_toast(socket, popover, rule, level) do
    %{current_scope: scope, target: target} = socket.assigns
    holder = if level == :target, do: target, else: nil

    where =
      cond do
        level != :target -> :hive
        target -> {:target, "#{target.system}/#{target.path}"}
        true -> :this_target
      end

    version =
      case Policy.list_changes(scope, holder, 1) do
        %{items: [%{version_after: n} | _]} when is_integer(n) ->
          gettext("Version %{n}.", n: n)

        _ ->
          nil
      end

    own =
      if level == :hive and popover.own_rule,
        do: gettext("This target's own rule still decides here.")

    reach =
      if fetched?(socket) or not alive?(socket.assigns.run),
        do: gettext("Running sessions have it within a heartbeat."),
        else:
          gettext(
            "This run uses its machine's policy; sessions that take this one have it within a heartbeat."
          )

    [Rules.toast(rule, popover.action, popover.host, popover.path, where), version, own, reach]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  ## The policy facts of the header and of the rows

  defp target_of(scope, %Run{target_id: id}) when is_binary(id) do
    case Policy.get_target(scope, id) do
      {:ok, target} -> target
      _ -> nil
    end
  end

  defp target_of(_scope, _run), do: nil

  # A run that holds a configuration fetched from this server is one that reloads.
  defp fetched?(%{assigns: %{digests: digests}}),
    do: is_binary(digests.reported) or is_binary(digests.applied)

  # pj8: drift is a comparison, read at mount, on each message of the policy's topic and
  # when the run reports another digest. No timer decides it.
  defp assign_policy_facts(%{assigns: %{run: %Run{} = run}} = socket) do
    %{current_scope: scope, target: target, versions: known} = socket.assigns
    digests = Rules.digests(scope, run)

    {reported, known} =
      lookup_version(known, scope, target, digests.reported || digests.applied)

    behind? = alive?(run) and digests.drift

    in_force =
      if behind? do
        case Policy.current_configuration(scope, target) do
          {:ok, configuration} -> Rules.version_of(configuration, target)
          _ -> nil
        end
      end

    socket =
      if in_force && is_nil(socket.assigns.in_force),
        do: announce(socket, gettext("This run is behind the policy in force."), :now),
        else: socket

    assign(socket,
      digests: digests,
      reported_version: reported,
      in_force: in_force,
      versions: known
    )
  end

  defp assign_policy_facts(socket), do: socket

  defp refresh_policy(%{assigns: %{run: %Run{}, loaded: true}} = socket) do
    %{current_scope: scope, target: target, live_action: tab} = socket.assigns
    socket = assign_policy_facts(socket)

    if tab == :connections,
      do: socket |> assign(effective: Policy.effective(scope, target)) |> assign_acts(),
      else: assign(socket, effective: nil)
  end

  defp refresh_policy(socket), do: socket

  # What each row of the page may ask, and the line after the rows a rule already answers.
  defp assign_acts(%{assigns: %{effective: %Policy.Effective{} = effective}} = socket) do
    %{current_scope: scope, target: target, connections: %{rows: rows}} = socket.assigns
    standings = Enum.map(rows, &{&1, Rules.standing(&1, effective, :run)})
    changes = Rules.changes(scope, target, Enum.map(standings, &elem(&1, 1)))

    standings =
      for {row, standing} <- standings, do: {row, Rules.answered(standing, row, changes)}

    acts =
      for {row, standing} <- standings, into: %{} do
        {"cx-#{row.id}", act(socket, row, standing, changes)}
      end

    socket |> assign(acts: acts) |> mark_expanded()
  end

  defp assign_acts(socket), do: assign(socket, acts: nil)

  defp act(socket, row, %{standing: {:rule_added, action}, entry: entry} = standing, changes)
       when not is_nil(entry) do
    %{target: target, current_scope: scope} = socket.assigns
    holder_id = if entry.source == :target and target, do: target.id
    change = Rules.change_for(entry, changes)

    standing
    |> Map.merge(%{
      values: %{"id" => row.id},
      entry_host: entry.host,
      rule_path: Rules.rule_path(holder_id, entry.host),
      after: %{
        action: action,
        level: if(entry.source == :target, do: :target, else: :hive),
        version:
          change && is_integer(change.version) &&
            %{
              n: change.version,
              path: Rules.version_path(holder_id, change.version),
              label: Rules.version_label(holder_id, target)
            },
        by: change && who(change, scope),
        at: (change && change.at) || (entry.rule && entry.rule.updated_at),
        state: after_state(socket),
        reloaded_at: reloaded_at(socket)
      }
    })
  end

  defp act(_socket, row, standing, _changes) do
    Map.merge(standing, %{
      values: %{"id" => row.id},
      entry_host: standing.entry && standing.entry.host,
      rule_path: nil,
      after: nil
    })
  end

  defp who(%{by_id: id}, %{user: %{id: id}}) when not is_nil(id), do: gettext("you")
  defp who(%{by: email}, _scope) when is_binary(email), do: email |> String.split("@") |> hd()
  defp who(_change, _scope), do: nil

  # "In force in this run" is claimed from the record alone: the run reported the digest
  # that is in force. Never after a timer, and never of a run that takes no policy here.
  defp after_state(%{assigns: %{run: run, digests: digests}} = socket) do
    cond do
      not alive?(run) -> :ended
      not fetched?(socket) -> :machine
      is_binary(digests.reported) and digests.reported == digests.in_force -> :in_force
      true -> :pending
    end
  end

  defp reloaded_at(%{assigns: %{run: run, digests: digests, policy: %{sequence: sequence}}})
       when is_integer(sequence) do
    if is_binary(digests.in_force) and run.run_configuration_digest == digests.in_force,
      do: sequence
  end

  defp reloaded_at(_socket), do: nil

  defp comparable?(%{target_id: id}, %{target_id: id}), do: true
  defp comparable?(_reported, _in_force), do: false

  defp behind_path(reported, in_force) do
    if comparable?(reported, in_force),
      do: Rules.version_path(in_force.target_id, in_force.n, %{"compare" => reported.n}),
      else: in_force.path
  end

  defp refresh_run(socket) do
    case Record.reload(socket.assigns.current_scope, socket.assigns.run) do
      %Run{} = run -> follow_run(socket, run)
      nil -> socket
    end
  end

  ## The run's topic

  @impl true
  def handle_info({:run_changed, %Run{} = run}, socket),
    do: {:noreply, socket |> follow_run(run) |> schedule_flush()}

  # At most one read per run per #{@coalesce_ms} ms, however many batches land: the ranges
  # that arrive in between are joined.
  def handle_info({:run_projected, %Run{} = run, first, last}, socket)
      when is_integer(first) and is_integer(last) do
    range =
      case socket.assigns.range do
        nil -> {first, last}
        {a, b} -> {min(a, first), max(b, last)}
      end

    {:noreply, socket |> follow_run(run) |> assign(range: range) |> schedule_flush()}
  end

  def handle_info(:flush, socket) do
    {:noreply, socket |> assign(flush_scheduled: false) |> flush()}
  end

  # Quiet is the server's word: recomputed on a timer and on every batch, never by the page.
  def handle_info(:quiet_tick, socket) do
    Process.send_after(self(), :quiet_tick, @quiet_tick_ms)

    case socket.assigns.run do
      %Run{} = run ->
        was = socket.assigns.quiet_for
        now = quiet_for(run)

        socket =
          if is_nil(was) and now != nil,
            do: announce(socket, gettext("No heartbeat for %{seconds} s.", seconds: now), :now),
            else: socket

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

  # The policy's topic: coalesced like the run's, one read per #{@coalesce_ms} ms.
  def handle_info({:policy_changed, _what}, socket) do
    if socket.assigns.policy_flush_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :policy_flush, @coalesce_ms)
      {:noreply, assign(socket, policy_flush_scheduled: true)}
    end
  end

  def handle_info(:policy_flush, socket) do
    {:noreply,
     socket |> assign(policy_flush_scheduled: false) |> refresh_policy() |> recheck_popover()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_flush(%{assigns: %{flush_scheduled: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Process.send_after(self(), :flush, @coalesce_ms)
    assign(socket, flush_scheduled: true)
  end

  defp follow_run(%{assigns: %{run: %Run{id: id} = old}} = socket, %Run{id: id} = run) do
    # The broadcast carries the row; the key it was posted with does not change.
    run = %{run | access_key: old.access_key}
    was_quiet? = socket.assigns.quiet_for != nil

    socket
    |> assign_run(run)
    |> announce_change(old, run, was_quiet?)
    |> follow_digests(old, run)
  end

  defp follow_run(socket, _run), do: socket

  # A heartbeat changes nothing here. What the run reports, what it applied and whether it
  # is alive do: then, and only then, the facts are read again.
  defp follow_digests(socket, %Run{} = old, %Run{} = run) do
    same? =
      old.reported_run_configuration_digest == run.reported_run_configuration_digest and
        old.run_configuration_digest == run.run_configuration_digest and
        alive?(old) == alive?(run)

    cond do
      same? or not socket.assigns.loaded ->
        socket

      socket.assigns.live_action == :connections ->
        socket |> assign_policy_facts() |> assign_acts()

      true ->
        assign_policy_facts(socket)
    end
  end

  defp announce_change(socket, %Run{state: state}, %Run{state: state} = run, was_quiet?) do
    if was_quiet? and is_nil(quiet_for(run)) and state == "running",
      do: announce(socket, gettext("Heartbeats resumed."), :now),
      else: socket
  end

  defp announce_change(socket, _old, %Run{} = run, _was_quiet?) do
    announce(socket, state_sentence(run), :now)
  end

  defp state_sentence(%Run{state: "succeeded", duration_ms: ms}) when is_integer(ms),
    do: gettext("Run succeeded after %{duration}.", duration: format_duration_ms(ms))

  defp state_sentence(%Run{state: "succeeded"}), do: gettext("Run succeeded.")

  defp state_sentence(%Run{state: "failed", signal: signal}) when is_binary(signal),
    do: gettext("Run failed with %{signal}.", signal: signal)

  defp state_sentence(%Run{state: "failed", exit_code: code}) when is_integer(code),
    do: gettext("Run failed with exit %{code}.", code: code)

  defp state_sentence(%Run{state: "failed"}), do: gettext("Run failed.")
  defp state_sentence(%Run{state: "timed_out"}), do: gettext("Run timed out.")

  defp state_sentence(%Run{state: "lost", heartbeat_interval_seconds: interval})
       when is_integer(interval),
       do: gettext("Run lost. No heartbeat for %{seconds} s.", seconds: interval * 3)

  defp state_sentence(%Run{state: "lost"}), do: gettext("Run lost.")
  defp state_sentence(%Run{state: "closed"}), do: gettext("Run closed.")
  defp state_sentence(%Run{state: "running"}), do: gettext("Run started.")
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

  # After the projections of the last quarter second. What is read is the range they
  # announced and what the open tab shows of it: never the run again, whatever its size.
  # The one exception is an event that arrived below what the page holds.
  defp flush(%{assigns: %{run: %Run{} = run, loaded: true}} = socket) do
    %{current_scope: scope, index: old, range: range, live_action: tab} = socket.assigns
    socket = assign(socket, range: nil)

    {index, rows} =
      case range do
        nil ->
          {Timeline.alive(old, alive?(run)), []}

        {first, last} ->
          case Record.extend_timeline(scope, run, old, first, last) do
            {:ok, index, rows} -> {index, rows}
            :stale -> {Record.timeline(scope, run), :stale}
          end
      end

    socket = assign(socket, index: index)

    case rows do
      :stale ->
        socket
        |> assign(policy: Record.policy(scope, run), window_loaded: false)
        |> read_tab(tab, socket.assigns.decision, socket.assigns.connections.page)

      rows ->
        types = MapSet.new(rows, & &1.type)
        egress? = "dev.qory.run.egress" in types

        socket
        |> then(
          &if("dev.qory.run.policy_applied" in types,
            do: &1 |> assign(policy: Record.policy(scope, run)) |> announce_reload() |> reline(),
            else: &1
          )
        )
        |> then(
          &if(egress?, do: assign(&1, counts: Record.connection_counts(scope, run)), else: &1)
        )
        |> flush_tab(tab, old, types, range)
    end
  end

  defp flush(socket), do: assign(socket, range: nil)

  # A reload arrived: the lines after the rows say at which sequence the run reloaded,
  # and they were made when the run's row changed, before this event was read.
  defp reline(%{assigns: %{live_action: :connections, effective: %Policy.Effective{}}} = socket),
    do: assign_acts(socket)

  defp reline(socket), do: socket

  defp announce_reload(%{assigns: %{index: index, policy: %{sequence: sequence}}} = socket) do
    reload? =
      Enum.any?(
        index.items,
        &(&1.kind == :policy_applied and &1.seq == sequence and &1[:previous_seq])
      )

    version = socket.assigns.versions[socket.assigns.run.run_configuration_digest]

    cond do
      not reload? ->
        socket

      version ->
        announce(
          socket,
          gettext("The run reloaded its policy: version %{n}.", n: version.n),
          :now
        )

      true ->
        announce(socket, gettext("The run reloaded its policy."), :now)
    end
  end

  defp announce_reload(socket), do: socket

  defp flush_tab(%{assigns: %{window_loaded: true}} = socket, :timeline, old, _types, _range),
    do: socket |> follow_timeline(old) |> assign_window_counts()

  # The log is read by difference: what followed the last chunk the page knows of. The
  # hook is told how far it has come, and fetches the bytes itself.
  defp flush_tab(socket, :terminal, _old, _types, range) when range != nil do
    %{current_scope: scope, run: run, log: log} = socket.assigns
    more = Record.log_summary(scope, run, log.through)

    if more.chunks > 0 do
      log = Record.add_log_summary(log, more)
      socket |> assign(log: log) |> push_event("log_advanced", %{through: log.through})
    else
      socket
    end
  end

  defp flush_tab(socket, :connections, _old, types, _range) do
    if "dev.qory.run.egress" in types,
      do:
        read_tab(socket, :connections, socket.assigns.decision, socket.assigns.connections.page),
      else: socket
  end

  defp flush_tab(socket, :details, _old, types, _range) do
    if "dev.qory.session.started" in types,
      do: read_tab(socket, :details, nil, 1),
      else: socket
  end

  defp flush_tab(socket, _tab, _old, _types, _range), do: socket

  defp follow_timeline(socket, old) do
    %{index: new, win_first: first, win_last: last} = socket.assigns
    old_last = old.items |> List.last() |> then(&((&1 && &1.seq) || 0))

    if is_nil(first) do
      # Nothing was on the page yet: the window starts with what arrived.
      reset_window(socket, socket.assigns.focused)
    else
      old_in_window =
        for item <- old.items,
            item.seq >= first and item.seq <= last,
            into: %{},
            do: {item.seq, item}

      changed =
        for item <- new.items,
            item.seq >= first and item.seq <= last,
            old_in_window[item.seq] != item,
            do: item

      appended = Enum.drop_while(new.items, &(&1.seq <= old_last))

      socket = if changed == [], do: socket, else: stream(socket, :items, build(socket, changed))

      cond do
        appended == [] ->
          socket

        last == old_last and socket.assigns.at_end and socket.assigns.new_count == 0 ->
          append(socket, appended)

        true ->
          socket
          |> assign(new_count: socket.assigns.new_count + length(appended))
          |> announce(
            ngettext("%{number} new event.", "%{number} new events.", length(appended),
              number: delimited(length(appended))
            ),
            :throttled
          )
      end
    end
  end

  ## Words

  defp alive?(%Run{state: state}), do: state in Run.alive_states()
  defp ended?(%Run{state: state}), do: state in ~w(succeeded failed timed_out)

  defp exit_value(%Run{reason: "timeout"}), do: gettext("timeout")
  defp exit_value(%Run{reason: "runner_lost"}), do: gettext("runner lost")
  defp exit_value(%Run{signal: signal}) when is_binary(signal) and signal != "", do: signal
  defp exit_value(%Run{exit_code: code}) when is_integer(code), do: Integer.to_string(code)
  defp exit_value(_run), do: gettext("n/a")

  defp connections_count(%{denied: denied}) when denied > 0,
    do: ngettext("%{number} denied", "%{number} denied", denied, number: delimited(denied))

  defp connections_count(%{all: all}) when all > 0, do: delimited(all)
  defp connections_count(_counts), do: nil

  defp interactive_words(true), do: gettext("Yes, on a pseudo-terminal")
  defp interactive_words(false), do: gettext("No, on pipes")
  defp interactive_words(_unknown), do: gettext("n/a")

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  # The strings the record kept of a list, and how many the list had.
  defp strings([], _count), do: nil

  defp strings(shown, count) when is_list(shown) do
    more = (count || 0) - length(shown)
    list = Enum.join(shown, ", ")

    if more > 0,
      do: gettext("%{list} and %{number} more", list: list, number: delimited(more)),
      else: list
  end

  defp strings(_other, _count), do: nil

  # Credentials or tools by name, with the hosts each is for. Never a credential's value:
  # the event carries none.
  defp named_hosts([_ | _] = named) do
    Enum.map_join(named, ", ", fn item ->
      case item["hosts"] do
        [_ | _] = hosts -> "#{item["name"]} (#{Enum.join(hosts, ", ")})"
        _ -> item["name"]
      end
    end)
  end

  defp named_hosts(_other), do: nil
end
