defmodule ApiaryWeb.HiveLive.Overview do
  @moduledoc """
  The hive overview, `/hive`: the page a member lands on after sign-in
  (`docs/design/brief-overview.md`). It answers two questions above the fold, in this
  order: what needs you (the Needs attention list, a list of acts and nothing else) and
  what your agents did (the activity strip, the alive rows, the fourteen-day chart, the
  last runs). Policy, access keys and retention are a glance and a link.

  Every number is a count the hive already keeps; the page infers nothing. The first
  paint is the shell: the count of alive runs, the keys, the policy's mode summary and
  the skeletons; four asynchronous reads fill the regions (attention, activity, policy,
  the keys and retention), none of them blocking, every one bounded. Two subscriptions
  (`Apiary.Runs.subscribe/1`, `Apiary.Policy.subscribe/1`) keep it live: a run change
  patches its row in place from the message and re-reads the alive rows, the last runs
  and today's column at most once per 250 ms; a policy change re-reads the policy card
  and the denied destinations; quiet and behind are recomputed on a 5 s timer without a
  query. Nothing moves under the reader: new rows append, resolved items stay struck until
  the next navigation, a run that is not on the page is "1 new run" in words.

  While no run has landed the page is the checklist of the empty hive (oe6), each step
  read from the record; when the first run lands the card stays with its third step
  ticked and leaves at the next navigation.

  `thresholds/0` holds the design's choices in one place.
  """
  use ApiaryWeb, :live_view

  import ApiaryWeb.OverviewComponents

  import ApiaryWeb.RunComponents,
    only: [rule_popover: 1, quiet_for: 2, beat: 1, delimited: 1]

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Policy
  alias Apiary.Retention
  alias Apiary.Runs
  alias Apiary.Runs.{Filters, Run}
  import ApiaryWeb.PolicyComponents, only: [sect: 1]

  alias ApiaryWeb.ConnectionLive.Rules
  alias ApiaryWeb.PolicyLive.Common
  alias Phoenix.LiveView.JS

  @thresholds %{
    idle_key_days: 30,
    lost_days: 7,
    denied_days: 7,
    chart_days: 14,
    behind_intervals: 2
  }

  @doc """
  The design's choices, in one place (brief ol 4): an idle key at #{@thresholds.idle_key_days}
  days, a lost run listed for #{@thresholds.lost_days} days, a run behind the policy after
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

  # How many rows a list shows; the sixth and later are "and n more".
  @shown 5
  @denied_filters %Filters{kind: :connections, since: "7d", decision: "denied"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:overview}
      width="full"
    >
      <div id="overview" phx-hook="OverviewPage" class="grid grid-cols-[minmax(0,1fr)] gap-6">
        <.header>
          {@current_scope.hive.name}
          <:subtitle>
            {gettext("The hive of the %{organisation} organisation.",
              organisation: @current_scope.organisation.name
            )}
          </:subtitle>
        </.header>

        <div id="overview-announcer" class="sr-only" aria-live="polite" aria-atomic="true">
          {@announce}
        </div>

        <%= if @checklist? do %>
          <.onboarding keys={@keys} preview={@preview} landed={@landed} />
          <.access_keys
            :if={@keys != [] && !@live?}
            keys={Enum.take(@keys, @shown)}
            total={length(@keys)}
            last_runs={%{}}
            hosts={%{}}
            create?={false}
          />
        <% end %>

        <%= if @live? do %>
          <.attention
            :if={@attention_items}
            id="attention"
            items={Enum.take(@attention_items, @shown)}
            count={@attention_count}
            more={@attention_more}
            owner?={@owner?}
            now={@now}
          />

          <.strip alive={@alive} facts={@facts} destinations={@destinations} />

          <div class="q-grid2">
            <section class="q-sect" id="overview-activity" aria-labelledby="overview-activity-h">
              <h2 class="sr-only" id="overview-activity-h">{gettext("Activity")}</h2>
              <div class="q-part">
                <%= cond do %>
                  <% @failed[:activity] -> %>
                    <.notice kind={:info}>
                      <span id="activity-error">{not_loaded()}</span>
                    </.notice>
                  <% @alive_runs -> %>
                    <.alive_rows
                      id="alive"
                      runs={Enum.take(@alive_runs, @shown)}
                      count={@alive}
                      now={@now}
                    />
                  <% true -> %>
                    <div class="q-part-h">
                      <h3>{gettext("Alive now")}</h3>
                    </div>
                    <.skeleton_lines lines={3} />
                <% end %>
              </div>
              <div class="q-part">
                <.days_chart
                  id="days"
                  days={@days}
                  today={@today}
                  table?={@table?}
                  narrow?={@narrow?}
                />
              </div>
              <div class="q-part">
                <p class="q-foot" id="activity-foot">
                  {gettext("Counted from the hive's runs by the day they started, UTC.")}
                  <span class="q-live-on">{gettext("Updated as batches land.")}</span>
                  <span class="q-live-off">{gettext("Reconnecting.")}</span>
                  <span :if={@connections == :unavailable} id="activity-uncounted" class="text-muted">
                    {gettext(
                      "Denied destinations were not counted: this hive recorded more than %{cap} connections in 7 days. The connections page counts them by destination.",
                      cap: delimited(Policy.Activity.cap())
                    )}
                  </span>
                </p>
              </div>
            </section>
            <div class="q-stack">
              <%= if @failed[:policy] do %>
                <.sect id="overview-policy" title={gettext("Policy")}>
                  <div class="q-lines">
                    <.notice kind={:info}>
                      <span id="policy-error">{not_loaded()}</span>
                    </.notice>
                  </div>
                </.sect>
              <% else %>
                <.policy_glance policy={@policy} />
              <% end %>
              <.retention_glance
                hive={@current_scope.hive}
                runs={@key_facts && @key_facts.retention}
                now={@now}
              />
            </div>
          </div>

          <.recent_runs
            id="last-runs"
            runs={@recent}
            quiet_ids={@quiet_ids}
            new_runs={@new_runs}
            now={@now}
          />

          <.access_keys
            :if={@keys != []}
            keys={Enum.take(@keys, @shown)}
            total={length(@keys)}
            last_runs={@key_facts && @key_facts.last_runs}
            hosts={@key_facts && @key_facts.hosts}
            create?={true}
          />
        <% end %>
      </div>

      <.rule_popover :if={@popover} popover={@popover} />

      <.modal
        :if={@confirm_close}
        id="close-run"
        title={gettext("Close this run")}
        on_cancel={JS.push("close_cancel")}
        size="sm"
      >
        <p>
          <.rich text={
            rich_gettext(
              "The hive stops taking events for %{run}: the runner is told the run is gone at its next delivery. The record kept so far stays. A close is final: nothing reopens the run.",
              run: close_title(@confirm_close)
            )
          } />
        </p>
        <:footer>
          <.button phx-click="close_cancel" data-autofocus>{gettext("Cancel")}</.button>
          <.button
            id="close-confirm"
            variant="danger"
            phx-click="close_confirm"
            loading_text={gettext("Closing")}
          >
            {gettext("Close run")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  ## Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    now = DateTime.utc_now()
    keys = scope |> AccessKeys.list_access_keys() |> Enum.filter(&is_nil(&1.revoked_at))
    alive = Runs.count_alive(scope)
    posted? = alive > 0 or Runs.recent_runs(scope, 1) != []

    if connected?(socket) do
      Runs.subscribe(scope)
      Policy.subscribe(scope)
      Process.send_after(self(), :quiet_tick, window(:quiet_tick, 5_000))
      Process.send_after(self(), :refresh, window(:refresh, 60_000))
    end

    socket =
      socket
      |> assign(
        page_title: scope.hive.name,
        shown: @shown,
        keys: sort_keys(keys),
        alive: alive,
        mode: Policy.mode_summary(scope),
        checklist?: not posted?,
        live?: posted?,
        landed: nil,
        now: now,
        today: DateTime.to_date(now),
        owner?: Common.owner?(scope),
        preview: preview(keys),
        table?: false,
        narrow?: false,
        popover: nil,
        confirm_close: nil,
        announce: nil,
        announced_at: nil,
        failed: %{},
        # The regions, nil while their read is in flight.
        alive_runs: nil,
        recent: nil,
        days: empty_days(DateTime.to_date(now)),
        facts: nil,
        drift: %{},
        connections: nil,
        destinations: nil,
        lost: [],
        policy: nil,
        key_facts: nil,
        attention_items: nil,
        attention_count: 0,
        attention_more: nil,
        quiet_ids: MapSet.new(),
        new_runs: 0,
        new_ids: MapSet.new(),
        seen: %{},
        run_window: :closed,
        policy_window: :closed,
        landed_reads: MapSet.new(),
        settled: false
      )

    {:ok, if(connected?(socket) and posted?, do: load(socket), else: socket)}
  end

  # The four reads that fill the page, none blocking the first paint (oj 1).
  defp load(socket) do
    socket
    |> read(:activity)
    |> read(:attention)
    |> read(:policy)
    |> read(:keys)
  end

  defp read(socket, :activity) do
    %{current_scope: scope, today: today} = socket.assigns
    start_async(socket, :activity, fn -> read_activity(scope, today, DateTime.utc_now()) end)
  end

  defp read(socket, :attention) do
    scope = socket.assigns.current_scope
    start_async(socket, :attention, fn -> read_attention(scope, DateTime.utc_now()) end)
  end

  defp read(socket, :policy) do
    scope = socket.assigns.current_scope
    start_async(socket, :policy, fn -> read_policy(scope, DateTime.utc_now()) end)
  end

  # The keys' facts: the last run and the hosts of each key shown, and the last prune.
  defp read(socket, :keys) do
    scope = socket.assigns.current_scope
    ids = socket.assigns.keys |> Enum.take(@shown) |> Enum.map(& &1.id)

    start_async(socket, :keys, fn ->
      since = DateTime.add(DateTime.utc_now(), -@thresholds.denied_days, :day)

      %{
        last_runs: Runs.last_runs_by_key(scope, ids),
        hosts: Runs.hosts_by_key(scope, ids, since),
        retention: Retention.list_retention_runs(scope, 1)
      }
    end)
  end

  ## The reads (oj 3 to 7). Each runs in its own task; nothing here touches the socket.

  defp read_activity(scope, today, now) do
    from = start_of(Date.add(today, -(@thresholds.chart_days - 1)))
    alive_runs = Runs.list_alive(scope, @shown)

    %{
      days: Runs.day_facts(scope, from),
      alive_runs: alive_runs,
      recent: Runs.recent_runs(scope, @shown),
      drift: drift_facts(scope, alive_runs),
      alive: Runs.count_alive(scope),
      today: today,
      read_at: now
    }
  end

  # Today's column, the alive rows and the last runs again: what a run change can move.
  defp read_today(scope, today, now) do
    alive_runs = Runs.list_alive(scope, @shown)

    %{
      today: Runs.day_facts(scope, start_of(today)),
      alive_runs: alive_runs,
      recent: Runs.recent_runs(scope, @shown),
      drift: drift_facts(scope, alive_runs),
      alive: Runs.count_alive(scope),
      lost: Runs.lost_since(scope, DateTime.add(now, -@thresholds.lost_days, :day), @shown + 1),
      read_at: now
    }
  end

  defp read_attention(scope, now) do
    since = DateTime.add(now, -@thresholds.denied_days, :day)
    window = DateTime.add(now, -@thresholds.chart_days, :day)

    %{
      connections: Policy.overview_activity(scope, since, window),
      lost: Runs.lost_since(scope, since, @shown + 1),
      keys: scope |> AccessKeys.list_access_keys() |> Enum.filter(&is_nil(&1.revoked_at)),
      read_at: now
    }
  end

  defp read_policy(scope, now) do
    summary = Policy.mode_summary(scope)
    targets = Policy.list_targets(scope)
    rules = Policy.list_rules(scope, nil)

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
      own: Enum.filter(targets, &(&1.own_mode != nil)),
      version: version,
      allow_rules: Enum.count(rules, &(&1.kind == "host" and &1.action == "allow")),
      suggestions:
        Policy.suggestion_counts(scope, DateTime.add(now, -@thresholds.chart_days, :day)),
      read_at: now
    }
  end

  # What the alive runs report against what is in force, in one bulk read; the reported
  # version is looked up for a run that is behind, and only then (pd9).
  defp drift_facts(scope, runs) do
    reported = Enum.filter(runs, &is_binary(&1.reported_run_configuration_digest))

    if reported == [] do
      %{}
    else
      holders = reported |> Enum.map(& &1.target_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      versions = Policy.newest_versions(scope, [nil | holders])

      for run <- reported,
          in_force = versions[run.target_id] || versions[nil],
          in_force.digest != run.reported_run_configuration_digest,
          into: %{} do
        reported_version =
          case Policy.configuration_for_digest(
                 scope,
                 holder_of(scope, run.target_id),
                 run.reported_run_configuration_digest
               ) do
            {:ok, configuration} -> version_map(configuration)
            _ -> nil
          end

        {run.id, %{in_force: version_map(in_force), reported: reported_version}}
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

  defp version_map(configuration) do
    %{
      n: configuration.version,
      digest: configuration.digest,
      rendered_at: configuration.rendered_at,
      target_id: configuration.target_id,
      path: Rules.version_path(configuration.target_id, configuration.version)
    }
  end

  ## Results

  @impl true
  def handle_async(:activity, {:ok, read}, socket) do
    socket =
      socket
      |> assign(
        alive_runs: read.alive_runs,
        recent: read.recent,
        drift: read.drift,
        alive: read.alive,
        today: read.today,
        failed: Map.delete(socket.assigns.failed, :activity),
        landed_reads: MapSet.put(socket.assigns.landed_reads, :activity)
      )
      |> remember(read.alive_runs ++ read.recent)
      |> put_days(read.days, read.today)
      |> tick(read.read_at)

    {:noreply, recompute(socket)}
  end

  def handle_async(:today, {:ok, read}, socket) do
    %{alive_runs: shown, recent: recent, new_ids: new_ids} = socket.assigns

    # Alive rows: the ones on the page are patched in place, a run that ended leaves, a run
    # that is new appends; the last runs never gain a row under the reader (oj 8).
    alive_ids = Enum.map(shown || [], & &1.id)
    fresh = Map.new(read.alive_runs, &{&1.id, &1})

    kept =
      (shown || [])
      |> Enum.map(&Map.get(fresh, &1.id, &1))
      |> Enum.filter(&(&1.state in Run.alive_states()))

    arrived = Enum.reject(read.alive_runs, &(&1.id in alive_ids))
    alive_runs = kept ++ Enum.map(arrived, &Map.put(&1, :arrived, true))

    # The last runs: patched in place; the fresh list whole when the reader asked for it
    # (`show_new`) or nothing was on the page yet.
    {recent, unseen} =
      case recent do
        nil ->
          {read.recent, MapSet.new()}

        shown ->
          on_page = Enum.map(shown, & &1.id)
          patched = Enum.map(shown, fn run -> Enum.find(read.recent, run, &(&1.id == run.id)) end)

          {patched,
           read.recent |> Enum.map(& &1.id) |> Enum.reject(&(&1 in on_page)) |> MapSet.new()}
      end

    new_ids = MapSet.union(new_ids, unseen)

    socket =
      socket
      |> assign(
        alive_runs: alive_runs,
        recent: recent,
        drift: read.drift,
        alive: read.alive,
        lost: read.lost,
        new_ids: new_ids,
        new_runs: MapSet.size(new_ids)
      )
      |> remember(read.alive_runs ++ read.recent ++ read.lost)
      |> put_today(read.today)
      |> tick(read.read_at)

    socket =
      if MapSet.size(new_ids) > MapSet.size(socket.assigns.new_ids),
        do: announce(socket, new_runs_text(MapSet.size(new_ids))),
        else: socket

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

  def handle_async(:keys, {:ok, read}, socket) do
    {:noreply, assign(socket, key_facts: read, failed: Map.delete(socket.assigns.failed, :keys))}
  end

  def handle_async(name, {:exit, _reason}, socket) do
    failed = Map.put(socket.assigns.failed, if(name == :today, do: :activity, else: name), true)
    socket = assign(socket, failed: failed)

    # A failed read of the keys' facts still shows the keys, with nothing after them.
    socket =
      if name == :keys,
        do: assign(socket, key_facts: %{last_runs: %{}, hosts: %{}, retention: []}),
        else: socket

    {:noreply, socket}
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(_unavailable), do: :unavailable

  ## Live

  @impl true
  def handle_info({:run_changed, %Run{} = run}, %{assigns: %{live?: false}} = socket) do
    # The first run has landed: the checklist ticks its third step and stays (oe6); the
    # activity and the cards render under it.
    socket =
      socket
      |> assign(live?: true, landed: run, alive: Runs.count_alive(socket.assigns.current_scope))
      |> remember([run])
      |> load()

    {:noreply, socket}
  end

  def handle_info({:run_changed, %Run{} = run}, socket) do
    socket = socket |> patch_run(run) |> remember([run])

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

    {:noreply, recheck_popover(socket)}
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
      # The checklist reads its steps from the record: a key used since is step 2 done.
      keys =
        socket.assigns.current_scope
        |> AccessKeys.list_access_keys()
        |> Enum.filter(&is_nil(&1.revoked_at))

      {:noreply,
       assign(socket, keys: sort_keys(keys), preview: preview(keys), now: DateTime.utc_now())}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The coalesced re-read: today's column, the alive rows, the last runs, the lost runs. At
  # midnight UTC the window has moved: the fourteen days are read anew.
  defp refresh_runs(%{assigns: %{live?: true}} = socket) do
    %{current_scope: scope, today: today} = socket.assigns
    now = DateTime.utc_now()

    if Date.compare(DateTime.to_date(now), today) == :gt do
      new_today = DateTime.to_date(now)

      socket
      |> assign(today: new_today)
      |> then(&start_async(&1, :activity, fn -> read_activity(scope, new_today, now) end))
    else
      start_async(socket, :today, fn -> read_today(scope, today, now) end)
    end
  end

  defp refresh_runs(socket), do: socket

  # A run on the page is patched from the message, in place; a run that is not is a new
  # run in words (rj 6), never a row inserted under the reader.
  defp patch_run(socket, %Run{} = run) do
    %{alive_runs: alive_runs, recent: recent} = socket.assigns

    alive_runs =
      alive_runs &&
        alive_runs
        |> Enum.map(
          &if(&1.id == run.id, do: Map.put(run, :arrived, Map.get(&1, :arrived, false)), else: &1)
        )
        |> Enum.filter(&(&1.state in Run.alive_states()))

    recent = recent && Enum.map(recent, &if(&1.id == run.id, do: run, else: &1))
    socket |> assign(alive_runs: alive_runs, recent: recent) |> recompute()
  end

  ## Events

  @impl true
  def handle_event("chart_table", %{"on" => on}, socket) do
    {:noreply, assign(socket, :table?, on == true or on == "true")}
  end

  # The browser knows the chart's width; the phone geometry is drawn on the server (oi).
  def handle_event("chart_size", %{"narrow" => narrow}, socket) do
    {:noreply, assign(socket, :narrow?, narrow == true or narrow == "true")}
  end

  def handle_event("show_new", _params, socket) do
    %{current_scope: scope, today: today} = socket.assigns
    now = DateTime.utc_now()

    socket =
      socket
      |> assign(new_ids: MapSet.new(), new_runs: 0, recent: nil)
      |> then(&start_async(&1, :today, fn -> read_today(scope, today, now) end))

    {:noreply, socket}
  end

  def handle_event("close_ask", %{"id" => id}, socket) do
    case find_item(socket, id) do
      %{kind: :lost, run: run, resolved: nil} -> {:noreply, assign(socket, :confirm_close, run)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_cancel", _params, socket),
    do: {:noreply, assign(socket, :confirm_close, nil)}

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
          |> announce(gettext("%{run} is closed.", run: run_title(run)), :now)
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

  ## The one-click allow of a denied destination (od2): the popover of pd8, called with the
  ## destination's targets, exactly as the connections page calls it.

  def handle_event("rule_open", %{"id" => id, "level" => level}, socket) do
    case find_item(socket, id) do
      %{kind: :denied, resolved: nil, locked: nil} = item ->
        {:noreply, open_popover(socket, item, level)}

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
        "target" when popover.targets != [] -> :target
        "hive" -> :hive
        _ -> popover.level
      end

    choice =
      case params["target"] do
        id when is_binary(id) -> if Enum.any?(popover.targets, &(&1.id == id)), do: id
        _ -> popover.choice
      end

    popover = %{popover | level: level, choice: choice, error: nil}

    popover =
      if choice != popover.chosen,
        do: describe(socket, popover, chosen_effective(socket, choice)),
        else: popover

    {:noreply, assign(socket, popover: popover)}
  end

  def handle_event("rule_cancel", _params, socket), do: {:noreply, close_popover(socket)}

  def handle_event(
        "rule_submit",
        _params,
        %{assigns: %{popover: %{refusal: nil, level: level} = popover}} = socket
      )
      when level in [:target, :hive] do
    scope = socket.assigns.current_scope

    with :ok <- still(socket, popover),
         {:ok, from} <- rule_source(popover),
         {:ok, connection} <- Runs.fetch_connection(scope, from.connection_id),
         {:ok, rule} <- Policy.rule_from_connection(scope, connection, :allow, level) do
      where = if level == :target, do: {:target, from.label}, else: :hive

      done =
        if level == :target, do: gettext("Allowed here"), else: gettext("Allowed for the hive")

      socket =
        socket
        |> close_popover()
        |> resolve_item(popover.item_id, %{mark: :allowed, what: nil, done: done})
        |> announce(Rules.toast(rule, :allow, popover.host, popover.path, where), :now)
        |> focus_after(popover.item_id)

      {:noreply, socket}
    else
      :stale ->
        {:noreply,
         socket
         |> close_popover()
         |> read(:attention)
         |> put_flash(
           :info,
           gettext("The policy changed under you; the rows were read again. Nothing was written.")
         )}

      {:error, %Policy.Error{message: message}} ->
        {:noreply, assign(socket, popover: %{popover | error: message})}

      _not_found ->
        {:noreply,
         socket
         |> close_popover()
         |> put_flash(
           :error,
           gettext("This destination is no longer among the connections shown.")
         )}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(rule_change rule_submit),
    do: {:noreply, socket}

  defp open_popover(socket, item, level) do
    scope = socket.assigns.current_scope

    reached =
      Runs.destination_targets(scope, @denied_filters, {item.host, item.port, item.path})

    targets =
      for %{target_id: id} = r when is_binary(id) <- reached do
        %{
          id: id,
          label: "#{r.system}/#{r.path}",
          runs: r.runs,
          connection_id: r.connection_id
        }
      end

    {level, choice} =
      case {level, targets} do
        {"hive", _} -> {:hive, nil}
        {"target", [one]} -> {:target, one.id}
        {"target", _} -> {nil, nil}
        _ -> {nil, nil}
      end

    baseline = Policy.effective(scope, nil)
    chosen = if choice, do: chosen_effective(socket, choice)

    popover = %{
      item_id: item.id,
      anchor: "#{item.id}-act",
      any_connection_id: reached |> List.first() |> then(&(&1 && &1.connection_id)),
      action: :allow,
      host: item.host,
      path: item.path,
      page: :hive,
      level: level,
      target: nil,
      targets: targets,
      choice: choice,
      baseline: baseline,
      standing: :can_allow,
      chosen: nil,
      what: %{target: nil, hive: nil},
      own_rule: false,
      seen: nil,
      consequence: %{},
      hive: scope.hive.name,
      alive: false,
      fetched: false,
      interval: 30,
      error: nil,
      refusal: nil,
      own: Rules.own_hosts(scope)
    }

    socket |> assign(popover: describe(socket, popover, chosen)) |> mark_expanded()
  end

  defp close_popover(socket), do: socket |> assign(popover: nil) |> mark_expanded()

  # The row's button says whether its popover is open (aria-expanded).
  defp mark_expanded(%{assigns: %{attention_items: items}} = socket) when is_list(items) do
    open = socket.assigns.popover && socket.assigns.popover.item_id
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

  defp rule_source(%{level: :hive, any_connection_id: id}) when is_binary(id),
    do: {:ok, %{connection_id: id, label: gettext("the hive"), target: nil}}

  defp rule_source(_popover), do: :error

  defp chosen_effective(_socket, nil), do: nil

  defp chosen_effective(socket, id) do
    case Policy.get_target(socket.assigns.current_scope, id) do
      {:ok, target} -> Policy.effective(socket.assigns.current_scope, target)
      _ -> nil
    end
  end

  defp describe(_socket, popover, chosen) do
    %{host: host, path: path, baseline: baseline, own: own} = popover
    own? = Rules.own_touches?(own, host) or Rules.own_rule?(chosen, host)

    %{
      popover
      | chosen: popover.choice,
        what: %{
          target: Rules.what(chosen, host, path),
          hive: Rules.what(baseline, host, path)
        },
        own_rule: own?,
        seen: {Rules.seen(baseline, host), Rules.seen(chosen, host)},
        consequence: %{
          target: chosen && target_consequence(chosen, host),
          hive: hive_consequence(baseline, host, own?)
        }
    }
  end

  defp target_consequence(effective, host) do
    if Rules.own_rule?(effective, host),
      do: gettext("Replaces the target's own rule for the host."),
      else: gettext("Disables the hive's allow rule there. Other targets keep it.")
  end

  defp hive_consequence(baseline, host, own?) do
    cond do
      own? -> gettext("A target's own allow rule still holds there.")
      Rules.seen(baseline, host) != [] -> gettext("Replaces the hive's allow rule.")
      true -> nil
    end
  end

  # Sent only while the policy is still the one the popover opened on, for its host.
  defp still(socket, popover) do
    scope = socket.assigns.current_scope
    baseline = Policy.effective(scope, nil)
    chosen = chosen_effective(socket, popover.chosen)

    if {Rules.seen(baseline, popover.host), Rules.seen(chosen, popover.host)} == popover.seen,
      do: :ok,
      else: :stale
  end

  # A change of the policy under an open popover closes it when it touches its host.
  defp recheck_popover(%{assigns: %{popover: %{refusal: nil} = popover}} = socket) do
    if still(socket, popover) == :ok, do: socket, else: close_popover(socket)
  end

  defp recheck_popover(socket), do: socket

  ## The attention list (od1): built from the record in assigns, merged into what is shown.

  # Every candidate item, in the order of od1. Nothing here queries.
  defp candidates(assigns) do
    now = assigns.now
    since_lost = DateTime.add(now, -@thresholds.lost_days, :day)

    denied =
      case assigns.connections do
        %{denied: rows} ->
          for row <- rows do
            Map.merge(row, %{
              id: "att-denied-#{:erlang.phash2({row.host, row.port, row.path}, 4_294_967_296)}",
              kind: :denied
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
          compare: compare_path(in_force, facts.reported)
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
      for key <- assigns.keys,
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

  defp compare_path(in_force, %{n: m, target_id: same}) when same == in_force.target_id,
    do: Rules.version_path(in_force.target_id, in_force.n, %{"compare" => m})

  defp compare_path(in_force, _reported), do: in_force.path

  defp idle_days(%AccessKey{last_used_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at, :day)

  defp idle_days(%AccessKey{inserted_at: %DateTime{} = at}, now), do: DateTime.diff(now, at, :day)
  defp idle_days(_key, _now), do: nil

  # The list as shown: rows already there keep their place and are patched, rows whose item
  # is gone are struck with the resolution in words, new items append (oa 5).
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

      # Settled once a recompute has seen the first three reads land: the list this one
      # produces is the first the reader can have read in full.
      settled? = assigns.settled

      all_landed? =
        MapSet.subset?(MapSet.new([:activity, :attention, :policy]), assigns.landed_reads)

      arrived =
        candidates
        |> Enum.reject(&MapSet.member?(known, &1.id))
        |> Enum.map(&Map.merge(&1, %{arrived: settled?, resolved: nil}))

      # Until the first reads have all landed the list is sorted as od1 orders it, whatever
      # read came first; from then on rows keep their place and new ones append.
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
          attention_more: more_link(hidden),
          quiet_ids: MapSet.new(for %{kind: :quiet, run: run} <- unresolved, do: run.id)
        )

      if settled? and shown != [] and arrived != [],
        do:
          announce(
            socket,
            ngettext(
              "%{count} more item needs attention.",
              "%{count} more items need attention.",
              length(arrived)
            )
          ),
        else: socket
    else
      socket
    end
  end

  # The overflow is counted per kind; the link goes to the kind that overflowed first.
  defp more_link([]), do: nil

  defp more_link([first | _] = hidden) do
    count = length(hidden)

    case first.kind do
      :denied ->
        %{
          count: count,
          navigate: ~p"/hive/connections?#{%{"decision" => "denied"}}",
          title:
            ngettext(
              "%{count} more item, on the connections page",
              "%{count} more items, on the connections page",
              count
            )
        }

      kind when kind in [:lost, :quiet, :behind] ->
        %{
          count: count,
          navigate: ~p"/hive/runs?#{%{"state" => "pending,running,lost"}}",
          title:
            ngettext(
              "%{count} more item, on the runs list",
              "%{count} more items, on the runs list",
              count
            )
        }

      _ ->
        %{
          count: count,
          navigate: ~p"/hive/keys",
          title:
            ngettext(
              "%{count} more item, on the keys page",
              "%{count} more items, on the keys page",
              count
            )
        }
    end
  end

  # What became of an item that is no longer on the record's list, in words (oe7).
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
        do: gettext("Enforce is the hive's default."),
        else: gettext("Nothing to enforce yet.")

    %{mark: :resolved, what: what, done: nil}
  end

  defp resolution(%{kind: :unmanaged}, _assigns),
    do: %{mark: :resolved, what: gettext("Qory serves the policy now."), done: nil}

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
      attention_more: more_link(hidden)
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
      id: if(next, do: "#{next.id}-act", else: "last-runs-all")
    })
  end

  ## The chart's days and the strip's facts

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

  # The server block the checklist previews: the real key id of the most recent key once
  # there is one, the secret always as dots (it was shown once).
  defp preview(keys) do
    key_id =
      case Enum.sort_by(keys, & &1.inserted_at, {:desc, DateTime}) do
        [%AccessKey{key_id: key_id} | _] -> key_id
        [] -> "ak_················"
      end

    AccessKeys.server_block(
      %AccessKey{key_id: key_id},
      "························",
      ApiaryWeb.Endpoint.url()
    )
  end

  defp not_loaded,
    do:
      gettext(
        "This could not be loaded. Reload the page; if it keeps happening, the server log has the reason."
      )

  # The run the close dialog names, in bold inside its sentence.
  defp close_title(run), do: {:b, run_title(run), "font-medium"}

  defp new_runs_text(n),
    do: ngettext("%{number} new run", "%{number} new runs", n, number: delimited(n))

  # What became of a run that ended while it was on the list.
  defp ended("succeeded"), do: gettext("Succeeded.")
  defp ended("failed"), do: gettext("Failed.")
  defp ended("timed_out"), do: gettext("Timed out.")
  defp ended(state), do: "#{ApiaryWeb.RunComponents.state_label(state)}."

  # `config :apiary, ApiaryWeb.HiveLive.Overview, coalesce: 0, quiet_tick: …` in a test.
  defp window(name, default) do
    :apiary |> Application.get_env(__MODULE__, []) |> Keyword.get(name, default)
  end
end
