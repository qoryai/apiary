defmodule ApiaryWeb.WorkspaceLive.Overview do
  @moduledoc """
  The workspace overview, `/:org/:workspace`: the page a member lands on after sign-in. It
  answers two questions, in this order: what needs you (the To review list, a list
  of acts and nothing else) and what your agents did (the summary, the fourteen-day chart,
  the active targets). Policy and retention are Guard's few lines, each with a link. Each
  level has its own look (`docs/ui.md`, Lists): the summary is the largest type on the
  page, a block is one box with a band and its rows, a row is one line; no block grows
  with the data, each shows the few and links the many.

  Every number is a count the workspace already keeps; the page infers nothing. The first
  paint is the shell: the count of alive runs, the keys, the policy's mode summary and the
  skeletons; four asynchronous reads fill the regions (activity, attention, policy, the
  targets and retention), none of them blocking, every one bounded. Two subscriptions
  (`Apiary.Runs.subscribe/1`, `Apiary.Policy.subscribe/1`) keep it live: a run change
  patches the alive runs and an active target's last run in place from the message and
  re-reads the alive runs and today's column at most once per 250 ms; a policy change
  re-reads Guard's policy and the denied destinations; quiet and behind are recomputed on a
  5 s timer without a query. Nothing moves under the reader (`docs/ui.md`): new items
  append, resolved items stay struck until the next navigation, and the announcer says
  what arrived.

  While no run has landed the page is the empty workspace's one box, each step read from
  the record; when the first run lands the box stays with its third step ticked and leaves
  at the next navigation. Its "Get the command" makes the command that connects the box's
  node in place (`get_command`), as the node's Access key tab does: the code lives in the
  page's process alone, in a function, shown once in the box and in no path, flash, title
  or log line, until the page goes, the command expires, it is cancelled on the tab, or
  the machine runs it. The page hears the last two on the node's topic
  (`Apiary.AccessKeys.subscribe/2`): a cancel brings the question back, a run moves the box
  on.

  The page is the record's, so it belongs to `observability`. Everything of the policy on
  it belongs to `security`, and where that is off for the scope the page is one that never
  had a policy: no policy lines, no policy read and no subscription to it, no item about
  the mode or the version in force, no denied destination offered for an allow (that act
  is a rule), nothing that links to the policy. The summary still counts the denied
  attempts and their destinations: Forager reported them, they are the record's.

  `thresholds/0` holds the design's choices in one place.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  import ApiaryWeb.OverviewComponents

  import ApiaryWeb.RunComponents,
    only: [quiet_for: 2, beat: 1]

  alias Apiary.Runs.Filters

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Enrolment
  alias Apiary.Nodes
  alias Apiary.Policy
  alias Apiary.Retention
  alias Apiary.Runs
  alias Apiary.Runs.Run

  alias ApiaryWeb.ConnectionLive.Rules
  alias ApiaryWeb.PolicyLive.Common
  alias Phoenix.LiveView.JS

  @thresholds %{
    idle_key_days: 30,
    lost_days: 7,
    denied_days: 14,
    chart_days: 14,
    behind_intervals: 2
  }

  @doc """
  The design's choices, in one place: an idle key at #{@thresholds.idle_key_days} days, a
  lost run listed for #{@thresholds.lost_days} days, a run behind the policy after
  #{@thresholds.behind_intervals} heartbeat intervals, denied destinations over
  #{@thresholds.denied_days} days, the chart over #{@thresholds.chart_days} days. None of them
  is the record's; the record keeps the timestamps, the page draws the lines.
  """
  @spec thresholds :: %{
          idle_key_days: pos_integer,
          lost_days: pos_integer,
          denied_days: pos_integer,
          chart_days: pos_integer,
          behind_intervals: pos_integer
        }
  def thresholds, do: @thresholds

  # How many rows a list shows; the sixth and later are "and n more". The active targets
  # are the eight with the most runs.
  @shown 5
  @targets 8
  @denied_filters %Filters{kind: :connections, since: "14d", decision: "denied"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:overview}
      width="list"
    >
      <:crumb>{gettext("Overview")}</:crumb>

      <div id="overview" phx-hook="OverviewPage" class="grid grid-cols-[minmax(0,1fr)] gap-5">
        <.page_header title={@current_scope.workspace.name} />

        <div id="overview-announcer" class="sr-only" aria-live="polite" aria-atomic="true">
          {@announce}
        </div>

        <.onboarding
          :if={@checklist?}
          scope={@current_scope}
          nodes={@onboarding.nodes}
          keys={@onboarding.keys}
          may_add={@onboarding.may_add}
          target={@onboarding.target}
          may_key={@onboarding.may_key}
          command={@command}
          server={@onboarding.server}
          landed={@landed}
        />

        <div :if={@live?} class="q-ov">
          <.summary
            scope={@current_scope}
            alive={@alive}
            quiet={MapSet.size(@quiet_ids)}
            facts={@facts}
            destinations={@destinations}
            from={chart_from(@today)}
          />

          <.attention
            :if={@attention_items}
            scope={@current_scope}
            id="attention"
            items={Enum.take(@attention_items, @shown)}
            count={@attention_count}
            more={@attention_more}
            shared={@shared}
            can_set_mode?={Common.may?(@current_scope, :"security_policy.set_mode")}
            panel={@rule_panel}
            now={@now}
            confirming={@confirm_close && "att-run-#{@confirm_close.run_id}"}
          />

          <section id="overview-activity" class="q-blk q-ov-act" aria-labelledby="overview-activity-h">
            <div class="q-band">
              <h2 id="overview-activity-h">{gettext("Activity")}</h2>
              <span class="q-band-n">
                {ngettext("%{number} day", "%{number} days", 14, number: Format.number(14))}
              </span>
              <span class="q-grow"></span>
              <button
                id="days-toggle"
                type="button"
                class="q-band-do"
                aria-pressed={to_string(@table?)}
                aria-controls="days-plot"
                phx-click={JS.push("chart_table", value: %{on: !@table?})}
              >
                {if @table?, do: gettext("As a chart"), else: gettext("As a table")}
              </button>
            </div>
            <div class="q-ov-chart">
              <.notice :if={@failed[:activity]} kind={:info}>
                <span id="activity-error">{not_loaded()}</span>
              </.notice>
              <.days_chart
                :if={!@failed[:activity]}
                scope={@current_scope}
                id="days"
                days={@days}
                today={@today}
                table?={@table?}
                width={@chart_w}
              />
              <p class="q-cap" id="activity-foot">
                <span :if={@facts && @facts.costed > 0} id="activity-cost">
                  <.rich text={
                    rich_ngettext(
                      "Cost reported: %{cost}, by %{costed} of the %{number} run.",
                      "Cost reported: %{cost}, by %{costed} of the %{number} runs.",
                      @facts.runs,
                      cost: {:b, cost_text(@facts.cost)},
                      costed: Format.number(@facts.costed),
                      number: Format.number(@facts.runs)
                    )
                  } />
                </span>
                {gettext("Days in UTC.")}
                <span class="q-live-on">{gettext("Updated as batches land.")}</span>
                <span class="q-live-off">{gettext("Reconnecting.")}</span>
                <span :if={@connections == :unavailable} id="activity-uncounted">
                  {gettext(
                    "Denied destinations were not counted: this workspace recorded more than %{cap} connections in 14 days. The Network access page counts them by destination.",
                    cap: Format.number(Policy.Activity.cap())
                  )}
                </span>
              </p>
            </div>
            <.link
              id="activity-all"
              navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs"}
              class="q-more"
            >
              {gettext("All runs")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
            </.link>
          </section>

          <.active_targets
            scope={@current_scope}
            rows={@targets}
            targets={@target_count}
            quiet_ids={@quiet_ids}
          />

          <.guard
            scope={@current_scope}
            security?={@security?}
            policy={@policy}
            policy_failed?={!!@failed[:policy]}
            workspace={@current_scope.workspace}
            retention={@retention}
            now={@now}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    now = DateTime.utc_now()
    keys = AccessKeys.list_workspace_node_keys(scope)
    alive = Runs.count_alive(scope)
    posted? = alive > 0 or Runs.recent_runs(scope, 1) != []
    security? = Common.may?(scope, :"security_policy.read")

    if connected?(socket) do
      Runs.subscribe(scope)
      if security?, do: Policy.subscribe(scope)
      Process.send_after(self(), :quiet_tick, window(:quiet_tick, 5_000))
      Process.send_after(self(), :refresh, window(:refresh, 60_000))
    end

    socket =
      socket
      |> assign(
        # Two organisations may each have a Main: the window names the organisation too.
        page_title: scope.workspace.name <> " · " <> scope.organisation.name,
        shown: @shown,
        keys: sort_keys(keys),
        alive: alive,
        security?: security?,
        mode: if(security?, do: Policy.mode_summary(scope)),
        checklist?: not posted?,
        live?: posted?,
        landed: nil,
        now: now,
        today: DateTime.to_date(now),
        onboarding: if(posted?, do: nil, else: read_onboarding(scope)),
        command: nil,
        table?: false,
        chart_w: 640,
        rule_panel: nil,
        confirm_close: nil,
        announce: nil,
        announced_at: nil,
        failed: %{},
        # The regions, nil while their read is in flight.
        alive_runs: nil,
        targets: nil,
        target_count: 0,
        shared: MapSet.new(),
        retention: nil,
        days: empty_days(DateTime.to_date(now)),
        facts: nil,
        drift: %{},
        connections: nil,
        destinations: nil,
        above_level: nil,
        lost: [],
        policy: nil,
        attention_items: nil,
        attention_count: 0,
        attention_more: nil,
        quiet_ids: MapSet.new(),
        seen: %{},
        run_window: :closed,
        policy_window: :closed,
        landed_reads: MapSet.new(),
        settled: false
      )

    {:ok, if(connected?(socket) and posted?, do: load(socket), else: socket)}
  end

  # The four reads that fill the page, none blocking the first paint; three where
  # `security` is off, which has no policy to read.
  defp load(socket) do
    socket
    |> read(:activity)
    |> read(:attention)
    |> read(:policy)
    |> read(:targets)
  end

  defp read(socket, :activity) do
    %{current_scope: scope, today: today, security?: security?} = socket.assigns

    start_async(socket, :activity, fn ->
      read_activity(scope, today, DateTime.utc_now(), security?)
    end)
  end

  defp read(socket, :attention) do
    %{current_scope: scope, security?: security?} = socket.assigns

    start_async(socket, :attention, fn ->
      read_attention(scope, DateTime.utc_now(), security?)
    end)
  end

  defp read(%{assigns: %{security?: false}} = socket, :policy), do: socket

  defp read(socket, :policy) do
    scope = socket.assigns.current_scope
    start_async(socket, :policy, fn -> read_policy(scope, DateTime.utc_now()) end)
  end

  # The active targets, the paths on more than one system (where a row names the system)
  # and the last prune.
  defp read(socket, :targets) do
    %{current_scope: scope, today: today} = socket.assigns
    from = Date.add(today, -(@thresholds.chart_days - 1))

    start_async(socket, :targets, fn ->
      %{
        active: Runs.active_targets(scope, from, @targets),
        shared: Runs.shared_paths(scope),
        retention: Retention.list_retention_runs(scope, 1)
      }
    end)
  end

  # The first of the chart's days, which the summary counts from.
  defp chart_from(today), do: Date.add(today, 1 - @thresholds.chart_days)

  ## The reads. Each runs in its own task; nothing here touches the socket.

  defp read_activity(scope, today, now, security?) do
    from = start_of(Date.add(today, -(@thresholds.chart_days - 1)))
    alive_runs = Runs.list_alive(scope, @shown)

    %{
      days: Runs.day_facts(scope, from),
      alive_runs: alive_runs,
      drift: drift_facts(scope, alive_runs, security?),
      alive: Runs.count_alive(scope),
      today: today,
      read_at: now
    }
  end

  # Today's column and the alive runs again: what a run change can move.
  defp read_today(scope, today, now, security?) do
    alive_runs = Runs.list_alive(scope, @shown)

    %{
      today: Runs.day_facts(scope, start_of(today)),
      alive_runs: alive_runs,
      drift: drift_facts(scope, alive_runs, security?),
      alive: Runs.count_alive(scope),
      lost: Runs.lost_since(scope, DateTime.add(now, -@thresholds.lost_days, :day), @shown + 1),
      read_at: now
    }
  end

  defp read_attention(scope, now, security?) do
    since = DateTime.add(now, -@thresholds.denied_days, :day)
    window = DateTime.add(now, -@thresholds.chart_days, :day)

    connections =
      if security?,
        do: Policy.overview_activity(scope, since, window),
        else: record_denials(scope, window)

    %{
      connections: connections,
      above_level: if(security?, do: above_level(scope)),
      lost: Runs.lost_since(scope, DateTime.add(now, -@thresholds.lost_days, :day), @shown + 1),
      keys: AccessKeys.list_workspace_node_keys(scope),
      read_at: now
    }
  end

  # The level above the workspace's policy (`Apiary.Policy.Above`), where the edition keeps
  # one: its name, whether a workspace or a target may allow hosts of its own, and the
  # edition's page of it (`c:ApiaryWeb.Edition.above_policy_link/1`). Where it allows only
  # its own hosts, an allow written here would not be in force, so the list offers none:
  # the way to its page to one who may change it, a lock and the reason to the rest, as
  # Network access does (`ApiaryWeb.ConnectionLive.Rules.rule_option/4`).
  defp above_level(scope) do
    case Policy.effective(scope, nil) do
      %{above: %Policy.Above{} = above} ->
        %{
          name: above.name,
          own_allows: above.own_allows,
          link: ApiaryWeb.Edition.above_policy_link(scope)
        }

      _ ->
        nil
    end
  end

  defp read_policy(scope, now) do
    summary = Policy.mode_summary(scope)
    targets = Policy.list_targets(scope)
    rules = Policy.list_rules(scope, nil)
    own = Enum.filter(targets, &(&1.own_mode != nil))

    version =
      case Common.served_version(scope, nil, summary.managed?) do
        {configuration, _own?} -> configuration
        nil -> nil
      end

    %{
      summary: summary,
      targets: length(targets),
      with_rules: Enum.count(targets, &(&1.rule_count > 0)),
      following: Enum.count(targets, &is_nil(&1.own_mode)),
      own: own,
      # The one target the guard may name, named as it is addressed: one read, or none.
      shared: Runs.shared_paths(scope, for(%{target: t} <- own, length(own) == 1, do: t.path)),
      version: version,
      allow_rules: Enum.count(rules, &(&1.kind == "host" and &1.action == "allow")),
      suggestions:
        Policy.suggestion_counts(scope, DateTime.add(now, -@thresholds.chart_days, :day)),
      read_at: now
    }
  end

  # Without `security` no rule holds a denied destination and there is no act to offer on
  # one: the connections are read for the summary's count of destinations alone, in the
  # shape the attention read has, with nothing to list. `Policy.denied_summary/2` reads
  # the recorded connections and no rule.
  defp record_denials(scope, window) do
    case Policy.denied_summary(scope, window) do
      {:ok, %{destinations: n}} -> {:ok, %{denied: [], uncovered: [], denied_destinations: n}}
      :unavailable -> :unavailable
    end
  end

  # What the alive runs report against what is in force, in one bulk read; the reported
  # version is looked up for a run that is behind, and only then. The configuration in
  # force is `security`'s: without it nothing is compared and no run is behind.
  defp drift_facts(_scope, _runs, false), do: %{}

  defp drift_facts(scope, runs, true) do
    reported = Enum.filter(runs, &is_binary(&1.reported_run_configuration_digest))

    if reported == [] do
      %{}
    else
      holders = reported |> Enum.map(& &1.target_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      versions = Policy.newest_versions(scope, [nil | holders])
      targets = Map.new(holders, &{&1, holder_of(scope, &1)})

      # A target's versions are at its address, its system there only where its path is
      # shared: one read for the targets of the runs that are behind.
      shared = Runs.shared_paths(scope, for({_id, %{path: path}} <- targets, do: path))

      for run <- reported,
          in_force = versions[run.target_id] || versions[nil],
          in_force.digest != run.reported_run_configuration_digest,
          into: %{} do
        holder = run.target_id && targets[run.target_id]

        reported_version =
          case Policy.configuration_for_digest(
                 scope,
                 holder,
                 run.reported_run_configuration_digest
               ) do
            {:ok, configuration} -> version_map(scope, configuration, holder, shared)
            _ -> nil
          end

        {run.id,
         %{in_force: version_map(scope, in_force, holder, shared), reported: reported_version}}
      end
    end
  end

  defp holder_of(_scope, nil), do: nil

  defp holder_of(scope, target_id) do
    case Policy.get_target(scope, target_id) do
      {:ok, target} -> target
      _ -> nil
    end
  end

  # A target's version is on its Policy tab: `holder` is the run's target, the one target
  # a run's versions are of; no path when it could not be read.
  defp version_map(scope, configuration, holder, shared) do
    holder = if configuration.target_id, do: holder
    shared = holder != nil and MapSet.member?(shared, holder.path)

    %{
      n: configuration.version,
      digest: configuration.digest,
      rendered_at: configuration.rendered_at,
      target_id: configuration.target_id,
      holder: holder,
      shared: shared,
      path:
        if(configuration.target_id && is_nil(holder),
          do: nil,
          else: Rules.version_path(scope, holder, configuration.version, %{}, shared)
        )
    }
  end

  ## Results

  @impl true
  def handle_async(:activity, {:ok, read}, socket) do
    socket =
      socket
      |> assign(
        alive_runs: read.alive_runs,
        drift: read.drift,
        alive: read.alive,
        today: read.today,
        failed: Map.delete(socket.assigns.failed, :activity),
        landed_reads: MapSet.put(socket.assigns.landed_reads, :activity)
      )
      |> remember(read.alive_runs)
      |> put_days(read.days, read.today)
      |> tick(read.read_at)

    {:noreply, recompute(socket)}
  end

  def handle_async(:today, {:ok, read}, socket) do
    shown = socket.assigns.alive_runs

    # The alive runs on the page are patched in place, a run that ended leaves, a run that
    # is new appends: what the attention list and the summary read.
    alive_ids = Enum.map(shown || [], & &1.id)
    fresh = Map.new(read.alive_runs, &{&1.id, &1})

    kept =
      (shown || [])
      |> Enum.map(&Map.get(fresh, &1.id, &1))
      |> Enum.filter(&(&1.state in Run.alive_states()))

    arrived = Enum.reject(read.alive_runs, &(&1.id in alive_ids))

    socket =
      socket
      |> assign(
        alive_runs: kept ++ arrived,
        drift: read.drift,
        alive: read.alive,
        lost: read.lost
      )
      |> remember(read.alive_runs ++ read.lost)
      |> put_today(read.today)
      |> tick(read.read_at)

    {:noreply, recompute(socket)}
  end

  def handle_async(:attention, {:ok, read}, socket) do
    destinations =
      case read.connections do
        {:ok, %{denied_destinations: n}} -> n
        _ -> nil
      end

    socket =
      socket
      |> assign(
        connections: unwrap(read.connections),
        destinations: destinations,
        above_level: read.above_level,
        lost: read.lost,
        keys: sort_keys(read.keys),
        failed: Map.delete(socket.assigns.failed, :attention),
        landed_reads: MapSet.put(socket.assigns.landed_reads, :attention)
      )
      |> remember(read.lost)
      |> tick(read.read_at)

    {:noreply, recompute(socket)}
  end

  def handle_async(:policy, {:ok, read}, socket) do
    socket =
      socket
      |> assign(
        policy: read,
        mode: read.summary,
        failed: Map.delete(socket.assigns.failed, :policy),
        landed_reads: MapSet.put(socket.assigns.landed_reads, :policy)
      )
      |> tick(read.read_at)

    {:noreply, recompute(socket)}
  end

  def handle_async(:targets, {:ok, read}, socket) do
    {:noreply,
     assign(socket,
       targets: read.active.rows,
       target_count: read.active.targets,
       shared: read.shared,
       retention: read.retention,
       failed: Map.delete(socket.assigns.failed, :targets)
     )}
  end

  def handle_async(name, {:exit, _reason}, socket) do
    failed = Map.put(socket.assigns.failed, if(name == :today, do: :activity, else: name), true)
    socket = assign(socket, failed: failed)

    # A failed read of the targets leaves their block empty and the prune unsaid.
    socket =
      if name == :targets,
        do: assign(socket, targets: [], retention: []),
        else: socket

    {:noreply, socket}
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(_unavailable), do: :unavailable

  ## Live

  @impl true
  def handle_info({:run_changed, %Run{} = run}, %{assigns: %{live?: false}} = socket) do
    # The first run has landed: the checklist ticks its third step and stays; the activity
    # and the cards render under it.
    socket =
      socket
      |> assign(live?: true, landed: run, alive: Runs.count_alive(socket.assigns.current_scope))
      |> remember([run])
      |> load()

    {:noreply, socket}
  end

  def handle_info({:run_changed, %Run{} = run}, socket) do
    # Remembered before the patch, whose recompute reads what the page has seen: a quiet
    # run the check has just found lost leaves the alive runs there, and with the struct
    # it had before, its row would be struck as resumed instead of turning Lost.
    socket = socket |> remember([run]) |> patch_run(run)

    case {socket.assigns.run_window, window(:coalesce, 250)} do
      # No window (a test): the read follows the message at once.
      {:closed, 0} ->
        {:noreply, refresh_runs(socket)}

      {:closed, coalesce} ->
        Process.send_after(self(), :run_flush, coalesce)
        {:noreply, assign(socket, :run_window, :open)}

      _open_or_dirty ->
        {:noreply, assign(socket, :run_window, :dirty)}
    end
  end

  def handle_info(:run_flush, socket) do
    case socket.assigns.run_window do
      :dirty ->
        Process.send_after(self(), :run_flush, window(:coalesce, 250))
        {:noreply, socket |> assign(:run_window, :open) |> refresh_runs()}

      _open ->
        {:noreply, socket |> assign(:run_window, :closed) |> refresh_runs()}
    end
  end

  def handle_info({:policy_changed, _what}, socket) do
    case {socket.assigns.policy_window, window(:coalesce, 250)} do
      {:closed, 0} ->
        handle_info(:policy_flush, socket)

      {:closed, coalesce} ->
        Process.send_after(self(), :policy_flush, coalesce)
        {:noreply, assign(socket, :policy_window, :open)}

      _open ->
        {:noreply, socket}
    end
  end

  def handle_info(:policy_flush, socket) do
    socket = assign(socket, :policy_window, :closed)

    socket =
      if socket.assigns.live?, do: socket |> read(:policy) |> read(:attention), else: socket

    {:noreply, recheck_panel(socket)}
  end

  # Quiet and behind are a comparison of the record's timestamps with the clock: no query.
  def handle_info(:quiet_tick, socket) do
    Process.send_after(self(), :quiet_tick, window(:quiet_tick, 5_000))
    {:noreply, socket |> tick(DateTime.utc_now()) |> recompute()}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, window(:refresh, 60_000))

    if socket.assigns.live? do
      {:noreply, read(socket, :attention)}
    else
      # The box reads its steps from the record: a node, a key, a key used since.
      {:noreply,
       socket
       |> assign(
         onboarding: read_onboarding(socket.assigns.current_scope),
         now: DateTime.utc_now()
       )
       |> keep_command()}
    end
  end

  # The machine ran the box's command: the box reads its steps again and moves on, and
  # the command, spent, is let go.
  def handle_info(
        {:key_enrolled, %{node_id: node_id}},
        %{assigns: %{command: %{node: %{id: node_id}}}} = socket
      ) do
    socket = assign(socket, :onboarding, read_onboarding(socket.assigns.current_scope))
    {:noreply, drop_command(socket)}
  end

  # The box's command was cancelled, on the node's Access key tab: it is let go, and the
  # box asks again.
  def handle_info(
        {:code_cancelled, %{code_id: code_id}},
        %{assigns: %{command: %{code_id: code_id}}} = socket
      ),
      do: {:noreply, drop_command(socket)}

  # The box's command expired: it is let go, and the box asks again.
  def handle_info(
        {:command_expired, code_id},
        %{assigns: %{command: %{code_id: code_id}}} = socket
      ),
      do: {:noreply, drop_command(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  # The box's command, while its node is still the one the box names and has no key; let
  # go otherwise.
  defp keep_command(%{assigns: %{command: %{node: %{id: id}}, onboarding: onboarding}} = socket) do
    case onboarding do
      %{target: %{id: ^id}, keys: []} -> socket
      _moved_on -> drop_command(socket)
    end
  end

  defp keep_command(socket), do: socket

  defp drop_command(%{assigns: %{command: %{node: node, timer: timer}}} = socket) do
    Process.cancel_timer(timer)
    AccessKeys.unsubscribe(socket.assigns.current_scope, node)
    assign(socket, :command, nil)
  end

  defp drop_command(socket), do: socket

  # The coalesced re-read: today's column, the alive rows, the last runs, the lost runs. At
  # midnight UTC the window has moved: the fourteen days are read anew.
  defp refresh_runs(%{assigns: %{live?: true}} = socket) do
    %{current_scope: scope, today: today, security?: security?} = socket.assigns
    now = DateTime.utc_now()

    if Date.compare(DateTime.to_date(now), today) == :gt do
      new_today = DateTime.to_date(now)

      socket
      |> assign(today: new_today)
      |> then(
        &start_async(&1, :activity, fn -> read_activity(scope, new_today, now, security?) end)
      )
    else
      start_async(socket, :today, fn -> read_today(scope, today, now, security?) end)
    end
  end

  defp refresh_runs(socket), do: socket

  # A run on the page is patched from the message, in place: an alive run, and the last
  # run of an active target, which a newer run of it replaces. The counts wait for the
  # next read; nothing moves under the reader.
  defp patch_run(socket, %Run{} = run) do
    %{alive_runs: alive_runs, targets: targets} = socket.assigns

    alive_runs =
      alive_runs &&
        alive_runs
        |> Enum.map(&if(&1.id == run.id, do: run, else: &1))
        |> Enum.filter(&(&1.state in Run.alive_states()))

    targets =
      targets &&
        Enum.map(targets, fn
          %{id: id, last: last} = row when id == run.target_id ->
            if is_nil(last) or last.id == run.id or newer?(run, last),
              do: %{row | last: run},
              else: row

          row ->
            row
        end)

    socket |> assign(alive_runs: alive_runs, targets: targets) |> recompute()
  end

  defp newer?(run, than) do
    DateTime.compare(run.started_at || run.inserted_at, than.started_at || than.inserted_at) ==
      :gt
  end

  ## Events

  @impl true
  def handle_event("chart_table", %{"on" => on}, socket) do
    {:noreply, assign(socket, :table?, on == true or on == "true")}
  end

  # The browser knows the chart's width; the drawing is made for it, so its words are
  # never scaled (`DaysChart`).
  def handle_event("chart_size", %{"width" => width}, socket) when is_integer(width) do
    {:noreply,
     assign(socket, :chart_w, width |> div(10) |> Kernel.*(10) |> max(280) |> min(1600))}
  end

  def handle_event("chart_size", _params, socket), do: {:noreply, socket}

  # Get the command, in the box: a code made at once for the box's node, with the defaults
  # (stored secrets not allowed, no label hint), whatever the event carries, as on the
  # node's Access key tab. The code is held in a function, and shown in the box alone.
  def handle_event(
        "get_command",
        _params,
        %{
          assigns: %{
            checklist?: true,
            command: nil,
            onboarding: %{target: %Nodes.Node{} = target, may_key: true, keys: []}
          }
        } = socket
      ) do
    scope = socket.assigns.current_scope

    case AccessKeys.create_enrolment_code(scope, target, %{}) do
      {:ok, row, code} ->
        code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())
        AccessKeys.subscribe(scope, target)
        wait = DateTime.diff(row.expires_at, DateTime.utc_now(), :millisecond)
        timer = Process.send_after(self(), {:command_expired, row.id}, max(wait, 0) + 1)

        {:noreply,
         assign(socket,
           command: %{
             node: target,
             code_id: row.id,
             code: fn -> code end,
             expires_at: row.expires_at,
             timer: timer
           }
         )}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:onboarding, read_onboarding(scope))
         |> put_flash(:error, gettext("Only owners and admins connect a node."))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:onboarding, read_onboarding(scope))
         |> put_flash(:error, gettext("Nothing was changed. Try again."))}
    end
  end

  # Get the command where the box offers none: a second click once the command shows, or
  # an event the page never sent. One who may connect a node is shown the page as it is;
  # anyone else is refused, and nothing is made.
  def handle_event("get_command", _params, socket) do
    if Common.may?(socket.assigns.current_scope, :"access_key.create_code"),
      do: {:noreply, socket},
      else:
        {:noreply, put_flash(socket, :error, gettext("Only owners and admins connect a node."))}
  end

  def handle_event("close_ask", %{"id" => id}, socket) do
    case find_item(socket, id) do
      %{kind: :lost, run: run, resolved: nil} -> {:noreply, assign(socket, :confirm_close, run)}
      _ -> {:noreply, socket}
    end
  end

  # Cancel, or Escape: the row is itself again, and its Close has the focus back.
  def handle_event("close_cancel", _params, %{assigns: %{confirm_close: %Run{} = run}} = socket) do
    {:noreply,
     socket
     |> assign(:confirm_close, nil)
     |> push_event("overview:focus", %{id: "att-run-#{run.run_id}-act"})}
  end

  def handle_event("close_cancel", _params, socket), do: {:noreply, socket}

  def handle_event("close_confirm", _params, %{assigns: %{confirm_close: %Run{} = run}} = socket) do
    socket = assign(socket, :confirm_close, nil)

    case Runs.close_run(socket.assigns.current_scope, run) do
      {:ok, closed} ->
        socket =
          socket
          |> remember([closed])
          |> resolve_item("att-run-#{run.run_id}", %{
            mark: :closed,
            what: gettext("Closed."),
            done: nil
          })
          |> announce(gettext("%{run} is closed.", run: row_title(run)), :now)
          |> focus_after("att-run-#{run.run_id}")

        {:noreply, socket}

      {:error, :not_closable} ->
        {:noreply,
         put_flash(socket, :error, gettext("This run has ended; there is nothing to close."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The run could not be closed."))}
    end
  end

  def handle_event("close_confirm", _params, socket), do: {:noreply, socket}

  ## The one-click allow of a denied destination: the panel of a connection row's Allow,
  ## called with the destination's targets, exactly as the connections page calls it. A
  ## rule is `security`'s: without it no row offers the act, and an event that asks anyway
  ## is ignored, as an event for a row that is gone is.

  def handle_event("rule_" <> _event, _params, %{assigns: %{security?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("rule_open", %{"id" => id, "level" => level}, socket) do
    case find_item(socket, id) do
      %{kind: :denied, resolved: nil, locked: nil, above: nil, elsewhere: nil} = item ->
        {:noreply, open_panel(socket, item, level)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "rule_change",
        params,
        %{assigns: %{rule_panel: %{refusal: nil} = panel}} = socket
      ) do
    level =
      case params["for"] do
        "target" when panel.targets != [] -> :target
        "workspace" -> :workspace
        _ -> panel.level
      end

    choice =
      case params["target"] do
        id when is_binary(id) -> if Enum.any?(panel.targets, &(&1.id == id)), do: id
        _ -> panel.choice
      end

    panel = %{panel | level: level, choice: choice, error: nil}

    panel =
      if choice != panel.chosen,
        do: describe(socket, panel, chosen_effective(socket, choice)),
        else: panel

    {:noreply, assign(socket, rule_panel: panel)}
  end

  def handle_event("rule_cancel", _params, socket), do: {:noreply, close_panel(socket)}

  def handle_event(
        "rule_submit",
        _params,
        %{assigns: %{rule_panel: %{refusal: nil, level: level} = panel}} = socket
      )
      when level in [:target, :workspace] do
    scope = socket.assigns.current_scope

    with :ok <- still(socket, panel),
         {:ok, from} <- rule_source(panel),
         {:ok, connection} <- Runs.fetch_connection(scope, from.connection_id),
         {:ok, rule} <- Policy.rule_from_connection(scope, connection, :allow, level) do
      where = if level == :target, do: {:target, from.label}, else: :workspace

      done =
        if level == :target,
          do: gettext("Allowed here"),
          else: gettext("Allowed for the workspace")

      socket =
        socket
        |> close_panel()
        |> resolve_item(panel.item_id, %{mark: :allowed, what: nil, done: done})
        |> announce(Rules.toast(rule, :allow, panel.host, panel.path, where), :now)
        |> focus_after(panel.item_id)

      {:noreply, socket}
    else
      :stale ->
        {:noreply,
         socket
         |> close_panel()
         |> read(:attention)
         |> put_flash(
           :info,
           gettext("The policy changed under you; the rows were read again. Nothing was written.")
         )}

      {:error, %Policy.Error{message: message}} ->
        {:noreply, assign(socket, rule_panel: %{panel | error: message})}

      _not_found ->
        {:noreply,
         socket
         |> close_panel()
         |> put_flash(
           :error,
           gettext("This destination is no longer among the connections shown.")
         )}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(rule_change rule_submit),
    do: {:noreply, socket}

  defp open_panel(socket, item, level) do
    scope = socket.assigns.current_scope

    reached =
      Runs.destination_targets(scope, @denied_filters, {item.host, item.port, item.path})

    # Each target named as it is addressed: one read of the paths the panel names.
    shared =
      Runs.shared_paths(
        scope,
        for(%{target_id: id, path: p} when is_binary(id) <- reached, do: p)
      )

    targets =
      for %{target_id: id} = r when is_binary(id) <- reached do
        %{
          id: id,
          label: ApiaryWeb.TargetComponents.target_label(r.system, r.path, shared),
          runs: r.runs,
          connection_id: r.connection_id
        }
      end

    {level, choice} =
      case {level, targets} do
        {"workspace", _} -> {:workspace, nil}
        {"target", [one]} -> {:target, one.id}
        {"target", _} -> {nil, nil}
        _ -> {nil, nil}
      end

    baseline = Policy.effective(scope, nil)
    chosen = if choice, do: chosen_effective(socket, choice)

    panel = %{
      item_id: item.id,
      anchor: "#{item.id}-act",
      any_connection_id: reached |> List.first() |> then(&(&1 && &1.connection_id)),
      action: :allow,
      host: item.host,
      path: item.path,
      page: :workspace,
      level: level,
      target: nil,
      targets: targets,
      choice: choice,
      baseline: baseline,
      rule_option: :can_allow,
      chosen: nil,
      what: %{target: nil, workspace: nil},
      own_rule: false,
      seen: nil,
      consequence: %{},
      workspace: scope.workspace.name,
      alive: false,
      fetched: false,
      interval: 30,
      error: nil,
      refusal: nil,
      own: Rules.own_hosts(scope)
    }

    socket |> assign(rule_panel: describe(socket, panel, chosen)) |> mark_expanded()
  end

  defp close_panel(socket), do: socket |> assign(rule_panel: nil) |> mark_expanded()

  # The row's button says whether its panel is open (aria-expanded).
  defp mark_expanded(%{assigns: %{attention_items: items}} = socket) when is_list(items) do
    open = socket.assigns.rule_panel && socket.assigns.rule_panel.item_id
    assign(socket, :attention_items, Enum.map(items, &Map.put(&1, :expanded, &1.id == open)))
  end

  defp mark_expanded(socket), do: socket

  defp rule_source(%{level: :target, choice: choice, targets: targets})
       when is_binary(choice) do
    case Enum.find(targets, &(&1.id == choice)) do
      %{} = target -> {:ok, Map.put(target, :target, %{id: target.id})}
      nil -> :error
    end
  end

  defp rule_source(%{level: :workspace, any_connection_id: id}) when is_binary(id),
    do: {:ok, %{connection_id: id, label: gettext("the workspace"), target: nil}}

  defp rule_source(_panel), do: :error

  defp chosen_effective(_socket, nil), do: nil

  defp chosen_effective(socket, id) do
    case Policy.get_target(socket.assigns.current_scope, id) do
      {:ok, target} -> Policy.effective(socket.assigns.current_scope, target)
      _ -> nil
    end
  end

  defp describe(_socket, panel, chosen) do
    %{host: host, path: path, baseline: baseline, own: own} = panel
    own? = Rules.own_touches?(own, host) or Rules.own_rule?(chosen, host)

    %{
      panel
      | chosen: panel.choice,
        what: %{
          target: Rules.what(chosen, host, path),
          workspace: Rules.what(baseline, host, path)
        },
        own_rule: own?,
        seen: {Rules.seen(baseline, host), Rules.seen(chosen, host)},
        consequence: %{
          target: chosen && target_consequence(chosen, host),
          workspace: workspace_consequence(baseline, host, own?)
        }
    }
  end

  defp target_consequence(effective, host) do
    if Rules.own_rule?(effective, host),
      do: gettext("Replaces the target's own rule for the host."),
      else: gettext("Disables the workspace's allow rule there. Other targets keep it.")
  end

  defp workspace_consequence(baseline, host, own?) do
    cond do
      own? -> gettext("A target's own allow rule still holds there.")
      Rules.seen(baseline, host) != [] -> gettext("Replaces the workspace's allow rule.")
      true -> nil
    end
  end

  # Sent only while the policy is still the one the panel opened on, for its host.
  defp still(socket, panel) do
    scope = socket.assigns.current_scope
    baseline = Policy.effective(scope, nil)
    chosen = chosen_effective(socket, panel.chosen)

    if {Rules.seen(baseline, panel.host), Rules.seen(chosen, panel.host)} == panel.seen,
      do: :ok,
      else: :stale
  end

  # A change of the policy under an open panel closes it when it touches its host.
  defp recheck_panel(%{assigns: %{rule_panel: %{refusal: nil} = panel}} = socket) do
    if still(socket, panel) == :ok, do: socket, else: close_panel(socket)
  end

  defp recheck_panel(socket), do: socket

  ## The attention list: built from the record in assigns, merged into what is shown.

  # A denied destination that only the level above could allow: no locked rule and no deny
  # of that level holds it, and the level allows only its own hosts.
  defp elsewhere(%{own_allows: false} = level, %{} = row) do
    if is_nil(row[:locked]) and is_nil(row[:above]), do: level
  end

  defp elsewhere(_level, _row), do: nil

  # Every candidate item, in the order the list shows them. Nothing here queries.
  defp candidates(assigns) do
    now = assigns.now
    since_lost = DateTime.add(now, -@thresholds.lost_days, :day)

    denied =
      case assigns.connections do
        %{denied: rows} ->
          for row <- rows do
            Map.merge(row, %{
              id: "att-denied-#{:erlang.phash2({row.host, row.port, row.path}, 4_294_967_296)}",
              kind: :denied,
              above: Map.get(row, :above),
              level: assigns.above_level,
              elsewhere: elsewhere(assigns.above_level, row)
            })
          end

        _ ->
          []
      end

    runs = Map.values(assigns.seen)

    lost =
      for run <- assigns.lost ++ Enum.filter(runs, &(&1.state == "lost")),
          run.lost_at && DateTime.compare(run.lost_at, since_lost) != :lt,
          uniq: true,
          do: %{id: "att-run-#{run.run_id}", kind: :lost, run: run, at: run.lost_at}

    alive = assigns.alive_runs || []

    quiet =
      for run <- alive, seconds = quiet_for(run, now), is_integer(seconds) do
        %{
          id: "att-run-#{run.run_id}",
          kind: :quiet,
          run: run,
          at: run.last_heartbeat_at || run.inserted_at
        }
      end

    behind =
      for run <- alive,
          %{in_force: in_force} = facts <- [assigns.drift[run.id]],
          DateTime.diff(now, in_force.rendered_at, :second) >
            @thresholds.behind_intervals * beat(run) do
        %{
          id: "att-run-#{run.run_id}",
          kind: :behind,
          run: run,
          at: in_force.rendered_at,
          in_force: in_force,
          reported: facts.reported,
          beats: div(max(DateTime.diff(now, in_force.rendered_at, :second), 0), beat(run)),
          compare: compare_path(assigns.current_scope, in_force, facts.reported)
        }
      end

    lost_ids = MapSet.new(lost, & &1.id)
    quiet = Enum.reject(quiet, &MapSet.member?(lost_ids, &1.id))
    quiet_ids = MapSet.new(quiet, & &1.id)

    behind =
      Enum.reject(behind, &(MapSet.member?(lost_ids, &1.id) or MapSet.member?(quiet_ids, &1.id)))

    runs_items =
      (lost ++ quiet ++ behind)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{kind_rank(&1.kind), -DateTime.to_unix(&1.at || now, :microsecond)})

    policy = policy_item(assigns)

    idle =
      for key <- idle_candidates(assigns),
          days = idle_days(key, now),
          is_integer(days) and days >= @thresholds.idle_key_days do
        %{id: "att-key-#{key.id}", kind: :idle_key, key: key, days: days}
      end
      |> Enum.sort_by(&(-&1.days))

    Enum.sort_by(denied, &(-&1.denied)) ++ runs_items ++ List.wrap(policy) ++ idle
  end

  defp kind_rank(:lost), do: 0
  defp kind_rank(:quiet), do: 1
  defp kind_rank(:behind), do: 2

  defp policy_item(%{policy: nil}), do: nil

  defp policy_item(%{policy: policy, facts: facts, connections: connections, seen: seen}) do
    recent_run? =
      Enum.any?(Map.values(seen), fn run ->
        at = run.started_at || run.inserted_at
        at && DateTime.diff(DateTime.utc_now(), at, :day) < @thresholds.denied_days
      end) or (facts && facts.runs > 0)

    cond do
      not policy.summary.managed? and (facts && facts.runs > 0) ->
        %{id: "att-policy-unmanaged", kind: :unmanaged, runs: facts.runs}

      policy.summary.managed? and policy.summary.mode == "observe" and policy.allow_rules > 0 and
          recent_run? ->
        uncovered =
          case connections do
            %{uncovered: list} -> length(list)
            :unavailable -> :unavailable
            nil -> nil
          end

        %{
          id: "att-policy-enforce",
          kind: :enforce,
          rules: policy.allow_rules,
          uncovered: uncovered
        }

      true ->
        nil
    end
  end

  defp compare_path(scope, in_force, %{n: m, target_id: same})
       when same == in_force.target_id and (is_nil(same) or in_force.holder != nil),
       do:
         Rules.version_path(
           scope,
           in_force.holder,
           in_force.n,
           %{"compare" => m},
           in_force.shared
         )

  defp compare_path(_scope, in_force, _reported), do: in_force.path

  # The node keys the idle item weighs: every key not revoked (each is active), for a reader
  # who may revoke them (`access_key.revoke`, owners and admins). The list holds acts, and
  # a member has none on a key.
  defp idle_candidates(assigns) do
    if Common.may?(assigns.current_scope, :"access_key.revoke"),
      do: assigns.keys,
      else: []
  end

  # Idle since the key's last use, or since it arrived when it has never been used.
  defp idle_days(%AccessKey{last_used_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at, :day)

  defp idle_days(%AccessKey{received_at: %DateTime{} = at}, now), do: DateTime.diff(now, at, :day)
  defp idle_days(%AccessKey{inserted_at: %DateTime{} = at}, now), do: DateTime.diff(now, at, :day)
  defp idle_days(_key, _now), do: nil

  # The list as shown: rows already there keep their place and are patched, rows whose item
  # is gone are struck with the resolution in words, new items append.
  defp recompute(%{assigns: %{live?: false}} = socket), do: socket

  defp recompute(socket) do
    assigns = socket.assigns
    ready? = assigns.connections != nil or assigns.policy != nil or assigns.alive_runs != nil

    if ready? do
      candidates = candidates(assigns)
      by_id = Map.new(candidates, &{&1.id, &1})
      shown = assigns.attention_items || []

      kept =
        for item <- shown do
          case {item.resolved, by_id[item.id]} do
            {nil, nil} ->
              Map.put(item, :resolved, resolution(item, assigns))

            {nil, fresh} ->
              fresh |> Map.merge(Map.take(item, [:arrived, :expanded])) |> Map.put(:resolved, nil)

            {_resolved, _} ->
              item
          end
        end

      known = MapSet.new(shown, & &1.id)

      # Settled once a recompute has seen the first three reads land (two without
      # `security`, which has no policy read): the list this one produces is the first the
      # reader can have read in full.
      settled? = assigns.settled

      first_reads =
        if assigns.security?, do: [:activity, :attention, :policy], else: [:activity, :attention]

      all_landed? = MapSet.subset?(MapSet.new(first_reads), assigns.landed_reads)

      arrived =
        candidates
        |> Enum.reject(&MapSet.member?(known, &1.id))
        |> Enum.map(&Map.merge(&1, %{arrived: settled?, resolved: nil}))

      # Until the first reads have all landed the list is sorted in its own order,
      # whatever read came first; from then on rows keep their place and new ones append.
      items =
        if settled? do
          kept ++ arrived
        else
          resolved = Enum.filter(kept, & &1.resolved)
          by_id = Map.new(kept ++ arrived, &{&1.id, &1})
          resolved ++ for(c <- candidates, item = by_id[c.id], is_nil(item.resolved), do: item)
        end

      unresolved = Enum.filter(items, &is_nil(&1.resolved))
      hidden = items |> Enum.drop(@shown) |> Enum.filter(&is_nil(&1.resolved))

      socket =
        socket
        |> assign(
          settled: all_landed?,
          attention_items: items,
          attention_count: length(unresolved) - length(hidden),
          attention_more: more_link(socket.assigns.current_scope, hidden),
          quiet_ids: MapSet.new(for %{kind: :quiet, run: run} <- unresolved, do: run.id)
        )

      if settled? and shown != [] and arrived != [],
        do:
          announce(
            socket,
            ngettext(
              "%{number} more item to review.",
              "%{number} more items to review.",
              length(arrived),
              number: Format.number(length(arrived))
            )
          ),
        else: socket
    else
      socket
    end
  end

  # The overflow is counted per kind; the link goes to the kind that overflowed first.
  defp more_link(_scope, []), do: nil

  defp more_link(scope, [first | _] = hidden) do
    count = length(hidden)

    case first.kind do
      # What To review counts: the destinations denied in the fourteen days that no
      # rule has allowed since. Network access's Denied counts every one denied then.
      :denied ->
        %{
          count: count,
          label:
            ngettext(
              "and %{number} more destination still denied",
              "and %{number} more destinations still denied",
              count,
              number: Format.number(count)
            ),
          navigate:
            ~p"/#{scope.organisation}/#{scope.workspace}/network?#{%{"decision" => "denied"}}",
          title:
            ngettext(
              "%{number} more item, on the Network access page",
              "%{number} more items, on the Network access page",
              count,
              number: Format.number(count)
            )
        }

      kind when kind in [:lost, :quiet, :behind] ->
        %{
          count: count,
          navigate:
            ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{%{"state" => "pending,running,lost"}}",
          title:
            ngettext(
              "%{number} more item, on the runs list",
              "%{number} more items, on the runs list",
              count,
              number: Format.number(count)
            )
        }

      _ ->
        %{
          count: count,
          navigate: ~p"/#{scope.organisation}/#{scope.workspace}/nodes?#{%{"sort" => "seen"}}",
          title:
            ngettext(
              "%{number} more item, on the nodes page",
              "%{number} more items, on the nodes page",
              count,
              number: Format.number(count)
            )
        }
    end
  end

  # What became of an item that is no longer on the record's list, in words.
  defp resolution(%{kind: :denied}, _assigns),
    do: %{mark: :allowed, what: gettext("Allowed since."), done: nil}

  defp resolution(%{kind: kind, run: run}, assigns) when kind in [:lost, :quiet, :behind] do
    current = Map.get(assigns.seen, run.id, run)

    what =
      cond do
        current.state == "closed" -> gettext("Closed.")
        kind == :behind and current.state in Run.alive_states() -> gettext("Reloaded.")
        current.state in Run.alive_states() -> gettext("Heartbeats resumed.")
        current.state == "lost" -> gettext("Marked lost.")
        true -> ended(current.state)
      end

    %{mark: if(current.state == "closed", do: :closed, else: :resolved), what: what, done: nil}
  end

  defp resolution(%{kind: :enforce}, %{policy: policy}) do
    what =
      if policy && policy.summary.mode == "enforce",
        do: gettext("Enforce is the workspace's default."),
        else: gettext("Nothing to enforce yet.")

    %{mark: :resolved, what: what, done: nil}
  end

  defp resolution(%{kind: :unmanaged}, _assigns),
    do: %{mark: :resolved, what: gettext("Qory Apiary serves the policy now."), done: nil}

  defp resolution(%{kind: :idle_key, key: key}, %{keys: keys}) do
    what =
      if Enum.any?(keys, &(&1.id == key.id)),
        do: gettext("Used again."),
        else: gettext("Revoked.")

    %{mark: :resolved, what: what, done: nil}
  end

  defp resolve_item(socket, id, resolved) do
    items = socket.assigns.attention_items || []

    items =
      Enum.map(
        items,
        &if(&1.id == id and is_nil(&1.resolved), do: Map.put(&1, :resolved, resolved), else: &1)
      )

    unresolved = Enum.filter(items, &is_nil(&1.resolved))
    hidden = items |> Enum.drop(@shown) |> Enum.filter(&is_nil(&1.resolved))

    assign(socket,
      attention_items: items,
      attention_count: length(unresolved) - length(hidden),
      attention_more: more_link(socket.assigns.current_scope, hidden)
    )
  end

  defp find_item(socket, id), do: Enum.find(socket.assigns.attention_items || [], &(&1.id == id))

  # After an act, focus moves to the next row's first action, or to All runs after the last.
  defp focus_after(socket, id) do
    items = socket.assigns.attention_items || []
    shown = Enum.take(items, @shown)
    index = Enum.find_index(shown, &(&1.id == id)) || -1

    next =
      shown
      |> Enum.drop(index + 1)
      |> Enum.find(&is_nil(&1.resolved))

    push_event(socket, "overview:focus", %{
      id: if(next, do: "#{next.id}-act", else: "activity-all")
    })
  end

  ## The chart's days and the summary's facts

  defp put_days(socket, rows, today) do
    days = for offset <- (@thresholds.chart_days - 1)..0//-1, do: Date.add(today, -offset)
    by_day = Map.new(rows, &{&1.day, &1})
    filled = Enum.map(days, &Map.merge(empty_day(&1), Map.get(by_day, &1, %{})))
    assign(socket, days: filled, facts: totals(filled))
  end

  defp put_today(socket, rows) do
    today = socket.assigns.today
    fresh = Enum.find(rows, &(Date.compare(&1.day, today) == :eq)) || empty_day(today)

    days =
      Enum.map(
        socket.assigns.days,
        &if(Date.compare(&1.day, today) == :eq, do: Map.merge(&1, fresh), else: &1)
      )

    assign(socket, days: days, facts: totals(days))
  end

  defp empty_days(today) do
    for offset <- (@thresholds.chart_days - 1)..0//-1, do: empty_day(Date.add(today, -offset))
  end

  defp empty_day(day),
    do: %{
      day: day,
      runs: 0,
      alive: 0,
      ended_well: 0,
      ended_badly: 0,
      denied: 0,
      cost: nil,
      costed: 0
    }

  defp totals(days) do
    Enum.reduce(
      days,
      %{runs: 0, alive: 0, ended_well: 0, ended_badly: 0, denied: 0, cost: nil, costed: 0},
      fn day, acc ->
        %{
          runs: acc.runs + day.runs,
          alive: acc.alive + day.alive,
          ended_well: acc.ended_well + day.ended_well,
          ended_badly: acc.ended_badly + day.ended_badly,
          denied: acc.denied + day.denied,
          cost: add_cost(acc.cost, day.cost),
          costed: acc.costed + day.costed
        }
      end
    )
  end

  defp add_cost(nil, cost), do: cost
  defp add_cost(sum, nil), do: sum
  defp add_cost(sum, cost), do: Decimal.add(sum, cost)

  defp start_of(%Date{} = day), do: DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")

  ## Small things

  # The latest struct of every run the page has seen, by row id: what a resolution reads.
  defp remember(socket, runs) do
    seen = Enum.reduce(runs, socket.assigns.seen, fn run, acc -> Map.put(acc, run.id, run) end)
    assign(socket, :seen, seen)
  end

  defp tick(socket, now), do: assign(socket, :now, now)

  # The polite region says one sentence at most every ten seconds (oh); a resolution the
  # reader caused is said at once.
  defp announce(socket, text, timing \\ :throttled) do
    now = DateTime.utc_now()
    last = socket.assigns.announced_at

    if timing == :now or is_nil(last) or
         DateTime.diff(now, last, :millisecond) >= window(:announce, 10_000),
       do: assign(socket, announce: text, announced_at: now),
       else: socket
  end

  # Most recently seen first, then the never-seen, newest first.
  defp sort_keys(keys) do
    Enum.sort_by(
      keys,
      &{if(&1.last_used_at, do: 0, else: 1),
       -DateTime.to_unix(&1.last_used_at || &1.inserted_at, :microsecond)}
    )
  end

  # What the empty workspace's box reads: the nodes and pools in use, their keys not
  # revoked, whether the reader may add a node, the newest node or pool that holds no
  # active key and whether the reader may give it one, and the address the command names.
  defp read_onboarding(scope) do
    counts = Nodes.count_nodes(scope)
    keys = AccessKeys.list_workspace_node_keys(scope)
    target = keyless_target(scope, counts, keys)
    may_key? = &Apiary.Access.can?(scope, &1, target)

    %{
      nodes: counts.node + counts.pool,
      keys: keys,
      may_add: Common.may?(scope, :"node.create"),
      target: target,
      may_key:
        not is_nil(target) and may_key?.(:"access_key.add") and
          may_key?.(:"access_key.create_code"),
      server: ApiaryWeb.Endpoint.url()
    }
  end

  # The newest node or pool in use that holds no active key (a revoked key is no key);
  # while step 2 is current, no node holds one, and it is simply the newest.
  defp keyless_target(_scope, %{node: 0, pool: 0}, _keys), do: nil

  defp keyless_target(scope, _counts, keys) do
    keyed = MapSet.new(keys, & &1.node_id)

    scope
    |> Nodes.list_nodes()
    |> Enum.reject(&MapSet.member?(keyed, &1.id))
    |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.public_id}, fn -> nil end)
  end

  defp not_loaded,
    do:
      gettext(
        "This could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
      )

  # What became of a run that ended while it was on the list.
  defp ended("succeeded"), do: gettext("Succeeded.")
  defp ended("failed"), do: gettext("Failed.")
  defp ended("timed_out"), do: gettext("Timed out.")
  defp ended(state), do: "#{ApiaryWeb.RunComponents.state_label(state)}."

  # In a test:
  # `config :apiary, ApiaryWeb.WorkspaceLive.Overview, coalesce: 0, quiet_tick: …`.
  defp window(name, default) do
    :apiary |> Application.get_env(__MODULE__, []) |> Keyword.get(name, default)
  end
end
