defmodule ApiaryWeb.ConnectionLive.Index do
  @moduledoc """
  Network access (`/:org/:workspace/network`, once Connections, whose paths send on here):
  where the runs of the workspace reached out to, what the policy made of it, and the way
  to allow or deny it. One row per host, port and path across the runs in range, with the
  reason and the outcome of the most recent attempt, and behind each row's chevron the
  runs that reached it. A target's Network access is this page narrowed to the target,
  which a run's page and a target's Overview link to. A connection as a thing keeps its
  word: a row is a destination and the connections made to it.

  A row is one line on the row spec (`ApiaryWeb.RunComponents.connection_row/1`): no tint
  and no bordered button; Allow and Deny are icons with a hint, shown on hover, focus and
  while open, with no ⋯ menu; the host has a copy icon beside it; and a locked rule is a
  lock whose hint says who locked it (`ApiaryWeb.ConnectionLive.Rules.locks/2`, one read
  for the page). The query field suggests the hosts in range as one types (`suggest`, a
  combobox, from the Host filter's query); choosing one adds `host:`.

  It is narrowed as every list is (docs/ui.md, Lists): the decisions as views (every
  destination, the denied, the allowed, each counted under the other filters), one query
  field whose filters show as tokens and whose free text finds a host or a path, one Filter
  menu (target, host, when it was seen, tool invocations), Sort (denied first, last seen,
  most runs, most attempts), and from 1280 px the rail of the targets whose runs reached
  out, pinned first, which sets the target. Every filter is a query parameter (`decision`,
  `system` and `target`, `host`, `q`, `tools`, `since`, `from`, `to`, `sort`, `page`),
  read through `Apiary.Runs.Filters`. A tool invocation
  (`Apiary.Runs.tool_invocation?/2`) is a destination like any other and reads as a call to
  its tool (`ApiaryWeb.RunComponents.connection_row/1`); a request a path rule refused
  before it reached the tool reads as any denial. `tools=1` keeps only the destinations of
  tool invocations.

  Narrowed to a target (`target`, with `system` only where two targets share the path),
  the page says so in one line under its title, "Showing acme/shop only.", the name
  leading to the target's page, with the same target's runs (the Runs list narrowed
  alike), its policy (the target's Policy tab) and "Show all destinations", which drops
  the target alone; the sidebar's Runs carries the target meanwhile
  (`ApiaryWeb.Layouts.narrowed/2`). Nothing else carries it. What the address names is
  read with it (`ApiaryWeb.Narrowing`), so the line, its policy and the rail's current
  target are right from the first render. A path that two targets share, given alone, is
  the path on both systems: the line says so and names each system, a link to the list
  narrowed to that system's target. The rail, the Filter menu and a typed `repo:` write a
  target as the line does, its system only where the path is shared.

  A destination's runs are read only when its
  row opens, ten at a time. While batches land the table does not move under the reader:
  "New activity" shows beside the title, which asks again and keeps the open rows open.

  Each row may ask the policy for a rule. A row's rule option is derived from one
  effective policy the page holds: the workspace's baseline, or the target's when the
  filters name one.
  The scope of a new rule is never guessed: among several targets none is chosen until the
  reader chooses. The rule itself is made by `Apiary.Policy.rule_from_connection/4` from
  the most recent connection of the destination in the chosen scope, and what the domain
  refuses is said in its sentence.

  The rows are the record (`observability`); the rules are `security`'s. On an instance
  without `security` the page is the record alone: no Reason column (which rule matched,
  in which mode), no Allow or Deny, no rule's panel, no link to a policy, and the policy is
  neither read nor followed. A rule event that arrives all the same is dropped before
  anything is looked up.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  alias Apiary.Access
  alias Apiary.Policy
  alias Apiary.Runs
  alias Apiary.Runs.Filters
  alias ApiaryWeb.ConnectionLive.Rules
  alias ApiaryWeb.Narrowing
  alias ApiaryWeb.TargetComponents

  @hits_page 10
  @coalesce_ms 250
  # The most hosts the query field suggests.
  @suggest_size 8
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
      nav={:network}
      width="work"
      narrowed={Layouts.narrowed(@filters.target, Narrowing.shared?(@narrowing))}
    >
      <:crumb>{gettext("Network access")}</:crumb>

      <div id="connections-page" class="q-lp">
        <.page_header title={gettext("Network access")}>
          <:description>
            {if @security,
              do:
                gettext(
                  "Where the runs of this workspace reached out to, and what the policy made of it."
                ),
              else: gettext("Where the runs of this workspace reached out to.")}
          </:description>
          <:actions>
            <.new_status stale={@stale} />
          </:actions>
          <.target_note
            :if={@filters.target}
            scope={@current_scope}
            filters={@filters}
            narrowing={@narrowing}
            policy_target={@security && @policy_target}
          />
        </.page_header>

        <.content {assigns} />
      </div>
    </Layouts.app>
    """
  end

  # The page's content under its header: the views, the query, the menus and the tokens,
  # the rail, the destinations and their pages, a row's rule panel under its row.
  defp content(assigns) do
    ~H"""
    <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
      <span id="connections-error">
        {gettext(
          "The connections could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
        )}
      </span>
    </.notice>

    <.notice :if={@dropped != [] or @refused != []} kind={:warning} class="max-w-[80ch]">
      <span id="connections-dropped">{dropped_sentence(@dropped, @refused)}</span>
    </.notice>

    <%= if !@load_error do %>
      <.views id="connections-views" label={gettext("Views")}>
        <:view
          :for={{key, label, decision} <- views()}
          id={"connections-view-#{key}"}
          patch={page_path(@current_scope, Filters.put(@filters, decision: decision))}
          current={@filters.decision == decision}
          count={@views && Format.number(Map.fetch!(@views, String.to_existing_atom(key)))}
        >
          {label}
        </:view>
      </.views>
      <p
        :if={@views && @views.allowed + @views.denied > @views.all}
        id="connections-views-note"
        class="q-views-note"
      >
        {gettext("A destination with both allowed and denied attempts counts in each.")}
      </p>

      <div id="connections-filters" class="q-bar">
        <.list_search
          id="connections-query"
          class="q-find-query"
          label={gettext("Filter destinations")}
          placeholder={gettext("Filter destinations, e.g. host:registry.example")}
          value={@filters.q}
          change="query"
          live={false}
          suggest="suggest"
          suggestions={@suggestions}
          suggestions_label={gettext("Hosts")}
          status={@suggest_status}
        />
        <.filter_menu
          id="connections-filter"
          count={filter_count(@filters)}
        >
          <:section
            key="target"
            label={gettext("Target")}
            icon="hero-folder"
            qualifier={pgettext("qualifier", "target")}
            value={@filters.target && target_text(@filters.target, @shared)}
            rail
          >
            <.filter_options
              id="filter-target"
              name="target"
              label={gettext("Target")}
              values={List.wrap(menu_value(@filters, @narrowing, @shared))}
              options={
                with_chosen(
                  target_options(@facets, @shared),
                  menu_value(@filters, @narrowing, @shared),
                  @filters.target && target_text(@filters.target, @shared)
                )
              }
              total={facet_total(@facets, :target)}
              query={@narrow["target"]}
              more="more_options"
            />
          </:section>
          <:section
            key="host"
            label={gettext("Host")}
            icon="hero-globe-alt"
            qualifier="host"
            value={@filters.host}
          >
            <.filter_options
              id="filter-host"
              name="host"
              label={gettext("Host")}
              values={List.wrap(@filters.host)}
              options={with_chosen(facet_options(@facets, :host), @filters.host, @filters.host)}
              total={facet_total(@facets, :host)}
              query={@narrow["host"]}
              more="more_options"
            />
          </:section>
          <:section
            key="since"
            label={gettext("Seen")}
            icon="hero-calendar"
            qualifier="seen"
            value={Filters.range_label(@filters)}
          >
            <.filter_options
              id="filter-since"
              name="since"
              label={gettext("Seen")}
              values={List.wrap(range_value(@filters))}
              options={for {label, value} <- Filters.ranges(:connections), do: {label, value, nil}}
              dates={
                %{
                  from: @filters.from && Date.to_iso8601(@filters.from),
                  to: @filters.to && Date.to_iso8601(@filters.to)
                }
              }
            />
          </:section>
          <:section
            key="tools"
            label={gettext("Tool invocations")}
            icon="hero-wrench-screwdriver"
            qualifier="tools"
            value={@filters.tools && gettext("Only")}
          >
            <.filter_check
              id="connections-tools"
              name="tools"
              label={gettext("Tool invocations only")}
              checked={@filters.tools}
            />
          </:section>
        </.filter_menu>
        <.sort_menu
          id="connections-sort"
          current={sort_name(@filters.sort)}
          label={sort_label(@filters.sort)}
        >
          <.menu_item
            :for={sort <- Filters.sorts(:connections)}
            id={"connections-sort-#{sort}"}
            patch={page_path(@current_scope, Filters.put(@filters, sort: sort))}
            checked={@filters.sort == sort}
          >
            {sort_label(sort)}
          </.menu_item>
        </.sort_menu>
      </div>

      <.filter_tokens
        id="connections-tokens"
        clear={narrowed?(@filters) && page_path(@current_scope, Filters.clear(@filters))}
      >
        <:token
          :for={token <- tokens(@current_scope, @filters, @shared)}
          id={token.id}
          class="q-tok-q"
          patch={token.remove}
          label={gettext("Remove %{token}", token: "#{token.qualifier}:#{token.value}")}
        >
          <span class="q-tok-k">{token.qualifier}:</span><span class="q-tok-v" title={token.value}>{token.value}</span>
        </:token>
      </.filter_tokens>

      <div class="q-with-rail">
        <.target_rail
          id="connections-rail"
          label={gettext("Targets")}
          heading={gettext("Most destinations")}
          rail={@rail}
          chosen={Narrowing.chosen(@narrowing, @filters.target)}
          chosen_count={@loaded == @filters && @listing && @listing.summary.destinations}
          shared={@shared}
          query={@rail_query}
          path={
            &page_path(
              @current_scope,
              Filters.put(@filters, target: Filters.link_target(&1, @shared))
            )
          }
        />

        <div class="q-list-col">
          <%!-- Always there, so a screen reader hears what a view or a filter left. --%>
          <div id="connections-status" role="status" class="q-status">
            <p
              :if={@listing && @listing.rows != [] && narrowed?(@filters)}
              id="connections-summary"
              class="q-matchline"
            >
              <.rich text={
                rich_gettext("%{destinations} across %{runs}",
                  destinations:
                    rich_ngettext(
                      "%{number} destination matches",
                      "%{number} destinations match",
                      @listing.summary.destinations,
                      number: {:b, Format.number(@listing.summary.destinations)}
                    ),
                  runs:
                    rich_ngettext("%{number} run", "%{number} runs", @listing.summary.runs,
                      number: {:b, Format.number(@listing.summary.runs)}
                    )
                )
              } />
            </p>
            <p :if={@listing && @listing.rows == []} class="sr-only">
              {empty_title(@filters)}
            </p>
          </div>

          <div
            :if={@listing == nil}
            id="connections-loading"
            class="q-tbl overflow-x-auto rounded-box border border-line bg-base-100"
            aria-busy="true"
          >
            <table class="table q-cxt q-cxt-ws">
              <thead>
                <tr>
                  <th class="q-cx-ex"></th>
                  <th>{gettext("Destination")}</th>
                  <th class="q-num q-cx-runs">{gettext("Runs")}</th>
                  <th class="q-num q-from-lg">{gettext("Attempts")}</th>
                  <th>{gettext("Allowed / denied")}</th>
                  <th :if={@security} class="q-from-sm">{gettext("Reason")}</th>
                  <th class="q-from-lg">{gettext("Outcome")}</th>
                  <th class="q-cx-seen">{gettext("Last seen")}</th>
                  <th :if={@security} class="q-cx-acts"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={n <- 1..8}>
                  <td class="q-cx-ex"></td>
                  <td class="q-cx-d">
                    <span class={[
                      "skeleton q-skel",
                      if(rem(n, 2) == 0, do: "w-56", else: "w-44")
                    ]}></span>
                  </td>
                  <td class="q-cx-runs"><span class="skeleton q-skel ml-auto w-6"></span></td>
                  <td class="q-from-lg"><span class="skeleton q-skel ml-auto w-8"></span></td>
                  <td><span class="skeleton q-skel w-24"></span></td>
                  <td :if={@security} class="q-from-sm">
                    <span class="skeleton q-skel w-40"></span>
                  </td>
                  <td class="q-from-lg"><span class="skeleton q-skel w-16"></span></td>
                  <td class="q-cx-seen"><span class="skeleton q-skel w-20"></span></td>
                  <td :if={@security} class="q-cx-acts"></td>
                </tr>
              </tbody>
            </table>
          </div>

          <.connections_table
            :if={@listing && @listing.rows != []}
            id="destinations"
            label={gettext("Network access of this workspace")}
            variant="workspace"
            rows={@listing.rows}
            row_id={&destination_id/1}
            open={@open}
            run_path={&run_path(@current_scope, &1)}
            acts={@acts}
            panel={@rule_panel}
            security={@security}
            shared={@shared}
          />

          <.empty_state
            :if={@listing && @listing.rows == []}
            icon={if !narrowed?(@filters), do: "hero-arrows-right-left"}
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
                :if={token = last_token(@current_scope, @filters, @shared)}
                id="connections-remove-last"
                patch={token.remove}
              >
                {gettext("Remove %{token}", token: "#{token.qualifier}:#{token.value}")}
              </.button>
              <.button
                :if={narrowed?(@filters)}
                id="connections-clear"
                patch={page_path(@current_scope, Filters.clear(@filters))}
              >
                {gettext("Clear filters")}
              </.button>
            </:actions>
          </.empty_state>

          <.pager
            :if={@listing && @listing.rows != []}
            id="connections-pager"
            prefix="connections"
            first={(@listing.page - 1) * Runs.page_size() + 1}
            last={(@listing.page - 1) * Runs.page_size() + length(@listing.rows)}
            total={@listing.summary.destinations}
            previous={
              @listing.page > 1 &&
                page_path(@current_scope, %{@filters | page: @listing.page - 1})
            }
            next={
              @listing.page < @listing.pages &&
                page_path(@current_scope, %{@filters | page: @listing.page + 1})
            }
            previous_label={gettext("Previous")}
            next_label={gettext("Next")}
          />
          <p :if={@listing && @listing.rows != []} id="connections-note" class="q-list-note">
            {if @security,
              do:
                gettext(
                  "The reason and outcome are those of the last attempt across the runs shown. A rule added here changes what happens next; what the record already says stays as it was."
                ),
              else: gettext("The outcome is that of the last attempt across the runs shown.")}
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  # "New activity": beside the page's title. While there is none the live region is kept
  # out of the flow.
  attr :stale, :boolean, required: true

  defp new_status(assigns) do
    ~H"""
    <span
      id="connections-new-status"
      class={!@stale && "absolute"}
      role="status"
      aria-live="polite"
    >
      <button
        :if={@stale}
        id="connections-refresh"
        type="button"
        class="q-newpill q-newpill-show q-newpill-head"
        phx-click="refresh"
      >
        <.icon name="hero-arrow-path-micro" class="size-4" />{gettext("New activity")}
      </button>
    </span>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    security = Access.can?(scope, :"security_policy.read", scope.workspace)

    if connected?(socket) do
      Runs.subscribe(scope)
      if security, do: Policy.subscribe(scope)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Network access"),
       filters: Filters.new(:connections),
       # The filters the listing was read for.
       loaded: nil,
       listing: nil,
       views: nil,
       rail: nil,
       rail_query: nil,
       rail_limit: Runs.rail_size(),
       shared: MapSet.new(),
       facets: %{},
       open: %{},
       stale: false,
       load_error: false,
       dropped: [],
       refused: [],
       narrow: %{},
       limits: %{},
       # The hosts the query field suggests for the word being typed, and that word.
       suggestions: [],
       suggest_word: nil,
       suggest_status: nil,
       # What the filters' target names (`ApiaryWeb.Narrowing`), and the one target among
       # it, read for its policy: both read with the address.
       narrowing: nil,
       policy_target: nil,
       effective: nil,
       acts: nil,
       rule_panel: nil,
       own: [],
       policy_flush_scheduled: false,
       security: security
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Filters.parse(params, :connections)

    # The path's organisation and workspace are not filters.
    if Filters.to_params(filters) == Map.drop(params, ["org", "workspace"]) do
      # What is open belongs to the view it was opened in.
      open = if Filters.same?(filters, socket.assigns.filters), do: socket.assigns.open, else: %{}

      {:noreply,
       socket
       |> keep_notices()
       |> assign(filters: filters, open: open, rule_panel: nil)
       |> clear_suggestions()
       |> narrow()
       |> load()}
    else
      {:noreply,
       socket
       |> assign(:dropped, filters.dropped)
       |> put_private(:notice_kept, true)
       |> push_patch(
         to: page_path(socket.assigns.current_scope, %{filters | dropped: []}),
         replace: true
       )}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to: page_path(socket.assigns.current_scope, Filters.change(socket.assigns.filters, params))
     )}
  end

  def handle_event("query", %{"q" => text}, socket) when is_binary(text) do
    scope = socket.assigns.current_scope

    {filters, refused} =
      Filters.apply_query(socket.assigns.filters, text, resolve: &Narrowing.typed(scope, &1))

    {:noreply,
     socket
     |> clear_suggestions()
     |> assign(:refused, refused)
     |> put_private(:notice_kept, refused != [])
     |> push_patch(to: page_path(socket.assigns.current_scope, filters))}
  end

  def handle_event("query", _params, socket), do: {:noreply, socket}

  # The hosts for the word being typed, the last of the field: from the Host filter's
  # query, bounded and narrowed by the page's other filters, never the whole list.
  def handle_event("suggest", %{"q" => text}, socket) when is_binary(text) do
    word =
      text
      |> String.slice(0, 256)
      |> String.split(~r/\s/u)
      |> List.last()
      |> String.replace_prefix("host:", "")

    cond do
      word == "" ->
        {:noreply, clear_suggestions(socket)}

      # A word the query cannot match on (too long, a control character) matches nothing.
      is_nil(Runs.like(word)) ->
        {:noreply,
         socket
         |> clear_suggestions()
         |> assign(:suggest_status, gettext("Nothing matches"))}

      true ->
        suggest(socket, word)
    end
  end

  def handle_event("suggest", _params, socket), do: {:noreply, socket}

  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket)
      when name in ~w(target host) and is_binary(q) do
    narrow = Map.put(socket.assigns.narrow, name, String.slice(q, 0, 256))
    {:noreply, socket |> assign(:narrow, narrow) |> load_facets()}
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  def handle_event("more_options", %{"name" => name}, socket) when name in ~w(target host) do
    limit = Map.get(socket.assigns.limits, name, Runs.facet_size()) + Runs.facet_size()

    {:noreply,
     socket |> assign(:limits, Map.put(socket.assigns.limits, name, limit)) |> load_facets()}
  end

  def handle_event("more_options", _params, socket), do: {:noreply, socket}

  def handle_event("rail_search", %{"q" => q}, socket) when is_binary(q) do
    query = q |> String.slice(0, 256) |> String.trim()

    {:noreply,
     socket
     |> assign(rail_query: if(query == "", do: nil, else: query), rail_limit: Runs.rail_size())
     |> load_rail()}
  end

  def handle_event("rail_search", _params, socket), do: {:noreply, socket}

  def handle_event("rail_more", _params, socket) do
    {:noreply, socket |> update(:rail_limit, &(&1 + Runs.rail_size())) |> load_rail()}
  end

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

  ## A row's Allow and Deny. What the browser names is matched whole against the rows the
  ## page holds, and the rule is made from a connection read through the scope: a
  ## destination or a target of another workspace finds nothing.

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
      # Only the level above allows a host here: an allow of the workspace would not be in
      # force. The panel says so and leads there, for one who may change it there.
      {%{rule_option: :can_allow, allow_elsewhere: %{}, allow_path: path}, "allow"}
      when is_binary(path) ->
        {:noreply, open_elsewhere(socket, row, act)}

      {%{rule_option: :can_allow, allow_elsewhere: %{}}, "allow"} ->
        {:noreply, socket}

      {%{rule_option: :can_allow}, "allow"} ->
        {:noreply, open_panel(socket, row, act, :allow)}

      {%{rule_option: :can_deny}, "deny"} ->
        {:noreply, open_panel(socket, row, act, :deny)}

      # No rule decides the host: it can be denied outright as well as allowed.
      {%{rule_option: :can_allow, deny: true}, "deny"} ->
        {:noreply, open_panel(socket, row, act, :deny)}

      {%{rule_option: locked}, _} when locked in [:locked_deny, :locked_allow] ->
        {:noreply, open_refusal(socket, row, act)}

      # A row the level above denies, or one only the level above allows for a reader
      # who may not change it there: its lock's hint says so; nothing opens here.
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

    # Only a target the panel listed can be chosen.
    choice =
      case params["target"] do
        id when is_binary(id) ->
          if Enum.any?(panel.targets, &(&1.id == id)), do: id

        _ ->
          panel.choice
      end

    panel = %{panel | level: level, choice: choice, error: nil}

    # What a rule for the chosen target would be is decided by that target's
    # policy, which is read when it is chosen.
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

    # Sent only while the policy is still the one the panel opened on.
    with :ok <- still(socket, panel),
         {:ok, from} <- rule_source(panel),
         {:ok, connection} <- Runs.fetch_connection(scope, from.connection_id),
         {:ok, rule} <- Policy.rule_from_connection(scope, connection, panel.action, level) do
      where = if level == :target, do: {:target, from.label}, else: :workspace
      holder = if level == :target, do: from.target

      own =
        if level == :workspace and panel.own_rule,
          do: gettext("A target's own rule for this host still decides there.")

      sentences = [
        Rules.toast(rule, panel.action, panel.host, panel.path, where),
        version_words(scope, holder),
        own,
        gettext("Running sessions have it within a heartbeat.")
      ]

      {:noreply,
       socket
       |> close_panel()
       |> refresh_policy()
       |> put_flash(:info, sentences |> Enum.reject(&is_nil/1) |> Enum.join(" "))}
    else
      :stale ->
        {:noreply, socket |> refresh_policy() |> policy_moved()}

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

  def handle_event(event, _params, socket)
      when event in ~w(rule_open rule_change rule_submit),
      do: {:noreply, socket}

  @impl true
  def handle_async(:load, {:ok, %{filters: filters} = loaded}, socket) do
    if filters == socket.assigns.filters do
      {:noreply,
       socket
       |> assign(
         loaded: filters,
         listing: loaded.listing,
         views: loaded.views,
         rail: loaded.rail,
         shared: loaded.shared,
         facets: loaded.facets,
         open: loaded.open,
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

  def handle_async(:facets, {:ok, %{filters: filters, key: key, facets: facets}}, socket) do
    if filters == socket.assigns.filters and key == facet_key(socket),
      do: {:noreply, assign(socket, :facets, facets)},
      else: {:noreply, socket}
  end

  def handle_async(:facets, {:exit, _reason}, socket), do: {:noreply, socket}

  # An answer for a word no longer being typed is dropped.
  def handle_async(:suggest, {:ok, %{word: word, facet: facet}}, socket) do
    if word == socket.assigns.suggest_word do
      suggestions =
        for {_label, host, runs} <- Enum.take(facet.options, @suggest_size),
            do: %{
              value: host,
              detail:
                ngettext("%{number} run", "%{number} runs", runs, number: Format.number(runs))
            }

      status =
        if suggestions == [],
          do: gettext("Nothing matches"),
          else:
            ngettext("%{number} host matches", "%{number} hosts match", facet.total,
              number: Format.number(facet.total)
            )

      {:noreply, assign(socket, suggestions: suggestions, suggest_status: status)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:suggest, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:rail, {:ok, %{filters: filters, key: key, rail: rail}}, socket) do
    if filters == socket.assigns.filters and key == rail_key(socket),
      do: {:noreply, assign(socket, :rail, rail)},
      else: {:noreply, socket}
  end

  def handle_async(:rail, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, load_error: true)}

  @impl true
  def handle_info({:run_changed, _run}, socket) do
    if socket.assigns.listing && !socket.assigns.stale,
      do: {:noreply, assign(socket, :stale, true)},
      else: {:noreply, socket}
  end

  # The policy's topic: the rows' rule options are read again, the listing is not. A page
  # without security never subscribed, and has no rule options to read again.
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
     socket |> assign(policy_flush_scheduled: false) |> refresh_policy() |> recheck_panel()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load(socket) do
    %{current_scope: scope, filters: filters, open: open, security: security} = socket.assigns
    target = socket.assigns.policy_target
    facets_opts = [narrow: socket.assigns.narrow, limits: socket.assigns.limits]
    rail_opts = rail_opts(socket)

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

        %{
          filters: filters,
          listing: listing,
          views: Runs.destination_views(scope, filters, now),
          rail: Runs.destination_target_counts(scope, filters, [now: now] ++ rail_opts),
          shared: Runs.shared_paths(scope),
          facets: Runs.destination_facets(scope, filters, [now: now] ++ facets_opts),
          open: open,
          effective: if(security, do: Policy.effective(scope, target)),
          own: if(security and is_nil(target), do: Rules.own_hosts(scope), else: [])
        }
      end)
    else
      socket
    end
  end

  # What the filters' target names, read with the address and only when it names another
  # (`ApiaryWeb.Narrowing`): the line, "Its policy", the rail's current target and the
  # sidebar's carry are right from the first render, and never the target before. The
  # one target is read for its policy; without security none is. A path the read finds
  # shared is shared for the page's names at once.
  defp narrow(%{assigns: %{filters: %{target: target}, narrowing: %{for: target}}} = socket),
    do: socket

  defp narrow(socket) do
    %{current_scope: scope, filters: %{target: target}, security: security} = socket.assigns
    narrowing = Narrowing.read(scope, target)

    socket
    |> assign(
      narrowing: narrowing,
      policy_target: if(security && narrowing, do: narrowing.target)
    )
    |> then(fn socket ->
      if Narrowing.shared?(narrowing),
        do: update(socket, :shared, &MapSet.put(&1, elem(target, 1))),
        else: socket
    end)
  end

  # The hosts of the destinations the view lists (`decided`), under the other filters; not
  # the host chosen, nor the free text the field is being typed to replace.
  defp suggest(socket, word) do
    %{current_scope: scope, filters: filters} = socket.assigns
    filters = %{filters | host: nil, q: nil}

    {:noreply,
     socket
     |> assign(:suggest_word, word)
     |> start_async(:suggest, fn ->
       facet =
         Runs.destination_facets(scope, filters,
           narrow: %{"host" => word},
           limits: %{"host" => @suggest_size},
           decided: true
         ).host

       %{word: word, facet: facet}
     end)}
  end

  defp clear_suggestions(socket),
    do: assign(socket, suggestions: [], suggest_word: nil, suggest_status: nil)

  defp load_facets(socket) do
    %{current_scope: scope, filters: filters, narrow: narrow, limits: limits} = socket.assigns
    key = facet_key(socket)

    start_async(socket, :facets, fn ->
      %{
        filters: filters,
        key: key,
        facets: Runs.destination_facets(scope, filters, narrow: narrow, limits: limits)
      }
    end)
  end

  defp facet_key(socket), do: {socket.assigns.narrow, socket.assigns.limits}

  defp load_rail(socket) do
    %{current_scope: scope, filters: filters} = socket.assigns
    key = rail_key(socket)
    opts = rail_opts(socket)

    start_async(socket, :rail, fn ->
      %{filters: filters, key: key, rail: Runs.destination_target_counts(scope, filters, opts)}
    end)
  end

  defp rail_key(socket), do: {socket.assigns.rail_query, socket.assigns.rail_limit}

  # The pinned targets are the sidebar's (`counts.pins`), in its order.
  defp rail_opts(socket) do
    pins = (socket.assigns[:nav_counts] || %{})[:pins] || []

    [
      narrow: socket.assigns.rail_query,
      limit: socket.assigns.rail_limit,
      pinned: for(%{system: system, path: path} <- pins, is_binary(system), do: {system, path})
    ]
  end

  ## The rows and the policy

  defp refresh_policy(%{assigns: %{security: true, listing: %{}}} = socket) do
    %{current_scope: scope, policy_target: target} = socket.assigns

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
    %{current_scope: scope, policy_target: target} = socket.assigns
    page = if target, do: :run, else: :workspace

    rule_options =
      Enum.map(rows, &{&1, Rules.rule_option(&1, effective, page, socket.assigns.own)})

    changes = Rules.changes(scope, target, Enum.map(rule_options, &elem(&1, 1)))

    rule_options =
      for {row, rule_option} <- rule_options, do: {row, Rules.answered(rule_option, row, changes)}

    open = socket.assigns.rule_panel && socket.assigns.rule_panel.anchor
    action = socket.assigns.rule_panel && socket.assigns.rule_panel[:action]

    # Who locked a locked rule, for the lock's hint on the rows it decides: one read.
    locks =
      Rules.locks(
        scope,
        for(
          {_row, %{rule_option: option, entry: %{host: host}}} <- rule_options,
          option in [:locked_deny, :locked_allow],
          uniq: true,
          do: host
        )
      )

    # Where the level above the workspace is read and changed, for the rows it decides;
    # a way there to allow a host carries the way back to this page, as it is filtered.
    link = if effective.above, do: ApiaryWeb.Edition.above_policy_link(scope)

    above_link =
      link &&
        Map.put(link, :back, page_path(socket.assigns.current_scope, socket.assigns.filters))

    acts =
      for {row, rule_option} <- rule_options, into: %{} do
        id = destination_id(row)
        expanded = row_of_anchor(open) == id

        {id,
         row
         |> act(rule_option, changes, socket)
         |> Map.merge(%{expanded: expanded, expanded_action: expanded && action})
         |> locked(locks, scope)
         |> above(above_link)}
      end

    assign(socket, acts: acts)
  end

  defp assign_acts(socket), do: assign(socket, acts: nil)

  defp act(
         row,
         %{rule_option: {:rule_added, action}, entry: entry} = rule_option,
         changes,
         socket
       )
       when not is_nil(entry) do
    %{current_scope: scope, policy_target: target} = socket.assigns
    holder = if entry.source == :target and target, do: target
    change = Rules.change_for(entry, changes)
    shared = Narrowing.shared?(socket.assigns.narrowing)

    Map.merge(rule_option, %{
      values: row_values(row),
      entry_host: entry.host,
      rule_path: Rules.rule_path(scope, holder, entry.host, shared),
      after: %{
        action: action,
        level: if(entry.source == :target, do: :target, else: :workspace),
        version:
          change && is_integer(change.version) &&
            %{
              n: change.version,
              path: Rules.version_path(scope, holder, change.version, %{}, shared),
              label: Rules.version_label(holder && holder.id, target, shared)
            },
        by: change && who(change, scope),
        at: (change && change.at) || (entry.rule && entry.rule.updated_at),
        # The workspace's page says nothing of a run.
        state: :workspace,
        reloaded_at: nil
      }
    })
  end

  # A row a rule decides links to that rule, in the Network access section of its policy.
  defp act(row, rule_option, _changes, socket) do
    %{current_scope: scope, policy_target: target} = socket.assigns
    entry = rule_option.entry

    Map.merge(rule_option, %{
      values: row_values(row),
      entry_host: entry && entry.host,
      rule_path:
        entry && entry.host &&
          Rules.rule_path(
            scope,
            if(entry.source == :target and target, do: target),
            entry.host,
            Narrowing.shared?(socket.assigns.narrowing)
          ),
      after: nil
    })
  end

  # A locked rule's row: the way to the rule, and who locked it when that is known.
  defp locked(%{rule_option: option, entry: %{host: host}} = act, locks, scope)
       when option in [:locked_deny, :locked_allow],
       do: Map.merge(act, %{rule_path: Rules.rule_path(scope, nil, host), locked: locks[host]})

  defp locked(act, _locks, _scope), do: act

  # A row the level above decides links to its rule there, and a row that could be
  # allowed only there links to its page with the host, where the reader may change it.
  defp above(%{above: %{}, entry: %{host: host}} = act, %{path: path} = link) do
    Map.merge(act, %{
      rule_path: path <> "?" <> URI.encode_query(%{"rule" => host}),
      above_linked: true,
      above_can_change: link.can_change
    })
  end

  defp above(%{allow_elsewhere: %{}, host: host} = act, %{path: path, can_change: true} = link),
    do:
      Map.put(
        act,
        :allow_path,
        path <> "?" <> URI.encode_query(%{"allow" => host, "back" => link.back})
      )

  defp above(act, _link), do: act

  defp row_values(row),
    do: %{"host" => row.host, "port" => Integer.to_string(row.port), "path" => row.path || ""}

  defp who(%{by_id: id}, %{user: %{id: id}}) when not is_nil(id), do: gettext("you")
  defp who(%{by: name}, _scope) when is_binary(name), do: ApiaryWeb.People.short(name)
  defp who(_change, _scope), do: nil

  defp open_panel(socket, row, act, action) do
    %{current_scope: scope, filters: filters, effective: effective, policy_target: filtered} =
      socket.assigns

    reached = Runs.destination_targets(scope, filters, {row.host, row.port, row.path || ""})

    targets =
      for %{target_id: id} = r when is_binary(id) <- reached do
        %{
          id: id,
          label: ApiaryWeb.TargetComponents.target_label(r.system, r.path, socket.assigns.shared),
          runs: r.runs,
          connection_id: r.connection_id
        }
      end

    # With `repo` set that target is chosen; among several, none is: no guessed scope.
    choice = filtered && Enum.find_value(targets, &(&1.id == filtered.id && &1.id))

    panel =
      %{
        anchor: "#{destination_id(row)}-#{action}",
        any_connection_id: reached |> List.first() |> then(&(&1 && &1.connection_id)),
        action: action,
        host: act.host,
        path: row.path || "",
        mode: Rules.mode(row),
        page: :workspace,
        level: if(choice, do: :target),
        target: nil,
        targets: targets,
        choice: choice,
        # The page holds the baseline, or with `repo` the target's; the other is read.
        baseline: if(filtered, do: Policy.effective(scope, nil), else: effective),
        rule_option: act.rule_option,
        chosen: nil,
        what: %{target: nil, workspace: nil},
        own_rule: false,
        seen: nil,
        consequence: %{},
        workspace: scope.workspace.name,
        alive: false,
        fetched: false,
        interval: @default_beat,
        error: nil,
        refusal: nil
      }

    chosen = if choice, do: effective

    socket
    |> assign(rule_panel: describe(socket, panel, chosen))
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
      rule_panel: %{
        anchor: "#{destination_id(row)}-lock",
        host: act.host,
        refusal: %{
          rule_option: act.rule_option,
          rule: act.entry.host,
          locked_by: locked && ApiaryWeb.People.email(locked.changed_by),
          locked_at: locked && locked.inserted_at,
          owner: Access.can?(scope, :"security_policy.lock", scope.workspace),
          rule_path: Rules.rule_path(scope, nil, act.entry.host)
        }
      }
    )
    |> assign_acts()
  end

  # The panel of an Allow only the level above can grant: what holds, and the way to the
  # level's page with the host. Nothing is written here.
  defp open_elsewhere(socket, row, act) do
    assign(socket,
      rule_panel: %{
        anchor: "#{destination_id(row)}-allow",
        host: act.host,
        action: :allow,
        refusal: :elsewhere,
        elsewhere: %{name: act.allow_elsewhere.name, path: act.allow_path}
      }
    )
    |> assign_acts()
  end

  defp close_panel(socket), do: socket |> assign(rule_panel: nil) |> assign_acts()

  # The connection the rule is made from: the chosen target's, or for the workspace any of
  # the destination's.
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

  # The policy of the target chosen in the panel: the page's when `repo` names it.
  defp chosen_effective(_socket, nil), do: nil

  defp chosen_effective(socket, id) do
    %{current_scope: scope, policy_target: filtered, effective: effective} = socket.assigns

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

  # What the panel says of each scope, from that scope's own policy: what the rule would
  # be (the host, or a path of it), what a deny does there, and what it saw.
  defp describe(socket, panel, chosen) do
    %{host: host, path: path, baseline: baseline} = panel
    own? = Rules.own_touches?(socket.assigns.own, host) or Rules.own_rule?(chosen, host)

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

  defp still(socket, panel) do
    %{current_scope: scope, policy_target: filtered, listing: %{rows: rows}} = socket.assigns
    effective = Policy.effective(scope, filtered)
    baseline = if filtered, do: Policy.effective(scope, nil), else: effective
    own = if filtered, do: [], else: Rules.own_hosts(scope)
    page = if filtered, do: :run, else: :workspace
    chosen = chosen_effective(assign(socket, effective: effective), panel.chosen)
    row = Enum.find(rows, &(destination_id(&1) == row_of_anchor(panel.anchor)))

    if (row && Rules.rule_option(row, effective, page, own).rule_option == panel.rule_option) and
         {Rules.seen(baseline, panel.host), Rules.seen(chosen, panel.host)} == panel.seen,
       do: :ok,
       else: :stale
  end

  defp policy_moved(socket) do
    socket
    |> close_panel()
    |> put_flash(:error, gettext("The policy changed; look at the row again."))
  end

  defp recheck_panel(%{assigns: %{rule_panel: %{refusal: nil} = panel}} = socket) do
    if still(socket, panel) == :ok, do: socket, else: policy_moved(socket)
  end

  defp recheck_panel(%{assigns: %{rule_panel: %{}}} = socket), do: close_panel(socket)
  defp recheck_panel(socket), do: socket

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

  # A notice of a rewritten link or a refused word stays for the view it led to, and goes
  # with the reader's next change.
  defp keep_notices(socket) do
    if socket.private[:notice_kept],
      do: put_private(socket, :notice_kept, false),
      else: assign(socket, dropped: [], refused: [])
  end

  # "applied" is the ordinary word here: a filter is applied to the list.
  defp dropped_sentence(names, []) do
    pngettext(
      "plain",
      "The link's %{names} filter could not be read, so it is not applied.",
      "The link's %{names} filters could not be read, so they are not applied.",
      length(names),
      names: Enum.join(names, ", ")
    )
  end

  defp dropped_sentence(_names, words) do
    pngettext(
      "plain",
      "%{words} could not be read, so it is not applied.",
      "%{words} could not be read, so they are not applied.",
      length(words),
      words: Enum.join(words, " ")
    )
  end

  # The decisions as views, each with its count of destinations.
  defp views do
    [
      {"all", gettext("All"), nil},
      {"denied", gettext("Denied"), "denied"},
      {"allowed", gettext("Allowed"), "allowed"}
    ]
  end

  # The filters as tokens in the query field; the decision is the view's.
  defp tokens(scope, filters, shared) do
    filters
    |> Filters.tokens(except: [:decision], target_text: &target_text(&1, shared))
    |> Enum.map(fn token ->
      %{
        id: "connections-token-#{token.key}",
        qualifier: qualifier(token.key),
        value: token.value,
        remove: token.without && page_path(scope, token.without)
      }
    end)
  end

  # The filter the empty state offers to remove: the last the reader set, never the
  # default window.
  defp last_token(scope, filters, shared) do
    scope
    |> tokens(filters, shared)
    |> Enum.filter(&(&1.remove && &1.id != "connections-token-started"))
    |> List.last()
  end

  # How many filters the Filter menu says are on: the tokens, but the default window,
  # which is said as a token and is no filter the reader set.
  defp filter_count(filters) do
    filters
    |> Filters.tokens(except: [:decision])
    |> Enum.count(&(&1.key != :started or Filters.any_range?(filters)))
  end

  defp qualifier(:target), do: pgettext("qualifier", "target")
  defp qualifier(:started), do: "seen"
  defp qualifier(key), do: Atom.to_string(key)

  # The Target section's options in the one notation of a target, each written as the
  # links write it: the system only where the path is shared. A path given alone is one
  # option with its target's: the first, as the facet puts the chosen first.
  defp target_options(facets, shared) do
    for {label, value, count} <- facet_options(facets, :target) do
      case Jason.decode(value) do
        {:ok, [system, path]} ->
          {target_text({system, path}, shared),
           Filters.target_value(Filters.link_target({system, path}, shared)), count}

        _none ->
          {label, value, count}
      end
    end
    |> Enum.uniq_by(&elem(&1, 1))
  end

  # The Target section's choice, as its options write it: a path given alone is its one
  # target's option.
  defp menu_value(filters, narrowing, shared) do
    narrowing
    |> Narrowing.chosen(filters.target)
    |> Filters.link_target(shared)
    |> Filters.target_value()
  end

  # A target as the query writes it: its system before its path only where the path is on
  # more than one system, as every page writes a target.
  defp target_text(:none, _shared), do: "none"
  defp target_text({nil, path}, _shared), do: path

  defp target_text({system, path}, shared),
    do: if(MapSet.member?(shared, path), do: "#{system}/#{path}", else: path)

  defp sort_label("denied"), do: gettext("Denied first")
  defp sort_label("recent"), do: gettext("Last seen")
  defp sort_label("runs"), do: gettext("Most runs")
  defp sort_label("attempts"), do: gettext("Most attempts")

  defp sort_name("denied"), do: gettext("denied first")
  defp sort_name("recent"), do: gettext("last seen first")
  defp sort_name("runs"), do: gettext("most runs first")
  defp sort_name("attempts"), do: gettext("most attempts first")

  # The page's path with the filters.
  defp page_path(scope, %Filters{} = filters) do
    path = ~p"/#{scope.organisation}/#{scope.workspace}/network"
    params = Filters.to_params(filters)
    if params == %{}, do: path, else: path <> "?" <> URI.encode_query(params)
  end

  defp run_path(scope, run),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network"

  defp narrowed?(%Filters{} = f),
    do: f.decision != nil or f.target != nil or f.host != nil or f.tools or f.q != nil

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
      "14d" -> gettext("No connections in the last 14 days")
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
  defp day(date), do: Format.date(date)

  defp facet_options(facets, name), do: (facets[name] || %{options: []}).options
  defp facet_total(facets, name), do: facets[name] && facets[name].total

  defp with_chosen(options, nil, _label), do: options || []

  defp with_chosen(options, value, label) do
    options = options || []

    if Enum.any?(options, fn {_label, v, _count} -> v == value end),
      do: options,
      else: [{label, value, 0} | options]
  end

  # The line of the list narrowed to a target, under the title (the narrowing ruling):
  # what it shows, the name leading to the target's page; the same target's runs, its
  # policy, and "Show all destinations", which takes the target away and nothing else. A
  # path that two targets share, given alone, names each system, each a link to the list
  # narrowed to its target, and has no one policy. The links beside the sentence are
  # named by it for a screen reader; when "Show all destinations" takes the line away,
  # focus goes to the page's title.
  attr :scope, :any, required: true
  attr :filters, Filters, required: true
  attr :narrowing, :map, default: nil, doc: "`ApiaryWeb.Narrowing.read/2` of the filters' target"

  attr :policy_target, :any,
    default: nil,
    doc: "the one target, read for its policy; nil without security"

  defp target_note(assigns) do
    %{scope: scope, filters: filters, narrowing: narrowing} = assigns
    shared = Narrowing.shared?(narrowing)

    assigns =
      case filters.target do
        {_system, path} = target ->
          found = narrowing && narrowing.target
          system = Narrowing.shown_system(narrowing)
          {linked, _path} = Filters.link_target(Narrowing.chosen(narrowing, target), shared)

          assign(assigns,
            path: path,
            system: system,
            label: if(system, do: "#{system}/#{path}", else: path),
            shared_alone: Narrowing.shared_alone?(narrowing),
            page: found && TargetComponents.target_path(scope, found.system, path, [], shared),
            policy:
              assigns.policy_target &&
                TargetComponents.target_path(scope, found.system, path, ["policy"], shared),
            runs:
              ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{Filters.target_params(linked, path)}"
          )

        :none ->
          assign(assigns,
            path: nil,
            system: nil,
            label: gettext("Unassigned"),
            shared_alone: false,
            page: nil,
            policy: nil,
            runs:
              ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{Filters.target_params(nil, nil)}"
          )
      end

    # The sentence is given whole (no change tracking): a slot passed on through `rich/1`
    # is not drawn again when only a part of it changes.
    assigns =
      assign(assigns,
        all: page_path(scope, Filters.put(filters, target: nil)),
        what: note_what(Map.delete(assigns, :__changed__))
      )

    ~H"""
    <p
      id="connections-target-note"
      class="q-page-desc flex flex-wrap items-baseline gap-x-3 gap-y-1"
      phx-remove={Narrowing.focus_title("connections-target-note")}
    >
      <span id="connections-target-what">
        <.rich text={@what} />
      </span>
      <.link
        id="connections-target-runs"
        navigate={@runs}
        class="q-link"
        aria-label={gettext("Runs, narrowed to %{name}", name: @label)}
      >
        {gettext("Runs")}
      </.link>
      <.link
        :if={@policy}
        id="connections-target-policy"
        navigate={@policy}
        class="q-link"
        aria-describedby="connections-target-what"
      >
        {gettext("Its policy")}
      </.link>
      <.link
        id="connections-target-all"
        patch={@all}
        class="q-link"
        aria-describedby="connections-target-what"
      >
        {gettext("Show all destinations")}
      </.link>
    </p>
    """
  end

  defp note_what(%{shared_alone: true} = assigns) do
    %{scope: scope, filters: filters} = assigns

    Narrowing.shared_sentence(
      assigns.narrowing,
      "connections-target",
      &page_path(scope, Filters.put(filters, target: &1))
    )
  end

  defp note_what(assigns),
    do: rich_gettext("Showing %{target} only.", target: note_name(assigns))

  defp note_name(%{path: nil} = assigns) do
    ~H"""
    <span id="connections-target-name">{@label}</span>
    """
  end

  defp note_name(%{page: page} = assigns) when is_binary(page) do
    ~H"""
    <.link id="connections-target-name" navigate={@page} class="q-link q-narrowed-name"><.target_name
      path={@path}
      system={@system}
    /></.link>
    """
  end

  defp note_name(assigns) do
    ~H"""
    <span id="connections-target-name" class="q-narrowed-name"><.target_name
      path={@path}
      system={@system}
    /></span>
    """
  end

  defp range_value(%Filters{from: nil, to: nil, since: since}), do: since
  defp range_value(%Filters{}), do: nil
end
