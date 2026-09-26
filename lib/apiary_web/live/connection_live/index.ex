defmodule ApiaryWeb.ConnectionLive.Index do
  @moduledoc """
  Where the runs of the hive reached out to (`docs/design/brief-runs.md`, rd13 and re6): one
  row per host, port and path across the runs in range, with the reason and the outcome of
  the most recent attempt, and behind each row's chevron the runs that reached it. "Per
  target" is this page with `repo` set, which the runs list links to.

  Every filter is a query parameter (`decision`, `repo`, `host`, `tools`, `since`, `from`,
  `to`, `page`), read through `Apiary.Runs.Filters`. A tool invocation
  (`Apiary.Runs.tool_invocation?/2`) is a destination like any other and reads as a call to
  its tool (`ApiaryWeb.RunComponents.connection_row/1`); a request a path rule refused
  before it reached the tool reads as any denial. `tools=1` keeps only the destinations of
  tool invocations. A destination's runs are read only when its
  row opens, ten at a time. While batches land the table does not move under the reader:
  the summary gains "New activity", which asks again and keeps the open rows open.

  Each row may ask the policy for a rule (`docs/design/brief-policy.md`, pd8). A row's
  standing is derived from one effective policy the page holds: the hive's baseline, or
  the target's when `repo` names one. The scope of a new rule is never guessed: among
  several targets none is chosen until the reader chooses. The rule itself is made
  by `Apiary.Policy.rule_from_connection/4` from the most recent connection of the
  destination in the chosen scope, and what the domain refuses is said in its sentence.

  The rows are the record (`observability`); the rules are `security`'s. On an instance
  without `security` (decision 0070) the page is the record alone: no Reason column (which
  rule matched, in which mode), no Allow or Deny, no popover, no link to a policy, and
  the policy is neither read nor followed. A rule event that arrives all the same is
  dropped before anything is looked up.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability

  alias Apiary.Features
  alias Apiary.Policy
  alias Apiary.Runs
  alias Apiary.Runs.Filters
  alias ApiaryWeb.ConnectionLive.Rules

  @hits_page 10
  @coalesce_ms 250
  # The contract's default heartbeat, for "about 30 s" on a page that is of no one run.
  @default_beat 30

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:connections}
      width="full"
    >
      <.header>
        {gettext("Connections")}
        <:subtitle>
          {if @security,
            do:
              gettext(
                "Where the runs of this hive reached out to, and what the policy made of it. One row per host, port and path, across runs."
              ),
            else:
              gettext(
                "Where the runs of this hive reached out to. One row per host, port and path, across runs."
              )}
          <span :if={@filters.target} id="connections-target-note">
            <.rich text={
              rich_gettext("Showing %{target} only.",
                target: mono_part(target_label(@filters.target))
              )
            } />
            <.link
              :if={@security && @target}
              id="connections-target-policy"
              navigate={Rules.target_policy_path(@target.id)}
              class="q-link"
            >
              {gettext("Its policy")}
            </.link>
          </span>
        </:subtitle>
      </.header>

      <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
        <span id="connections-error">
          {gettext(
            "The connections could not be loaded. Reload the page; if it keeps happening, the server log has the reason."
          )}
        </span>
      </.notice>

      <.notice :if={@dropped != []} kind={:warning} class="max-w-[80ch]">
        <span id="connections-dropped">{dropped_sentence(@dropped)}</span>
      </.notice>

      <div :if={!@load_error} class="grid grid-cols-[minmax(0,1fr)] gap-6">
        <.filter_bar
          id="connections-filters"
          clear={Filters.any?(@filters) && path(Filters.clear(@filters))}
        >
          <.segments id="connections-decision" label={gettext("Decision")}>
            <:segment
              :for={
                {label, value} <- [
                  {gettext("All"), nil},
                  {gettext("Allowed"), "allowed"},
                  {gettext("Denied"), "denied"}
                ]
              }
              patch={path(Filters.put(@filters, decision: value))}
              pressed={@filters.decision == value}
            >
              {label}
            </:segment>
          </.segments>
          <.filter
            name="target"
            total={facet_total(@facets, :target)}
            query={@narrow["target"]}
            label={gettext("Target")}
            value={Filters.target_value(@filters.target)}
            options={
              with_chosen(
                facet_options(@facets, :target),
                Filters.target_value(@filters.target),
                target_label(@filters.target)
              )
            }
            remove={path(Filters.put(@filters, target: nil))}
          />
          <.filter
            name="host"
            total={facet_total(@facets, :host)}
            query={@narrow["host"]}
            label={gettext("Host")}
            value={@filters.host}
            options={with_chosen(facet_options(@facets, :host), @filters.host, @filters.host)}
            remove={path(Filters.put(@filters, host: nil))}
          />
          <.filter_toggle
            id="connections-tools"
            name="tools"
            label={gettext("Tool invocations")}
            icon="hero-wrench-screwdriver-micro"
            pressed={@filters.tools}
            patch={path(Filters.put(@filters, tools: !@filters.tools))}
          />
          <.filter
            name="since"
            label={gettext("Seen")}
            value={range_value(@filters)}
            value_label={Filters.range_label(@filters)}
            options={for {label, value} <- Filters.ranges(:connections), do: {label, value, nil}}
            dates={
              %{
                from: @filters.from && Date.to_iso8601(@filters.from),
                to: @filters.to && Date.to_iso8601(@filters.to)
              }
            }
            remove={
              @filters.since != "90d" && path(Filters.put(@filters, since: "90d", from: nil, to: nil))
            }
          />
          <:trailing>
            <span id="connections-summary" class="q-summary">
              <span :if={@listing}>
                <.rich text={
                  rich_ngettext(
                    "%{number} destination",
                    "%{number} destinations",
                    @listing.summary.destinations,
                    number: {:b, delimited(@listing.summary.destinations)}
                  )
                } />
              </span>
              <span :if={@listing && @listing.summary.denied > 0}>
                <.rich text={
                  rich_ngettext("%{number} denied", "%{number} denied", @listing.summary.denied,
                    number: {:b, delimited(@listing.summary.denied)}
                  )
                } />
              </span>
              <span :if={@listing}>
                <.rich text={
                  rich_ngettext("%{number} run", "%{number} runs", @listing.summary.runs,
                    number: {:b, delimited(@listing.summary.runs)}
                  )
                } />
              </span>
              <span :if={!@listing} class="skeleton q-skel w-44"></span>
              <.link :if={@stale} id="connections-refresh" phx-click="refresh" href="#">
                {gettext("New activity")}
              </.link>
            </span>
          </:trailing>
        </.filter_bar>

        <div
          :if={@listing == nil}
          id="connections-loading"
          class="overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
          aria-busy="true"
        >
          <table class="table q-cxt">
            <thead>
              <tr>
                <th :for={
                  label <-
                    [
                      gettext("Destination"),
                      gettext("Runs"),
                      gettext("Attempts"),
                      gettext("Allowed / denied"),
                      @security && gettext("Reason"),
                      gettext("Outcome"),
                      gettext("Last seen")
                    ]
                    |> Enum.filter(& &1)
                }>
                  {label}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={n <- 1..8}>
                <td>
                  <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-56", else: "w-44")]}></span>
                </td>
                <td><span class="skeleton q-skel w-6"></span></td>
                <td><span class="skeleton q-skel w-8"></span></td>
                <td><span class="skeleton q-skel w-24"></span></td>
                <td :if={@security}><span class="skeleton q-skel w-48"></span></td>
                <td><span class="skeleton q-skel w-16"></span></td>
                <td><span class="skeleton q-skel w-20"></span></td>
              </tr>
            </tbody>
          </table>
        </div>

        <.connections_table
          :if={@listing && @listing.rows != []}
          id="destinations"
          label={gettext("Connections of this hive")}
          variant="hive"
          rows={@listing.rows}
          row_id={&destination_id/1}
          open={@open}
          run_path={&run_path/1}
          acts={@acts}
          security={@security}
        />

        <.empty_state
          :if={@listing && @listing.rows == []}
          icon="hero-arrows-right-left"
          tone="neutral"
          title={empty_title(@filters)}
        >
          <span id="connections-empty">
            {if narrowed?(@filters),
              do: gettext("No destination matches them in this range."),
              else:
                gettext(
                  "Widen the range, or wait for a run to reach out. Only programs that honour the proxy variables are seen."
                )}
          </span>
          <:actions>
            <.button
              :if={narrowed?(@filters)}
              id="connections-clear"
              patch={path(Filters.clear(@filters))}
            >
              {gettext("Clear filters")}
            </.button>
          </:actions>
        </.empty_state>

        <div
          :if={@listing && @listing.rows != []}
          class="flex flex-wrap items-center justify-between gap-3"
        >
          <p id="connections-footer" class="max-w-[80ch] text-[12.5px] text-faint">
            {if @security,
              do:
                gettext(
                  "Denied destinations come first, then the most recent. The reason and outcome are those of the last attempt across the runs shown. A rule added here changes what happens next; what the record already says stays as it was."
                ),
              else:
                gettext(
                  "Denied destinations come first, then the most recent. The outcome is that of the last attempt across the runs shown."
                )}
          </p>
          <div :if={@listing.pages > 1} class="flex items-center gap-2">
            <.button
              id="connections-previous"
              patch={path(%{@filters | page: @listing.page - 1})}
              disabled={@listing.page <= 1}
            >
              {gettext("Previous")}
            </.button>
            <.button
              id="connections-next"
              patch={path(%{@filters | page: @listing.page + 1})}
              disabled={@listing.page >= @listing.pages}
            >
              {gettext("Next")}
            </.button>
          </div>
        </div>
      </div>

      <.rule_popover :if={@security && @popover} popover={@popover} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    security = Features.on?(scope, :security)

    if connected?(socket) do
      Runs.subscribe(scope)
      if security, do: Policy.subscribe(scope)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Connections"),
       filters: %Filters{kind: :connections},
       listing: nil,
       facets: %{},
       open: %{},
       stale: false,
       load_error: false,
       dropped: [],
       narrow: %{},
       target: nil,
       effective: nil,
       acts: nil,
       popover: nil,
       own: [],
       policy_flush_scheduled: false,
       security: security
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Filters.parse(params, :connections)

    if Filters.to_params(filters) == params do
      # What is open belongs to the view it was opened in.
      open = if Filters.same?(filters, socket.assigns.filters), do: socket.assigns.open, else: %{}

      {:noreply,
       socket
       |> keep_dropped()
       |> assign(filters: filters, open: open, popover: nil)
       |> load()}
    else
      {:noreply,
       socket
       |> assign(:dropped, filters.dropped)
       |> put_private(:rewrote, true)
       |> push_patch(to: path(%{filters | dropped: []}), replace: true)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(Filters.change(socket.assigns.filters, params)))}
  end

  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket)
      when name in ~w(repo host) and is_binary(q) do
    %{current_scope: scope, filters: filters} = socket.assigns
    narrow = Map.put(socket.assigns.narrow, name, String.slice(q, 0, 256))

    {:noreply,
     socket
     |> assign(:narrow, narrow)
     |> start_async(:facets, fn ->
       %{
         filters: filters,
         narrow: narrow,
         facets: Runs.destination_facets(scope, filters, narrow: narrow)
       }
     end)}
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("toggle_destination", params, socket) do
    %{open: open} = socket.assigns

    case find_row(socket, params) do
      nil ->
        {:noreply, socket}

      row ->
        key = destination_key(row)

        if is_map_key(open, key),
          do: {:noreply, assign(socket, :open, Map.delete(open, key))},
          else:
            {:noreply, assign(socket, :open, Map.put(open, key, hits(socket, row, @hits_page)))}
    end
  end

  def handle_event("more_destination_runs", params, socket) do
    with %{} = row <- find_row(socket, params),
         key = destination_key(row),
         %{runs: shown} <- socket.assigns.open[key] do
      more = hits(socket, row, length(shown) + @hits_page)
      {:noreply, update(socket, :open, &Map.put(&1, key, more))}
    else
      _ -> {:noreply, socket}
    end
  end

  ## A row's Allow and Deny (pd8). What the browser names is matched whole against the rows
  ## the page holds, and the rule is made from a connection read through the scope: a
  ## destination or a target of another hive finds nothing.

  # Without security there is no rule to write: a crafted event is dropped here, before
  # a row, a policy or a connection is read.
  def handle_event(event, _params, %{assigns: %{security: false}} = socket)
      when event in ~w(rule_open rule_change rule_cancel rule_submit),
      do: {:noreply, socket}

  def handle_event("rule_open", %{"action" => action} = params, socket)
      when action in ~w(allow deny) do
    row = find_row(socket, params)
    act = row && socket.assigns.acts && socket.assigns.acts[destination_id(row)]

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
        "target" when popover.targets != [] -> :target
        "hive" -> :hive
        _ -> popover.level
      end

    # Only a target the popover listed can be chosen.
    choice =
      case params["target"] do
        id when is_binary(id) ->
          if Enum.any?(popover.targets, &(&1.id == id)), do: id

        _ ->
          popover.choice
      end

    popover = %{popover | level: level, choice: choice, error: nil}

    # What a rule for the chosen target would be is decided by that target's
    # policy, which is read when it is chosen.
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

    # Sent only while the policy is still the one the popover opened on.
    with :ok <- still(socket, popover),
         {:ok, from} <- rule_source(popover),
         {:ok, connection} <- Runs.fetch_connection(scope, from.connection_id),
         {:ok, rule} <- Policy.rule_from_connection(scope, connection, popover.action, level) do
      where = if level == :target, do: {:target, from.label}, else: :hive
      holder = if level == :target, do: from.target

      own =
        if level == :hive and popover.own_rule,
          do: gettext("A target's own rule for this host still decides there.")

      sentences = [
        Rules.toast(rule, popover.action, popover.host, popover.path, where),
        version_words(scope, holder),
        own,
        gettext("Running sessions have it within a heartbeat.")
      ]

      {:noreply,
       socket
       |> close_popover()
       |> refresh_policy()
       |> put_flash(:info, sentences |> Enum.reject(&is_nil/1) |> Enum.join(" "))}
    else
      :stale ->
        {:noreply, socket |> refresh_policy() |> policy_moved()}

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

  def handle_event(event, _params, socket)
      when event in ~w(rule_open rule_change rule_submit),
      do: {:noreply, socket}

  @impl true
  def handle_async(:load, {:ok, %{filters: filters} = loaded}, socket) do
    if filters == socket.assigns.filters do
      {:noreply,
       socket
       |> assign(
         listing: loaded.listing,
         facets: loaded.facets,
         open: loaded.open,
         target: loaded.target,
         effective: loaded.effective,
         own: loaded.own,
         stale: false,
         load_error: false
       )
       |> assign_acts()}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:facets, {:ok, %{filters: filters, narrow: narrow, facets: facets}}, socket) do
    if filters == socket.assigns.filters and narrow == socket.assigns.narrow,
      do: {:noreply, assign(socket, :facets, facets)},
      else: {:noreply, socket}
  end

  def handle_async(:facets, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, load_error: true)}

  @impl true
  def handle_info({:run_changed, _run}, socket) do
    if socket.assigns.listing && !socket.assigns.stale,
      do: {:noreply, assign(socket, :stale, true)},
      else: {:noreply, socket}
  end

  # The policy's topic: the rows' standing is read again, the listing is not. A page
  # without security never subscribed, and has no standing to read again.
  def handle_info({:policy_changed, _what}, %{assigns: %{security: false}} = socket),
    do: {:noreply, socket}

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

  defp load(socket) do
    %{current_scope: scope, filters: filters, open: open, narrow: narrow, security: security} =
      socket.assigns

    if connected?(socket) do
      start_async(socket, :load, fn ->
        now = DateTime.utc_now()
        listing = Runs.page_destinations(scope, filters, now)

        # The rows that were open stay open, read again, for as long as they are on the page.
        open =
          for row <- listing.rows,
              key = destination_key(row),
              %{runs: shown} <- [open[key]],
              into: %{} do
            {key,
             Runs.destination_runs(scope, filters, {row.host, row.port, row.path},
               now: now,
               limit: max(length(shown), @hits_page)
             )}
          end

        # The target is read for its policy; without security nothing is.
        target = if security, do: target_of(scope, filters.target)

        %{
          filters: filters,
          listing: listing,
          facets: Runs.destination_facets(scope, filters, now: now, narrow: narrow),
          open: open,
          target: target,
          effective: if(security, do: Policy.effective(scope, target)),
          own: if(security and is_nil(target), do: Rules.own_hosts(scope), else: [])
        }
      end)
    else
      socket
    end
  end

  ## The rows and the policy

  # The target `repo` names, when the hive has it: its policy is what the rows stand
  # against, and where "Its policy" leads.
  defp target_of(scope, {system, path}), do: Runs.fetch_target(scope, system, path)
  defp target_of(_scope, _target), do: nil

  defp refresh_policy(%{assigns: %{security: true, listing: %{}}} = socket) do
    %{current_scope: scope, target: target} = socket.assigns

    socket
    |> assign(
      effective: Policy.effective(scope, target),
      own: if(target, do: [], else: Rules.own_hosts(scope))
    )
    |> assign_acts()
  end

  defp refresh_policy(socket), do: socket

  defp assign_acts(
         %{assigns: %{effective: %Policy.Effective{} = effective, listing: %{rows: rows}}} =
           socket
       ) do
    %{current_scope: scope, target: target} = socket.assigns
    page = if target, do: :run, else: :hive
    standings = Enum.map(rows, &{&1, Rules.standing(&1, effective, page, socket.assigns.own)})
    changes = Rules.changes(scope, target, Enum.map(standings, &elem(&1, 1)))

    standings =
      for {row, standing} <- standings, do: {row, Rules.answered(standing, row, changes)}

    open = socket.assigns.popover && socket.assigns.popover.anchor
    action = socket.assigns.popover && socket.assigns.popover[:action]

    acts =
      for {row, standing} <- standings, into: %{} do
        id = destination_id(row)
        expanded = open == "#{id}-act"

        {id,
         row
         |> act(standing, changes, socket)
         |> Map.merge(%{expanded: expanded, expanded_action: expanded && action})}
      end

    assign(socket, acts: acts)
  end

  defp assign_acts(socket), do: assign(socket, acts: nil)

  defp act(row, %{standing: {:rule_added, action}, entry: entry} = standing, changes, socket)
       when not is_nil(entry) do
    %{current_scope: scope, target: target} = socket.assigns
    holder_id = if entry.source == :target and target, do: target.id
    change = Rules.change_for(entry, changes)

    Map.merge(standing, %{
      values: row_values(row),
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
        # The hive's page says nothing of a run.
        state: :hive,
        reloaded_at: nil
      }
    })
  end

  defp act(row, standing, _changes, _socket) do
    Map.merge(standing, %{
      values: row_values(row),
      entry_host: standing.entry && standing.entry.host,
      rule_path: nil,
      after: nil
    })
  end

  defp row_values(row),
    do: %{"host" => row.host, "port" => Integer.to_string(row.port), "path" => row.path || ""}

  defp who(%{by_id: id}, %{user: %{id: id}}) when not is_nil(id), do: gettext("you")
  defp who(%{by: email}, _scope) when is_binary(email), do: email |> String.split("@") |> hd()
  defp who(_change, _scope), do: nil

  defp open_popover(socket, row, act, action) do
    %{current_scope: scope, filters: filters, effective: effective, target: filtered} =
      socket.assigns

    reached = Runs.destination_targets(scope, filters, {row.host, row.port, row.path || ""})

    targets =
      for %{target_id: id} = r when is_binary(id) <- reached do
        %{
          id: id,
          label: "#{r.system}/#{r.path}",
          runs: r.runs,
          connection_id: r.connection_id
        }
      end

    # With `repo` set that target is chosen; among several, none is: no guessed scope.
    choice = filtered && Enum.find_value(targets, &(&1.id == filtered.id && &1.id))

    popover =
      %{
        anchor: "#{destination_id(row)}-act",
        any_connection_id: reached |> List.first() |> then(&(&1 && &1.connection_id)),
        action: action,
        host: act.host,
        path: row.path || "",
        mode: Rules.mode(row),
        page: :hive,
        level: if(choice, do: :target),
        target: nil,
        targets: targets,
        choice: choice,
        # The page holds the baseline, or with `repo` the target's; the other is read.
        baseline: if(filtered, do: Policy.effective(scope, nil), else: effective),
        standing: act.standing,
        chosen: nil,
        what: %{target: nil, hive: nil},
        own_rule: false,
        seen: nil,
        consequence: %{},
        hive: scope.hive.name,
        alive: false,
        fetched: false,
        interval: @default_beat,
        error: nil,
        refusal: nil
      }

    chosen = if choice, do: effective

    socket
    |> assign(popover: describe(socket, popover, chosen))
    |> assign_acts()
  end

  defp open_refusal(socket, row, act) do
    scope = socket.assigns.current_scope

    locked =
      scope
      |> Policy.list_changes(nil, 1)
      |> Map.get(:items, [])
      |> Enum.find(&(&1.action == "rule_locked" and &1.subject == act.entry.host))

    assign(socket,
      popover: %{
        anchor: "#{destination_id(row)}-act",
        host: act.host,
        refusal: %{
          standing: act.standing,
          rule: act.entry.host,
          locked_by: locked && locked.changed_by && locked.changed_by.email,
          locked_at: locked && locked.inserted_at,
          owner: match?(%{membership: %{level: :owner}}, scope),
          rule_path: Rules.rule_path(nil, act.entry.host)
        }
      }
    )
    |> assign_acts()
  end

  defp close_popover(socket), do: socket |> assign(popover: nil) |> assign_acts()

  # The connection the rule is made from: the chosen target's, or for the hive any of
  # the destination's.
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

  defp version_words(scope, holder) do
    holder =
      case holder do
        %{id: id} ->
          case Policy.get_target(scope, id) do
            {:ok, target} -> target
            _ -> nil
          end

        nil ->
          nil
      end

    case Policy.list_changes(scope, holder, 1) do
      %{items: [%{version_after: n} | _]} when is_integer(n) ->
        gettext("Version %{number}.", number: n)

      _ ->
        nil
    end
  end

  # The policy of the target chosen in the popover: the page's when `repo` names it.
  defp chosen_effective(_socket, nil), do: nil

  defp chosen_effective(socket, id) do
    %{current_scope: scope, target: filtered, effective: effective} = socket.assigns

    cond do
      filtered && filtered.id == id ->
        effective

      true ->
        case Policy.get_target(scope, id) do
          {:ok, target} -> Policy.effective(scope, target)
          _ -> nil
        end
    end
  end

  # What the popover says of each scope, from that scope's own policy: what the rule would
  # be (the host, or a path of it), what a deny does there, and what it saw.
  defp describe(socket, popover, chosen) do
    %{host: host, path: path, baseline: baseline} = popover
    own? = Rules.own_touches?(socket.assigns.own, host) or Rules.own_rule?(chosen, host)

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

  defp still(socket, popover) do
    %{current_scope: scope, target: filtered, listing: %{rows: rows}} = socket.assigns
    effective = Policy.effective(scope, filtered)
    baseline = if filtered, do: Policy.effective(scope, nil), else: effective
    own = if filtered, do: [], else: Rules.own_hosts(scope)
    page = if filtered, do: :run, else: :hive
    chosen = chosen_effective(assign(socket, effective: effective), popover.chosen)
    row = Enum.find(rows, &("#{destination_id(&1)}-act" == popover.anchor))

    if (row && Rules.standing(row, effective, page, own).standing == popover.standing) and
         {Rules.seen(baseline, popover.host), Rules.seen(chosen, popover.host)} == popover.seen,
       do: :ok,
       else: :stale
  end

  defp policy_moved(socket) do
    socket
    |> close_popover()
    |> put_flash(:error, gettext("The policy changed; look at the row again."))
  end

  defp recheck_popover(%{assigns: %{popover: %{refusal: nil} = popover}} = socket) do
    if still(socket, popover) == :ok, do: socket, else: policy_moved(socket)
  end

  defp recheck_popover(%{assigns: %{popover: %{}}} = socket), do: close_popover(socket)
  defp recheck_popover(socket), do: socket

  defp hits(socket, row, limit) do
    %{current_scope: scope, filters: filters} = socket.assigns
    Runs.destination_runs(scope, filters, {row.host, row.port, row.path}, limit: limit)
  end

  # What the browser names is matched whole, host, port and path, against the rows the
  # page holds: never by a DOM id, and it only ever picks one of those rows.
  defp find_row(%{assigns: %{listing: %{rows: rows}}}, %{
         "host" => host,
         "port" => port,
         "path" => path
       })
       when is_binary(host) and is_binary(port) and is_binary(path) do
    Enum.find(rows, &(&1.host == host and Integer.to_string(&1.port) == port and &1.path == path))
  end

  defp find_row(_socket, _id), do: nil

  # The notice of a rewritten link stays for the view the rewrite led to, and goes with the
  # reader's next change.
  defp keep_dropped(socket) do
    if socket.private[:rewrote],
      do: put_private(socket, :rewrote, false),
      else: assign(socket, :dropped, [])
  end

  # "applied" is the ordinary word here: a filter is applied to the list.
  defp dropped_sentence([name]),
    do:
      pgettext("plain", "The link's %{name} filter could not be read, so it is not applied.",
        name: name
      )

  defp dropped_sentence(names),
    do:
      pgettext(
        "plain",
        "The link's %{names} filters could not be read, so they are not applied.",
        names: Enum.join(names, ", ")
      )

  defp path(%Filters{} = filters), do: ~p"/hive/connections?#{Filters.to_params(filters)}"
  defp run_path(run), do: ~p"/hive/runs/#{run.run_id}/connections"

  defp narrowed?(%Filters{} = f),
    do: f.decision != nil or f.target != nil or f.host != nil or f.tools

  defp empty_title(%Filters{} = filters) do
    if narrowed?(filters),
      do: gettext("No connections match these filters"),
      else: range_title(filters)
  end

  # One whole title per range, as `Filters.range_label/1` names the ranges.
  defp range_title(%Filters{from: nil, to: nil, since: since}) do
    case since do
      "1h" -> gettext("No connections in the last hour")
      "24h" -> gettext("No connections in the last 24 hours")
      "7d" -> gettext("No connections in the last 7 days")
      "30d" -> gettext("No connections in the last 30 days")
      "90d" -> gettext("No connections in the last 90 days")
      _all -> gettext("No connections recorded")
    end
  end

  defp range_title(%Filters{from: from, to: nil}),
    do: gettext("No connections from %{date}", date: day(from))

  defp range_title(%Filters{from: nil, to: to}),
    do: gettext("No connections up to %{date}", date: day(to))

  defp range_title(%Filters{from: same, to: same}),
    do: gettext("No connections in %{date}", date: day(same))

  defp range_title(%Filters{from: from, to: to}),
    do: gettext("No connections in %{from} to %{to}", from: day(from), to: day(to))

  # As `Filters.range_label/1` writes a day.
  defp day(date), do: Calendar.strftime(date, "%-d %b %Y")

  # The target's name inside a sentence, set in mono.
  defp mono_part(text) do
    assigns = %{text: text}

    ~H"""
    <.mono>{@text}</.mono>
    """
  end

  defp facet_options(facets, name), do: (facets[name] || %{options: []}).options
  defp facet_total(facets, name), do: facets[name] && facets[name].total

  defp with_chosen(options, nil, _label), do: options || []

  defp with_chosen(options, value, label) do
    options = options || []

    if Enum.any?(options, fn {_label, v, _count} -> v == value end),
      do: options,
      else: [{label, value, 0} | options]
  end

  defp target_label(:none), do: gettext("Unassigned")
  defp target_label({system, path}), do: "#{system}/#{path}"
  defp target_label(nil), do: nil

  defp range_value(%Filters{from: nil, to: nil, since: "all"}), do: nil
  defp range_value(%Filters{from: nil, to: nil, since: since}), do: since
  defp range_value(%Filters{}), do: "dates"
end
