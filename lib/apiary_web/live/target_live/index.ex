defmodule ApiaryWeb.TargetLive.Index do
  @moduledoc """
  The workspace's targets: the index GitHub gives an organisation's repositories. One
  row per target, its path the only strong text: the reader's pin, its last run as a dot
  and a time (a word only when it is running or went badly), its runs a day over fourteen
  days, how many of them ended well, its denied attempts in seven days, and its policy
  mode only where it sets its own. Pages of 50.

  Narrowed the way every list is (`docs/ui.md`): views as tabs (All, Active this week,
  Never ran), a search that takes qualifiers (`ApiaryWeb.TargetLive.Query`), one Filter
  menu that writes the same qualifiers, shown as tokens in the search, and Sort. All of it
  is the URL. The page is read off the socket's process (`start_async`) in one query of
  `Apiary.Targets.page/3`: the first render is the table's skeleton, later ones keep
  what is on screen until the new page arrives.

  Live through the workspace's topic: a run that lands re-reads the page at most once a
  second, and the rows on it change in place and in the order they have; a target the
  page did not hold is not inserted under the reader.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  import ApiaryWeb.TargetComponents

  alias Apiary.{Access, Features, Runs, Targets}
  alias ApiaryWeb.TargetLive.Query

  @refresh_window 1_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Runs.subscribe(scope)

    {:ok,
     assign(socket,
       page_title: gettext("Targets"),
       query: %Query{},
       listing: nil,
       counts: nil,
       systems: [],
       pinned: MapSet.new(),
       load_error: false,
       refresh: :closed,
       security:
         Features.on?(scope, :security) and
           Access.can?(scope, :"security_policy.read", scope.workspace)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = Query.parse(params)
    canonical = Query.to_params(query)

    if canonical != Map.take(params, ~w(view q sort page)) do
      {:noreply,
       push_patch(socket, to: index_path(socket.assigns.current_scope, query), replace: true)}
    else
      {:noreply, socket |> assign(:query, query) |> load()}
    end
  end

  defp load(socket) do
    if connected?(socket) do
      %{current_scope: scope, query: query} = socket.assigns

      start_async(socket, :load, fn ->
        now = DateTime.utc_now()

        %{
          query: query,
          listing: Targets.page(scope, Query.to_targets(query), now),
          counts: Targets.view_counts(scope, now),
          systems: Targets.systems(scope),
          pinned: Targets.pinned_ids(scope)
        }
      end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:load, {:ok, %{query: query} = loaded}, socket) do
    if query == socket.assigns.query do
      {:noreply,
       assign(socket,
         listing: loaded.listing,
         counts: loaded.counts,
         systems: loaded.systems,
         pinned: loaded.pinned,
         load_error: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :load_error, true)}

  # A re-read after runs landed: the rows the page holds take their new facts, in the
  # order they have; one the page did not hold is left out.
  def handle_async(:refresh, {:ok, %{query: query} = loaded}, socket) do
    case socket.assigns do
      %{query: ^query, listing: %{rows: rows} = listing} ->
        fresh = Map.new(loaded.listing.rows, &{&1.target.id, &1})
        rows = Enum.map(rows, &Map.get(fresh, &1.target.id, &1))
        {:noreply, assign(socket, listing: %{listing | rows: rows}, counts: loaded.counts)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_async(:refresh, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => typed}, socket) do
    query = socket.assigns.query
    {tokens, text} = Query.parse_search(typed)
    query = %{query | tokens: Enum.uniq(query.tokens ++ tokens), text: text, page: 1}
    {:noreply, push_patch(socket, to: index_path(socket.assigns.current_scope, query))}
  end

  def handle_event("target_pin", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %{} = target <- Targets.get_by_id(scope, id),
         pinned? = MapSet.member?(socket.assigns.pinned, target.id),
         :ok <- if(pinned?, do: Targets.unpin(scope, target), else: Targets.pin(scope, target)) do
      pinned =
        if pinned?,
          do: MapSet.delete(socket.assigns.pinned, target.id),
          else: MapSet.put(socket.assigns.pinned, target.id)

      {:noreply,
       socket
       |> assign(:pinned, pinned)
       |> assign(:nav_counts, Map.put(socket.assigns.nav_counts, :pins, Targets.list_pins(scope)))}
    else
      _refused -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_changed, _run}, socket) do
    case socket.assigns.refresh do
      :closed ->
        Process.send_after(self(), :refresh_window_over, @refresh_window)
        {:noreply, socket |> assign(:refresh, :open) |> refresh()}

      _open_or_dirty ->
        {:noreply, assign(socket, :refresh, :dirty)}
    end
  end

  def handle_info(:refresh_window_over, socket) do
    case socket.assigns.refresh do
      :dirty ->
        Process.send_after(self(), :refresh_window_over, @refresh_window)
        {:noreply, socket |> assign(:refresh, :open) |> refresh()}

      _open ->
        {:noreply, assign(socket, :refresh, :closed)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(%{assigns: %{listing: nil}} = socket), do: socket

  defp refresh(socket) do
    %{current_scope: scope, query: query} = socket.assigns

    start_async(socket, :refresh, fn ->
      now = DateTime.utc_now()

      %{
        query: query,
        listing: Targets.page(scope, Query.to_targets(query), now),
        counts: Targets.view_counts(scope, now)
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:targets}
      width="list"
    >
      <.header>
        {gettext("Targets")}
        <:subtitle>{gettext("The targets this workspace's runs have changed.")}</:subtitle>
      </.header>

      <div class="q-tgt-list">
        <.view_tabs id="targets-views" label={gettext("Views")}>
          <:view
            id="targets-view-all"
            patch={index_path(@current_scope, %{@query | view: :all, page: 1})}
            current={@query.view == :all}
            count={@counts && @counts.all}
          >
            {gettext("All")}
          </:view>
          <:view
            id="targets-view-active"
            patch={index_path(@current_scope, %{@query | view: :active, page: 1})}
            current={@query.view == :active}
            count={@counts && @counts.active}
          >
            {gettext("Active this week")}
          </:view>
          <:view
            id="targets-view-never"
            patch={index_path(@current_scope, %{@query | view: :never, page: 1})}
            current={@query.view == :never}
            count={@counts && @counts.never}
          >
            {gettext("Never ran")}
          </:view>
        </.view_tabs>

        <div class="q-tgt-query">
          <form id="targets-search" class="q-tgt-qbar" phx-submit="search" role="search">
            <.icon name="hero-magnifying-glass-micro" class="size-4 flex-none text-faint" />
            <span :for={token <- @query.tokens} class="q-tgt-qtok">
              <span class="q-tgt-qtok-k">{token_key(token)}:</span>{token_value(token)}
              <.link
                patch={index_path(@current_scope, Query.toggle(@query, token))}
                aria-label={gettext("Remove %{filter}", filter: Query.token_text(token))}
              >
                <.icon name="hero-x-mark-micro" class="size-3" />
              </.link>
            </span>
            <label for="targets-q" class="sr-only">{gettext("Find a target")}</label>
            <input
              id="targets-q"
              type="search"
              name="q"
              value={@query.text}
              placeholder={placeholder(@systems)}
              autocomplete="off"
              spellcheck="false"
            />
          </form>
          <.filter_menu
            query={@query}
            systems={@systems}
            security={@security}
            current_scope={@current_scope}
          />
          <.sort_menu query={@query} current_scope={@current_scope} />
        </div>

        <p :if={Query.narrowed?(@query) && @listing} id="targets-summary" class="q-tgt-summary">
          <.rich text={
            rich_ngettext("%{number} target matches", "%{number} targets match", @listing.total,
              number: {:b, Format.number(@listing.total)}
            )
          } />
          <.link
            id="targets-clear"
            patch={index_path(@current_scope, %Query{view: @query.view, sort: @query.sort})}
          >
            {gettext("Clear")}
          </.link>
        </p>

        <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
          {gettext("The targets could not be read. Reload the page to try again.")}
        </.notice>

        <.table_skeleton :if={!@listing && !@load_error} />

        <div :if={@listing && @listing.rows == []} id="targets-empty">
          <.empty_state
            :if={!Query.narrowed?(@query) && @query.view == :all}
            icon="hero-folder"
            tone="neutral"
            title={gettext("No target yet")}
          >
            {gettext("A target is listed here once a run of this workspace names it.")}
          </.empty_state>
          <.empty_state
            :if={Query.narrowed?(@query) or @query.view != :all}
            icon="hero-magnifying-glass"
            tone="neutral"
            title={empty_title(@query)}
          >
            <:actions :if={Query.narrowed?(@query)}>
              <.button patch={
                index_path(@current_scope, %Query{view: @query.view, sort: @query.sort})
              }>
                {gettext("Clear the search")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <div
          :if={@listing && @listing.rows != []}
          class="q-tgt-table-wrap"
          tabindex="0"
          role="region"
          aria-label={gettext("Targets")}
        >
          <table class={["q-tgt-table q-tgt-index", @query.view == :never && "q-tgt-never"]}>
            <thead>
              <tr>
                <th scope="col" class="q-tgt-c-pin">
                  <span class="sr-only">{gettext("Pinned")}</span>
                </th>
                <th scope="col">{gettext("Target")}</th>
                <th scope="col" class="q-tgt-act">{gettext("Last run")}</th>
                <th scope="col" class="q-tgt-k2 q-tgt-act">{gettext("Runs, 14 days")}</th>
                <th
                  scope="col"
                  class="q-tgt-k4 q-tgt-act q-tgt-r"
                  title={gettext("Of the runs that ended in the last 14 days, those that ended well")}
                >
                  {gettext("Ended well")}
                </th>
                <th
                  scope="col"
                  class="q-tgt-k3 q-tgt-act q-tgt-r"
                  title={gettext("Denied attempts in the last 7 days")}
                >
                  {gettext("Denied")}
                </th>
                <th :if={@security} scope="col" class="q-tgt-k4">{gettext("Policy")}</th>
              </tr>
            </thead>
            <tbody id="targets">
              <tr :for={row <- @listing.rows} id={"target-#{row.target.id}"}>
                <td class="q-tgt-c-pin">
                  <.pin_button
                    id={"target-pin-#{row.target.id}"}
                    target={row.target}
                    pinned={MapSet.member?(@pinned, row.target.id)}
                  />
                </td>
                <td class="q-tgt-c-name">
                  <.link
                    id={"target-link-#{row.target.id}"}
                    navigate={target_path(@current_scope, row.target.system, row.target.path)}
                    class="q-tgt-name"
                    title={"#{row.target.system}/#{row.target.path}"}
                  >
                    <.target_name path={row.target.path} system={row.shared && row.target.system} />
                  </.link>
                </td>
                <td class="q-tgt-act whitespace-nowrap">
                  <.last_run :if={row.last} last={row.last} />
                  <span :if={!row.last} class="text-faint">{gettext("Never ran")}</span>
                </td>
                <td class="q-tgt-k2 q-tgt-act whitespace-nowrap">
                  <span :if={row.runs > 0} class="q-tgt-sp">
                    <.spark days={row.days} />
                    <span class="q-tgt-num">{Format.number(row.runs)}</span>
                  </span>
                </td>
                <td class="q-tgt-k4 q-tgt-act q-tgt-r q-tgt-num">
                  <span :if={rate = rate(row)} class={rate < 80 && "text-error"}>
                    {gettext("%{percent}%", percent: rate)}
                  </span>
                </td>
                <td class="q-tgt-k3 q-tgt-act q-tgt-r">
                  <.denied
                    count={row.denied}
                    title={
                      ngettext(
                        "%{number} denied attempt in the last 7 days",
                        "%{number} denied attempts in the last 7 days",
                        row.denied,
                        number: Format.number(row.denied)
                      )
                    }
                  />
                </td>
                <td :if={@security} class="q-tgt-k4 whitespace-nowrap">
                  {own_mode(row.target.egress_mode)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <nav
          :if={@listing && @listing.total > 0}
          id="targets-pager"
          class="q-tgt-pager"
          aria-label={gettext("Pages")}
        >
          <span class="grow">
            {gettext("%{first}–%{last} of %{total}",
              first: Format.number((@listing.page - 1) * Targets.page_size() + 1),
              last: Format.number((@listing.page - 1) * Targets.page_size() + length(@listing.rows)),
              total: Format.number(@listing.total)
            )}
          </span>
          <.button
            :if={@listing.page > 1}
            id="targets-previous"
            size="xs"
            patch={index_path(@current_scope, %{@query | page: @listing.page - 1})}
          >
            <.icon name="hero-arrow-left-micro" class="size-3.5" />{gettext("Previous")}
          </.button>
          <.button
            :if={@listing.page < @listing.pages}
            id="targets-next"
            size="xs"
            patch={index_path(@current_scope, %{@query | page: @listing.page + 1})}
          >
            {gettext("Next")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
          </.button>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  # The last run: its dot and when, and its word only when it is running or went badly.
  attr :last, :map, required: true

  defp last_run(assigns) do
    ~H"""
    <span class="q-tgt-last">
      <span class={["q-sdot", "q-sdot-#{@last.state}"]}>
        <i aria-hidden="true"></i><span class="sr-only">{state_label(@last.state)}</span>
      </span>
      <.relative_time at={@last.at} />
      <span
        :if={@last.state not in ~w(succeeded closed)}
        class={["q-tgt-lw", "q-sdot-#{@last.state}"]}
        aria-hidden="true"
      >
        {state_label(@last.state)}
      </span>
    </span>
    """
  end

  # One Filter menu: its sections write the qualifiers the search takes, each a link that
  # adds its qualifier or takes it away.
  attr :query, :any, required: true
  attr :systems, :list, required: true
  attr :security, :boolean, required: true
  attr :current_scope, :any, required: true

  defp filter_menu(assigns) do
    ~H"""
    <div
      id="targets-filter"
      class="dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="targets-filter-button"
        type="button"
        class="btn btn-sm q-tgt-menubtn"
        aria-haspopup="menu"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-funnel" class="size-4" />{gettext("Filter")}
      </button>
      <ul
        class="menu menu-sm dropdown-content q-tgt-menu right-0 top-full mt-1.5 w-72"
        role="menu"
        aria-label={gettext("Filter")}
      >
        <li :if={@systems != []} class="menu-title" role="presentation">{gettext("System")}</li>
        <li :for={{system, count} <- @systems} role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:system, system}}
            id={"targets-filter-system-#{system}"}
          >
            <span class="min-w-0 flex-1 truncate font-mono text-[12.5px]">{system}</span>
            <span class="q-tgt-menu-n">{Format.number(count)}</span>
          </.filter_item>
        </li>
        <li class="menu-title" role="presentation">{gettext("Activity")}</li>
        <li role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:activity, :quiet_30}}
            id="targets-filter-quiet-30"
          >
            {gettext("No run in 30 days")}
          </.filter_item>
        </li>
        <li role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:activity, :quiet_90}}
            id="targets-filter-quiet-90"
          >
            {gettext("No run in 90 days")}
          </.filter_item>
        </li>
        <li :if={@security} class="menu-title" role="presentation">{gettext("Policy")}</li>
        <li :if={@security} role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:mode, :follows}}
            id="targets-filter-follows"
          >
            {gettext("Follows the workspace")}
          </.filter_item>
        </li>
        <li :if={@security} role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:mode, :observes}}
            id="targets-filter-observes"
          >
            {gettext("Observes on its own")}
          </.filter_item>
        </li>
        <li :if={@security} role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:mode, :enforces}}
            id="targets-filter-enforces"
          >
            {gettext("Enforces on its own")}
          </.filter_item>
        </li>
        <li class="menu-title" role="presentation">{gettext("Pinned")}</li>
        <li role="none">
          <.filter_item
            current_scope={@current_scope}
            query={@query}
            token={{:pinned, true}}
            id="targets-filter-pinned"
          >
            {gettext("Pinned by you")}
          </.filter_item>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :current_scope, :any, required: true
  attr :query, :any, required: true
  attr :token, :any, required: true
  slot :inner_block, required: true

  defp filter_item(assigns) do
    assigns = assign(assigns, :on, assigns.token in assigns.query.tokens)

    ~H"""
    <.link
      id={@id}
      patch={index_path(@current_scope, Query.toggle(@query, @token))}
      role="menuitemcheckbox"
      aria-checked={to_string(@on)}
    >
      <.icon name="hero-check-micro" class={["size-4", !@on && "invisible"]} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :query, :any, required: true
  attr :current_scope, :any, required: true

  defp sort_menu(assigns) do
    ~H"""
    <div
      id="targets-sort"
      class="dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="targets-sort-button"
        type="button"
        class="btn btn-sm q-tgt-menubtn"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Sort: %{order}", order: sort_word(@query.sort))}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-arrows-up-down" class="size-4" />{sort_word(@query.sort)}
      </button>
      <ul
        class="menu menu-sm dropdown-content q-tgt-menu right-0 top-full mt-1.5 w-60"
        role="menu"
        aria-label={gettext("Sort")}
      >
        <li :for={sort <- Targets.sorts()} role="none">
          <.link
            id={"targets-sort-#{sort}"}
            patch={index_path(@current_scope, %{@query | sort: sort, page: 1})}
            role="menuitemradio"
            aria-checked={to_string(@query.sort == sort)}
          >
            <.icon name="hero-check-micro" class={["size-4", @query.sort != sort && "invisible"]} />
            {sort_label(sort)}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp table_skeleton(assigns) do
    ~H"""
    <div id="targets-loading" class="q-tgt-table-wrap" aria-busy="true">
      <table class="q-tgt-table">
        <tbody>
          <tr :for={n <- 1..8}>
            <td class="q-tgt-c-pin"></td>
            <td>
              <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-44", else: "w-32")]}></span>
            </td>
            <td><span class="skeleton q-skel w-24"></span></td>
            <td class="q-tgt-k2"><span class="skeleton q-skel w-24"></span></td>
            <td class="q-tgt-k4"><span class="skeleton q-skel ml-auto w-10"></span></td>
            <td class="q-tgt-k3"><span class="skeleton q-skel ml-auto w-6"></span></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  ## Words and paths

  defp index_path(scope, %Query{} = query) do
    ~p"/#{scope.organisation}/#{scope.workspace}/targets?#{Query.to_params(query)}"
  end

  defp placeholder([{system, _count} | _]),
    do: gettext("Find a target, e.g. %{example}", example: "#{Query.system_key()}:#{system}")

  defp placeholder([]), do: gettext("Find a target")

  defp token_key({:system, _system}), do: Query.system_key()
  defp token_key({:pinned, true}), do: "is"
  defp token_key({key, _value}), do: to_string(key)

  defp token_value(token),
    do: token |> Query.token_text() |> String.split(":", parts: 2) |> List.last()

  defp sort_word(:last_run), do: gettext("Last run")
  defp sort_word(:name), do: gettext("Name")
  defp sort_word(:runs), do: gettext("Most runs")
  defp sort_word(:denials), do: gettext("Most denials")

  defp sort_label(:last_run), do: gettext("Last run")
  defp sort_label(:name), do: gettext("Name")
  defp sort_label(:runs), do: gettext("Most runs in 14 days")
  defp sort_label(:denials), do: gettext("Most denials in 7 days")

  defp empty_title(%Query{view: :never} = query) do
    if Query.narrowed?(query),
      do: gettext("No target that never ran matches"),
      else: gettext("Every target has run")
  end

  defp empty_title(%Query{view: :active} = query) do
    if Query.narrowed?(query),
      do: gettext("No target active this week matches"),
      else: gettext("No target ran this week")
  end

  defp empty_title(_query), do: gettext("No target matches")

  # Of the runs that ended in the window, the share that ended well; none without one.
  defp rate(%{ended_well: well, ended_badly: badly}) when well + badly > 0,
    do: round(well * 100 / (well + badly))

  defp rate(_row), do: nil

  defp own_mode("observe"), do: gettext("observes")
  defp own_mode("enforce"), do: gettext("enforces")
  defp own_mode(_follows), do: nil
end
