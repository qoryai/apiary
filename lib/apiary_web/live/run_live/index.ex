defmodule ApiaryWeb.RunLive.Index do
  @moduledoc """
  The runs of the workspace, the record: one flat list, newest first unless the reader
  sorts it otherwise, one line per run with its state, what it worked on, where and for how
  long, and its denials. It is narrowed as every list is (docs/ui.md, Lists): the views as
  tabs (every run, alive, ended badly, with denials, each counted under the other filters),
  one query field whose filters show as tokens, one Filter menu (target, state, task,
  runtime, host, access key, when it started, denials), and Sort (newest, oldest, longest,
  most denials). From 1280 px a rail beside the list holds the targets with their runs,
  pinned first; choosing one is the target filter. The list has no time range until the
  reader sets one. Pages of 25, 50 or 100, "1–50 of 3,137", and Jump to date.

  Every filter, the order, the page size and the page are query parameters, read through
  `Apiary.Runs.Filters`: a value it does not know is dropped and the URL rewritten. What the
  reader types in the query field is read by `Apiary.Runs.Filters.apply_query/3` into the
  same parameters, the free text as `q`.

  From 1920 px a preview pane beside the list shows the run chosen (`?run=`, patched by a
  click or ↑ and ↓ while the list has focus; the first row until then): its state, its
  facts, its denials and the last lines of its log. The page learns the width from the
  `RunList` hook; below 1920 px a row is a link to the run's page.

  Live through the workspace's topic (`docs/ui.md`). A run on the page changes in place,
  by its DOM id; changes are collected and applied at most every 250 ms, and the rows are
  a keyed comprehension, so only the rows that changed are sent. A new run that the
  filters return is never inserted under the reader: the pill beside the title counts it,
  said politely to a screen reader, and the page asks again when the reader follows it.
  Whether a running run has gone quiet is decided here, on a 5 s timer and on every change,
  never in the browser.

  The page is loaded off the socket's process (`start_async`): the first render is the
  table's skeleton, later ones keep what is on screen until the new page arrives. The runs
  are the record (`observability`).
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  alias Apiary.AccessKeys
  alias Apiary.Runs
  alias Apiary.Runs.Filters
  alias Apiary.Runs.Record

  @quiet_tick 5_000
  @summary_window 1_000
  @preview_window 1_000
  @flush_window 250
  @preview_lines 30
  @preview_denials 5
  # Closed's tooltip in the State section: what the state means and where it is counted.
  @closed_menu_tip [
    gettext_noop("Stopped by the workspace: a member closed it after it went quiet."),
    gettext_noop("Counted with the runs that ended badly.")
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:runs}
      width="work"
    >
      <div id="runs-page" class={["q-lp", @preview_on && "q-lp-preview"]}>
        <.header>
          {gettext("Runs")}
          <:subtitle>
            {gettext("Every run the machines of this workspace have posted, as their events tell it.")}
          </:subtitle>
          <:actions>
            <%!-- Never followed for the reader: a screen reader's cursor leaves focus on the
            body, which looks like "nothing focused". The pill is shown and said politely. --%>
            <span id="runs-new-status" role="status" aria-live="polite">
              <button
                :if={MapSet.size(@new_ids) > 0}
                id="runs-new"
                type="button"
                class="q-newpill q-newpill-show q-newpill-head"
                phx-click="show_new"
              >
                <.icon name="hero-arrow-up-micro" class="size-4" />
                {ngettext("%{number} new run", "%{number} new runs", MapSet.size(@new_ids),
                  number: Format.number(MapSet.size(@new_ids))
                )}
              </button>
            </span>
          </:actions>
        </.header>

        <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
          <span id="runs-error">
            {gettext(
              "The runs could not be loaded. Reload the page; if it keeps happening, the server log has the reason."
            )}
          </span>
        </.notice>

        <.notice :if={@dropped != [] or @refused != []} kind={:warning} class="max-w-[80ch]">
          <span id="runs-dropped">{dropped_sentence(@dropped, @refused)}</span>
        </.notice>

        <%= if !@load_error && !first_run?(@listing, @filters) do %>
          <.views id="runs-views" label={gettext("Views")}>
            <:view
              :for={view <- view_list(@filters)}
              id={"runs-view-#{view.key}"}
              patch={page_path(@current_scope, view.filters)}
              current={view.current}
              count={@views && Format.number(Map.fetch!(@views, view.count))}
            >
              {view.label}
            </:view>
          </.views>

          <div id="runs-filters" class="q-bar">
            <.list_search
              id="runs-query"
              class="q-find-query"
              label={gettext("Filter runs")}
              placeholder={gettext("Filter runs, e.g. state:failed host:gpu-01 started:>2026-09-01")}
              value={@filters.q}
              change="query"
              live={false}
            />
            <.filter_menu id="runs-filter" count={length(Filters.tokens(@filters))}>
              <:section
                key="target"
                label={gettext("Target")}
                icon="hero-folder-micro"
                qualifier={pgettext("qualifier", "target")}
                value={@filters.target && target_text(@filters.target, @shared)}
                rail
              >
                <.filter_options
                  id="filter-target"
                  name="target"
                  label={gettext("Target")}
                  values={List.wrap(Filters.target_value(@filters.target))}
                  options={
                    with_chosen(
                      target_options(@facets, @shared),
                      Filters.target_value(@filters.target),
                      @filters.target && target_text(@filters.target, @shared)
                    )
                  }
                  total={facet_total(@facets, :target)}
                  query={@narrow["target"]}
                  more="more_options"
                />
              </:section>
              <:section
                key="state"
                label={gettext("State")}
                icon="hero-check-circle-micro"
                qualifier="state"
                value={
                  @filters.states != [] &&
                    (family_words(@filters.states) || state_words(@filters.states))
                }
              >
                <.filter_options
                  id="filter-state"
                  name="state"
                  label={gettext("State")}
                  multiple
                  values={@filters.states}
                  options={state_options(@facets)}
                  groups={state_groups()}
                  tips={state_tips()}
                />
              </:section>
              <:section
                :for={{name, label, icon} <- text_sections()}
                key={name}
                label={label}
                icon={icon}
                qualifier={name}
                value={text_value(@filters, name)}
              >
                <.filter_options
                  id={"filter-#{name}"}
                  name={name}
                  label={label}
                  values={List.wrap(text_param(@filters, name))}
                  options={
                    with_chosen(
                      facet_options(@facets, String.to_existing_atom(name)),
                      text_param(@filters, name),
                      text_value(@filters, name)
                    )
                  }
                  total={facet_total(@facets, String.to_existing_atom(name))}
                  query={@narrow[name]}
                  more="more_options"
                />
              </:section>
              <:section
                key="since"
                label={gettext("Started")}
                icon="hero-calendar-micro"
                qualifier="started"
                value={Filters.range_label(@filters)}
              >
                <.filter_options
                  id="filter-since"
                  name="since"
                  label={gettext("Started")}
                  values={List.wrap(range_value(@filters))}
                  options={for {label, value} <- Filters.ranges(), do: {label, value, nil}}
                  dates={
                    %{
                      from: @filters.from && Date.to_iso8601(@filters.from),
                      to: @filters.to && Date.to_iso8601(@filters.to)
                    }
                  }
                />
              </:section>
              <:section
                key="denials"
                label={gettext("Denials")}
                icon="hero-no-symbol-micro"
                qualifier="denied"
                value={@filters.denials && gettext("With denials")}
              >
                <.filter_check
                  id="filter-denials"
                  name="denials"
                  label={gettext("With denials")}
                  checked={@filters.denials}
                />
              </:section>
            </.filter_menu>
            <.sort_menu
              id="runs-sort"
              current={sort_name(@filters.sort)}
              label={sort_label(@filters.sort)}
            >
              <.menu_item
                :for={sort <- Filters.sorts(:runs)}
                id={"runs-sort-#{sort}"}
                patch={page_path(@current_scope, Filters.put(@filters, sort: sort))}
                checked={@filters.sort == sort}
              >
                {sort_label(sort)}
              </.menu_item>
            </.sort_menu>
          </div>

          <.filter_tokens
            id="runs-tokens"
            clear={Filters.any?(@filters) && page_path(@current_scope, Filters.clear(@filters))}
          >
            <:token
              :for={token <- tokens(@current_scope, @filters, @shared)}
              id={token.id}
              class="q-tok-q"
              patch={token.remove}
              label={gettext("Remove %{token}", token: "#{token.qualifier}:#{token.value}")}
            >
              <span class="q-tok-k">{token.qualifier}:</span>{token.value}
            </:token>
          </.filter_tokens>

          <div class="q-with-rail">
            <.target_rail
              id="runs-rail"
              label={gettext("Targets")}
              rail={@rail}
              chosen={@filters.target}
              shared={@shared}
              query={@rail_query}
              path={&page_path(@current_scope, Filters.put(@filters, target: &1))}
            />

            <div class="q-with-preview">
              <div class="q-list-col">
                <%!-- Always there, so a screen reader hears what a view or a filter left. --%>
                <div id="runs-status" role="status" class="q-status">
                  <p
                    :if={@listing && @listing.runs != [] && Filters.any?(@filters)}
                    id="runs-summary"
                    class="q-matchline"
                  >
                    <.rich text={
                      rich_ngettext(
                        "%{number} run matches",
                        "%{number} runs match",
                        @listing.total,
                        number: {:b, Format.number(@listing.total)}
                      )
                    } />
                  </p>
                  <p :if={@listing && @listing.runs == []} class="sr-only">
                    {empty_title(@filters)}
                  </p>
                </div>

                <.runs_table
                  :if={@listing == nil || @listing.runs != []}
                  id="runs"
                  label={gettext("Runs")}
                  runs={(@listing && @listing.runs) || []}
                  scope={@current_scope}
                  quiet_ids={@quiet_ids}
                  selected={@preview_on && @preview_id}
                  loading={@listing == nil}
                  shared={@shared}
                  phx-hook="RunList"
                />

                <.empty_state
                  :if={@listing && @listing.runs == []}
                  icon="hero-funnel"
                  tone="neutral"
                  title={empty_title(@filters)}
                >
                  <span :if={@workspace_runs} id="runs-hidden">
                    {hidden_sentence(@workspace_runs)}
                  </span>
                  <:actions>
                    <.button
                      :if={last_token(@current_scope, @filters, @shared)}
                      id="runs-remove-last"
                      patch={last_token(@current_scope, @filters, @shared).remove}
                    >
                      {gettext("Remove %{token}",
                        token:
                          "#{last_token(@current_scope, @filters, @shared).qualifier}:#{last_token(@current_scope, @filters, @shared).value}"
                      )}
                    </.button>
                    <.button
                      :if={Filters.any?(@filters)}
                      id="runs-clear"
                      patch={page_path(@current_scope, Filters.clear(@filters))}
                    >
                      {gettext("Clear filters")}
                    </.button>
                  </:actions>
                </.empty_state>

                <.pager
                  :if={@listing && @listing.runs != []}
                  id="runs-pager"
                  prefix="runs"
                  first={(@listing.page - 1) * @listing.per + 1}
                  last={(@listing.page - 1) * @listing.per + length(@listing.runs)}
                  total={@listing.total}
                  previous={
                    @listing.page > 1 &&
                      page_path(@current_scope, %{@filters | page: @listing.page - 1})
                  }
                  next={
                    @listing.page < @listing.pages &&
                      page_path(@current_scope, %{@filters | page: @listing.page + 1})
                  }
                  previous_label={previous_label(@filters.sort)}
                  next_label={next_label(@filters.sort)}
                >
                  <.segments id="runs-per" label={gettext("Runs a page")}>
                    <:segment
                      :for={per <- Filters.pers()}
                      patch={page_path(@current_scope, Filters.put(@filters, per: per))}
                      pressed={@filters.per == per}
                    >
                      {Format.number(per)}
                    </:segment>
                  </.segments>
                  <div
                    :if={@filters.sort in ~w(newest oldest)}
                    id="runs-jump"
                    class="dropdown dropdown-top dropdown-end"
                    phx-hook="Menu"
                    phx-mounted={JS.ignore_attributes(["class"])}
                  >
                    <button
                      id="runs-jump-button"
                      type="button"
                      class="btn btn-ghost btn-sm"
                      aria-haspopup="dialog"
                      aria-controls="runs-jump-panel"
                      aria-expanded="false"
                      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
                    >
                      <.icon name="hero-calendar-micro" class="size-4" />{gettext("Jump to date")}
                    </button>
                    <div
                      id="runs-jump-panel"
                      role="dialog"
                      aria-label={gettext("Jump to date")}
                      class="dropdown-content q-jumpdate"
                    >
                      <form
                        id="runs-jump-form"
                        phx-submit={
                          JS.push("jump") |> JS.remove_class("dropdown-open", to: "#runs-jump")
                        }
                      >
                        <label for="runs-jump-date">{gettext("Day")}</label>
                        <input
                          id="runs-jump-date"
                          type="date"
                          name="date"
                          class="input input-sm"
                          required
                        />
                        <.button type="submit" size="sm">{gettext("Go")}</.button>
                        <p class="q-jumpdate-note">
                          {if @filters.sort == "newest",
                            do:
                              gettext(
                                "The page of the first run started on or before that day, in UTC."
                              ),
                            else:
                              gettext(
                                "The page of the first run started on or after that day, in UTC."
                              )}
                        </p>
                      </form>
                    </div>
                  </div>
                </.pager>
              </div>

              <.run_preview
                :if={@preview_on}
                id="runs-preview"
                scope={@current_scope}
                preview={@preview}
                shared={@shared}
              />
            </div>
          </div>
        <% end %>

        <div :if={!@load_error && first_run?(@listing, @filters)} class="grid gap-4">
          <.empty_state :if={!@has_keys} icon="hero-play-circle" title={gettext("No runs yet")}>
            {gettext(
              "A run appears here when a machine with an access key of this workspace starts one."
            )}
            {gettext(
              "Create a key, paste its server block into the runner file on the machine, and start a run."
            )}
            <:actions>
              <.button
                id="runs-create-key"
                variant="primary"
                navigate={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys/new"
                }
              >
                {gettext("Create an access key")}
              </.button>
            </:actions>
          </.empty_state>
          <.empty_state :if={@has_keys} icon="hero-play-circle" title={gettext("No runs yet")}>
            {gettext("No machine has posted a run to this workspace yet.")}
            {gettext("The server block to paste into the runner file is on the access keys page.")}
            <:actions>
              <.button
                id="runs-go-to-keys"
                navigate={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys"
                }
              >
                {gettext("Go to access keys")}
              </.button>
            </:actions>
          </.empty_state>
          <.listening :if={@has_keys}>{gettext("Listening for the first run.")}</.listening>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Runs.subscribe(scope)
      Process.send_after(self(), :quiet_tick, @quiet_tick)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Runs"),
       filters: Filters.new(:runs),
       loaded: nil,
       listing: nil,
       views: nil,
       rail: nil,
       rail_query: nil,
       rail_limit: Runs.rail_size(),
       facets: %{},
       narrow: %{},
       limits: %{},
       shared: MapSet.new(),
       workspace_runs: nil,
       new_ids: MapSet.new(),
       quiet_ids: MapSet.new(),
       loaded_at: DateTime.utc_now(),
       load_error: false,
       summary_window: :closed,
       preview_window: :closed,
       dropped: [],
       refused: [],
       chosen: nil,
       wide: false,
       preview_on: false,
       preview_id: nil,
       preview: nil,
       has_keys: AccessKeys.list_access_keys(scope) != []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {chosen, rest} = Map.pop(params, "run")
    chosen = run_id(chosen)
    filters = Filters.parse(rest, :runs)
    bad_run? = Map.has_key?(params, "run") and is_nil(chosen)

    # The path's organisation and workspace are not filters.
    if not bad_run? and Filters.to_params(filters) == Map.drop(rest, ["org", "workspace"]) do
      socket =
        socket
        |> keep_notices()
        |> assign(:chosen, chosen)

      if socket.assigns.loaded && Filters.same?(filters, socket.assigns.filters),
        do: {:noreply, socket |> assign(:filters, filters) |> show_preview()},
        else: {:noreply, socket |> assign(:filters, filters) |> load()}
    else
      # A value the page does not know was dropped: the address bar says what is shown,
      # and the page says that the link was not read in full.
      {:noreply,
       socket
       |> assign(:dropped, filters.dropped ++ if(bad_run?, do: ["run"], else: []))
       |> put_private(:notice_kept, true)
       |> push_patch(
         to: page_path(socket.assigns.current_scope, %{filters | dropped: []}, chosen),
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
      Filters.apply_query(socket.assigns.filters, text, resolve: &Runs.resolve_target(scope, &1))

    {:noreply,
     socket
     |> assign(:refused, refused)
     |> put_private(:notice_kept, refused != [])
     |> push_patch(to: page_path(scope, filters))}
  end

  def handle_event("query", _params, socket), do: {:noreply, socket}

  # What the reader types in a section narrows that section's options on the server, over
  # every value there is; Show more asks for more of them.
  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket)
      when name in ~w(target task runtime host key) and is_binary(q) do
    narrow = Map.put(socket.assigns.narrow, name, String.slice(q, 0, 256))
    {:noreply, socket |> assign(:narrow, narrow) |> load_facets()}
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  def handle_event("more_options", %{"name" => name}, socket)
      when name in ~w(target task runtime host key) do
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

  def handle_event("jump", %{"date" => date}, socket) when is_binary(date) do
    %{current_scope: scope, filters: filters} = socket.assigns

    case Date.from_iso8601(date) do
      {:ok, %Date{year: year} = day} when year in 2000..2999 ->
        page = Runs.jump_page(scope, filters, day)
        {:noreply, push_patch(socket, to: page_path(scope, %{filters | page: page}))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("jump", _params, socket), do: {:noreply, socket}

  # The width the page is read at, from the RunList hook: the preview is for 1920 px and
  # more, and the first row is chosen there until the reader chooses one.
  def handle_event("viewport", %{"wide" => wide}, socket) when is_boolean(wide) do
    {:noreply, socket |> assign(:wide, wide) |> show_preview()}
  end

  def handle_event("viewport", _params, socket), do: {:noreply, socket}

  # A row chosen in the list, by a click or an arrow key: its id goes into the URL, so a
  # preview is a link. Only a run of the page is chosen here.
  def handle_event("select", %{"id" => id}, socket) when is_binary(id) do
    %{current_scope: scope, filters: filters, listing: listing} = socket.assigns

    if listing && Enum.any?(listing.runs, &(&1.run_id == id)),
      do: {:noreply, push_patch(socket, to: page_path(scope, filters, id), replace: true)},
      else: {:noreply, socket}
  end

  def handle_event("select", _params, socket), do: {:noreply, socket}

  def handle_event("open", %{"id" => id}, socket) when is_binary(id) do
    %{current_scope: scope, listing: listing} = socket.assigns

    if listing && Enum.any?(listing.runs, &(&1.run_id == id)),
      do:
        {:noreply,
         push_navigate(socket, to: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{id}")},
      else: {:noreply, socket}
  end

  def handle_event("open", _params, socket), do: {:noreply, socket}

  def handle_event("show_new", _params, socket) do
    filters = socket.assigns.filters

    if filters.page == 1,
      do: {:noreply, load(socket)},
      else:
        {:noreply,
         push_patch(socket, to: page_path(socket.assigns.current_scope, %{filters | page: 1}))}
  end

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
         facets: loaded.facets,
         shared: loaded.shared,
         workspace_runs: loaded.workspace_runs,
         loaded_at: loaded.at,
         new_ids: MapSet.new(),
         load_error: false
       )
       |> assign_quiet()
       |> show_preview()}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:load, {:exit, _reason}, socket) do
    {:noreply, assign(socket, load_error: true)}
  end

  def handle_async(:facets, {:ok, %{filters: filters, key: key, facets: facets}}, socket) do
    if filters == socket.assigns.filters and key == facet_key(socket),
      do: {:noreply, assign(socket, :facets, facets)},
      else: {:noreply, socket}
  end

  def handle_async(:facets, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:rail, {:ok, %{filters: filters, key: key, rail: rail}}, socket) do
    if filters == socket.assigns.filters and key == rail_key(socket),
      do: {:noreply, assign(socket, :rail, rail)},
      else: {:noreply, socket}
  end

  def handle_async(:rail, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:views, {:ok, %{filters: filters, views: views}}, socket) do
    if filters == socket.assigns.filters,
      do: {:noreply, assign(socket, :views, views)},
      else: {:noreply, socket}
  end

  def handle_async(:views, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:preview, {:ok, %{id: id, preview: preview}}, socket) do
    if id == socket.assigns.preview_id,
      do: {:noreply, assign(socket, :preview, preview)},
      else: {:noreply, socket}
  end

  def handle_async(:preview, {:exit, _reason}, socket), do: {:noreply, socket}

  # Changes are collected and applied at most once every @flush_window: at once for the
  # first, then together when the window ends. A busy workspace costs this page one render
  # and at most one query a window, however many batches land; nothing is read again for a
  # row, the message carries the run.
  @impl true
  def handle_info({:run_changed, run}, socket) do
    changed = Map.put(socket.private[:changed] || %{}, run.id, run)
    socket = put_private(socket, :changed, changed)

    case socket.private[:flush_window] do
      :open ->
        {:noreply, socket}

      _closed ->
        Process.send_after(self(), :flush_runs, @flush_window)
        {:noreply, socket |> put_private(:flush_window, :open) |> flush()}
    end
  end

  def handle_info(:flush_runs, socket) do
    if map_size(socket.private[:changed] || %{}) > 0 do
      Process.send_after(self(), :flush_runs, @flush_window)
      {:noreply, flush(socket)}
    else
      {:noreply, put_private(socket, :flush_window, :closed)}
    end
  end

  def handle_info(:quiet_tick, socket) do
    Process.send_after(self(), :quiet_tick, @quiet_tick)
    {:noreply, socket |> assign_quiet() |> assign_preview_quiet()}
  end

  def handle_info(:summary_window_over, socket) do
    case socket.assigns.summary_window do
      :dirty -> {:noreply, socket |> assign(:summary_window, :closed) |> touch_views()}
      _open -> {:noreply, assign(socket, :summary_window, :closed)}
    end
  end

  def handle_info(:preview_window_over, socket) do
    case socket.assigns.preview_window do
      :dirty -> {:noreply, socket |> assign(:preview_window, :closed) |> reload_preview()}
      _open -> {:noreply, assign(socket, :preview_window, :closed)}
    end
  end

  defp flush(%{assigns: %{listing: nil}} = socket), do: put_private(socket, :changed, %{})

  defp flush(socket) do
    %{listing: listing, filters: filters, current_scope: scope, new_ids: new_ids} =
      socket.assigns

    changed = socket.private[:changed] || %{}
    socket = put_private(socket, :changed, %{})
    on_page = MapSet.new(listing.runs, & &1.id)

    # Only a run that did not exist when the page was read can be new to it; an old run
    # of another page changing costs nothing. One query for all of them.
    candidates =
      for {id, run} <- changed,
          not MapSet.member?(on_page, id),
          not MapSet.member?(new_ids, id),
          DateTime.compare(run.inserted_at, socket.assigns.loaded_at) == :gt,
          do: id

    new = if candidates == [], do: [], else: Runs.matching_ids(scope, filters, candidates)

    socket =
      if Enum.any?(changed, fn {id, _run} -> MapSet.member?(on_page, id) end) do
        runs = Enum.map(listing.runs, &Map.get(changed, &1.id, &1))

        socket
        |> assign(listing: %{listing | runs: runs})
        |> assign_quiet()
      else
        socket
      end

    socket = if new == [], do: socket, else: assign(socket, :new_ids, Enum.into(new, new_ids))

    socket =
      case socket.assigns.preview do
        %{run: %{id: id}} when is_map_key(changed, id) -> touch_preview(socket)
        _other -> socket
      end

    if map_size(changed) > 0, do: touch_views(socket), else: socket
  end

  # The views' counts are counted again at once on the first change, then at most once a
  # second while changes keep coming. The rail is not: its rows would move under the
  # reader; it is read again with the list.
  defp touch_views(%{assigns: %{summary_window: :closed}} = socket) do
    %{current_scope: scope, filters: filters} = socket.assigns
    Process.send_after(self(), :summary_window_over, @summary_window)

    socket
    |> assign(:summary_window, :open)
    |> start_async(:views, fn -> %{filters: filters, views: Runs.view_counts(scope, filters)} end)
  end

  defp touch_views(socket), do: assign(socket, :summary_window, :dirty)

  defp touch_preview(%{assigns: %{preview_window: :closed}} = socket) do
    Process.send_after(self(), :preview_window_over, @preview_window)
    socket |> assign(:preview_window, :open) |> reload_preview()
  end

  defp touch_preview(socket), do: assign(socket, :preview_window, :dirty)

  defp load(socket) do
    %{current_scope: scope, filters: filters} = socket.assigns

    if connected?(socket) do
      facets_opts = [narrow: socket.assigns.narrow, limits: socket.assigns.limits]
      rail_opts = rail_opts(socket)

      # The task does not inherit the process's locale: what `Apiary.Runs` names in it
      # (a facet's option) is named in the workspace's domain all the same.
      start_async(socket, :load, fn ->
        ApiaryWeb.Lingo.with_locale(scope, fn ->
          now = DateTime.utc_now()
          listing = Runs.page_runs(scope, filters, now)

          %{
            filters: filters,
            at: now,
            listing: listing,
            views: Runs.view_counts(scope, filters, now),
            rail: Runs.target_counts(scope, filters, [now: now] ++ rail_opts),
            facets: Runs.run_facets(scope, filters, [now: now] ++ facets_opts),
            shared: Runs.shared_paths(scope),
            workspace_runs: if(listing.total == 0, do: Runs.count_runs(scope))
          }
        end)
      end)
    else
      socket
    end
  end

  defp load_facets(socket) do
    %{current_scope: scope, filters: filters, narrow: narrow, limits: limits} = socket.assigns
    key = facet_key(socket)

    start_async(socket, :facets, fn ->
      ApiaryWeb.Lingo.with_locale(scope, fn ->
        %{
          filters: filters,
          key: key,
          facets: Runs.run_facets(scope, filters, narrow: narrow, limits: limits)
        }
      end)
    end)
  end

  defp facet_key(socket), do: {socket.assigns.narrow, socket.assigns.limits}

  defp load_rail(socket) do
    %{current_scope: scope, filters: filters} = socket.assigns
    key = rail_key(socket)
    opts = rail_opts(socket)

    start_async(socket, :rail, fn ->
      %{filters: filters, key: key, rail: Runs.target_counts(scope, filters, opts)}
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

  ## The preview

  # Which run the preview shows: the one the URL chose, else the page's first; none below
  # 1920 px, where there is no pane to show it in.
  defp show_preview(socket) do
    %{wide: wide, chosen: chosen, listing: listing} = socket.assigns

    id =
      cond do
        not wide -> nil
        chosen -> chosen
        listing && listing.runs != [] -> hd(listing.runs).run_id
        true -> nil
      end

    cond do
      is_nil(id) ->
        assign(socket, preview_on: false, preview_id: nil, preview: nil)

      id == socket.assigns.preview_id ->
        assign(socket, :preview_on, true)

      true ->
        socket
        |> assign(preview_on: true, preview_id: id, preview: nil)
        |> reload_preview()
    end
  end

  defp reload_preview(%{assigns: %{preview_id: nil}} = socket), do: socket

  defp reload_preview(socket) do
    %{current_scope: scope, preview_id: id, listing: listing} = socket.assigns
    on_page = listing && Enum.find(listing.runs, &(&1.run_id == id))

    start_async(socket, :preview, fn ->
      # A row's run can be a moment behind the record: the preview reads it again.
      run =
        case on_page do
          %{} = run ->
            Record.reload(scope, run)

          nil ->
            case Record.fetch_run(scope, id) do
              {:ok, run} -> run
              :error -> nil
            end
        end

      %{id: id, preview: run && preview_of(scope, run)}
    end)
  end

  defp preview_of(scope, run) do
    denials =
      if run.denied_count > 0,
        do: Record.connections(scope, run, decision: "denied"),
        else: %{rows: [], total: 0}

    %{
      run: run,
      quiet: not is_nil(quiet_for(run)),
      lines: Record.log_tail(scope, run, @preview_lines),
      denials: Enum.take(denials.rows, @preview_denials),
      more_denials: max(denials.total - @preview_denials, 0)
    }
  end

  defp assign_preview_quiet(%{assigns: %{preview: %{run: run} = preview}} = socket) do
    quiet = not is_nil(quiet_for(run))

    if quiet == preview.quiet,
      do: socket,
      else: assign(socket, :preview, %{preview | quiet: quiet})
  end

  defp assign_preview_quiet(socket), do: socket

  # Assigned only when the set changes: the seconds tick in the browser.
  defp assign_quiet(%{assigns: %{listing: nil}} = socket), do: socket

  defp assign_quiet(socket) do
    now = DateTime.utc_now()

    quiet =
      for run <- socket.assigns.listing.runs, quiet_for(run, now), into: MapSet.new(), do: run.id

    if quiet == socket.assigns.quiet_ids, do: socket, else: assign(socket, :quiet_ids, quiet)
  end

  ## Words and paths

  # A notice of a rewritten link or a refused word stays for the view it led to, and goes
  # with the reader's next change.
  defp keep_notices(socket) do
    if socket.private[:notice_kept],
      do: put_private(socket, :notice_kept, false),
      else: assign(socket, dropped: [], refused: [])
  end

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

  defp page_path(scope, %Filters{} = filters, run \\ nil) do
    params = Filters.to_params(filters)
    params = if run, do: Map.put(params, "run", run), else: params
    ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{params}"
  end

  # A run's id as the URL may carry it, the id the runner prints.
  defp run_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp run_id(_value), do: nil

  # No run in the workspace at all, and nothing narrowing the view: the first-run states.
  defp first_run?(%{total: 0}, filters), do: not Filters.any?(filters)
  defp first_run?(_listing, _filters), do: false

  defp hidden_sentence(n) do
    ngettext("%{number} run is hidden by them.", "%{number} runs are hidden by them.", n,
      number: Format.number(n)
    )
  end

  # The views: every run, the alive ones, the ones that ended badly, the ones with
  # denials; each sets the states and the denials and keeps every other filter.
  defp view_list(filters) do
    alive = Filters.family_states("alive")
    badly = Filters.family_states("ended_badly")

    [
      %{key: "all", label: gettext("All"), count: :all, states: [], denials: false},
      %{key: "alive", label: gettext("Alive"), count: :alive, states: alive, denials: false},
      %{
        key: "ended-badly",
        label: gettext("Ended badly"),
        count: :ended_badly,
        states: badly,
        denials: false
      },
      %{
        key: "denials",
        label: gettext("With denials"),
        count: :with_denials,
        states: [],
        denials: true
      }
    ]
    |> Enum.map(fn view ->
      Map.merge(view, %{
        filters: Filters.put(filters, states: view.states, denials: view.denials),
        current: filters.states == view.states and filters.denials == view.denials
      })
    end)
    |> then(fn views ->
      # States that are no view's, or states and denials together, are narrowed from
      # every run: All is the view, and the tokens say the rest.
      if Enum.any?(views, & &1.current),
        do: views,
        else: List.update_at(views, 0, &%{&1 | current: true})
    end)
  end

  # The filters as tokens in the query field, less the ones the current view says.
  defp tokens(scope, filters, shared) do
    except =
      if filters.states != [] and Enum.any?(tl(view_list(filters)), & &1.current),
        do: [:state],
        else: []

    except = if filters.denials and filters.states == [], do: [:denied | except], else: except

    filters
    |> Filters.tokens(except: except, target_text: &target_text(&1, shared))
    |> Enum.map(fn token ->
      %{
        id: "runs-token-#{token.key}",
        qualifier: qualifier(token.key),
        value: token.value,
        remove: page_path(scope, token.without)
      }
    end)
  end

  defp last_token(scope, filters, shared), do: scope |> tokens(filters, shared) |> List.last()

  defp qualifier(:target), do: pgettext("qualifier", "target")
  defp qualifier(key), do: Atom.to_string(key)

  # The Target section's options in the one notation of a target.
  defp target_options(facets, shared) do
    for {label, value, count} <- facet_options(facets, :target) do
      case Jason.decode(value) do
        {:ok, [system, path]} -> {target_text({system, path}, shared), value, count}
        _none -> {label, value, count}
      end
    end
  end

  # A target as the query writes it: its system before its path only where the path is on
  # more than one system, as every page writes a target.
  defp target_text(:none, _shared), do: "none"
  defp target_text({nil, path}, _shared), do: path

  defp target_text({system, path}, shared),
    do: if(MapSet.member?(shared, path), do: "#{system}/#{path}", else: path)

  defp text_sections do
    [
      {"task", gettext("Task"), "hero-command-line-micro"},
      {"runtime", gettext("Runtime"), "hero-cpu-chip-micro"},
      {"host", gettext("Host"), "hero-server-stack-micro"},
      {"key", gettext("Access key"), "hero-key-micro"}
    ]
  end

  defp text_param(filters, "task"), do: task_param(filters.task)
  defp text_param(filters, "runtime"), do: filters.runtime
  defp text_param(filters, "host"), do: filters.host
  defp text_param(filters, "key"), do: filters.key

  defp text_value(filters, "task"), do: task_label(filters.task)
  defp text_value(filters, name), do: text_param(filters, name)

  defp sort_label("newest"), do: gettext("Newest")
  defp sort_label("oldest"), do: gettext("Oldest")
  defp sort_label("longest"), do: gettext("Longest")
  defp sort_label("denials"), do: gettext("Most denials")

  defp sort_name("newest"), do: gettext("newest first")
  defp sort_name("oldest"), do: gettext("oldest first")
  defp sort_name("longest"), do: gettext("longest first")
  defp sort_name("denials"), do: gettext("most denials first")

  defp previous_label("newest"), do: gettext("Newer")
  defp previous_label("oldest"), do: gettext("Older")
  defp previous_label(_sort), do: gettext("Previous")

  defp next_label("newest"), do: gettext("Older")
  defp next_label("oldest"), do: gettext("Newer")
  defp next_label(_sort), do: gettext("Next")

  # Every state, in its family's order, with its count under the other filters; a state no
  # run has shows without a count, so the section keeps its shape from one view to the next.
  defp state_options(facets) do
    counts =
      for {state, _value, count} <- facet_options(facets, :state), into: %{}, do: {state, count}

    for family <- Filters.families(),
        state <- family.states,
        do: {state_label(state), state, counts[state]}
  end

  # The section's headings: the family's checkbox reads its label and is named for a screen
  # reader as the sentence of the brief ("Every alive state").
  defp state_groups do
    for family <- Filters.families() do
      %{
        key: family.key,
        label: family.label,
        name: family_checkbox_name(family.key),
        states: family.states
      }
    end
  end

  defp family_checkbox_name("alive"), do: gettext("Every alive state")
  defp family_checkbox_name("ended_well"), do: gettext("Every state that ended well")
  defp family_checkbox_name("ended_badly"), do: gettext("Every state that ended badly")

  defp state_tips do
    tip = Enum.map_join(@closed_menu_tip, " ", &Gettext.gettext(ApiaryWeb.Gettext, &1))
    %{"closed" => tip}
  end

  # The chosen states as family words when they are whole families ("ended badly", "alive,
  # ended badly"); nil otherwise.
  defp family_words(states) do
    case Filters.families_of(states) do
      nil -> nil
      keys -> Enum.map_join(keys, ", ", &family_word/1)
    end
  end

  defp state_words(states), do: Enum.map_join(states, ", ", &state_label/1)

  defp family_word("alive"), do: gettext("alive")
  defp family_word("ended_well"), do: gettext("ended well")
  defp family_word("ended_badly"), do: gettext("ended badly")

  # The funnel empty state's title: the family in the sentence when the states are exactly
  # one family ("No runs ended badly in the last 7 days."), the plain title otherwise.
  defp empty_title(%Filters{states: states} = filters) do
    case Filters.families_of(states) do
      [key] -> empty_family_title(key, Filters.range_phrase(filters))
      _other -> gettext("No runs match these filters")
    end
  end

  defp empty_family_title("alive", nil), do: gettext("No runs alive.")
  defp empty_family_title("ended_well", nil), do: gettext("No runs ended well.")
  defp empty_family_title("ended_badly", nil), do: gettext("No runs ended badly.")

  defp empty_family_title("alive", range),
    do: gettext("No runs alive %{range}.", range: range)

  defp empty_family_title("ended_well", range),
    do: gettext("No runs ended well %{range}.", range: range)

  defp empty_family_title("ended_badly", range),
    do: gettext("No runs ended badly %{range}.", range: range)

  defp facet_options(facets, name), do: (facets[name] || %{options: []}).options
  defp facet_total(facets, name), do: facets[name] && facets[name].total

  # A chosen value that the data no longer offers still shows in its section, so it can be
  # read.
  defp with_chosen(options, nil, _label), do: options || []

  defp with_chosen(options, value, label) do
    options = options || []

    if Enum.any?(options, fn {_label, v, _count} -> v == value end),
      do: options,
      else: [{label, value, 0} | options]
  end

  defp task_param(:none), do: "none"
  defp task_param(task), do: task

  defp task_label(:none), do: gettext("No task")
  defp task_label(task), do: task

  defp range_value(%Filters{from: nil, to: nil, since: since}), do: since
  defp range_value(%Filters{}), do: nil
end
