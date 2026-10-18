defmodule ApiaryWeb.AdapterLive.Show do
  # An integration's page in Organisation settings › Integrations (`:collections`), by its
  # adapter's public id (`na_…`), for whoever may read the instance's adapters in the
  # organisation (`adapter.read`, members), behind the `factory` feature. Its settings and
  # its keys are the instance admins' (`ApiaryWeb.InstanceLive.Adapter`,
  # `ApiaryWeb.AdapterLive.AccessKey`). An adapter the person does not find is a path that
  # does not exist.
  #
  # Under the integration's name, where the organisation's connection to it stands
  # (`Apiary.Adapters.Connections`):
  #
  #   * not installed: no connection, a pending one whose latest pass came back refused
  #     or cancelled, which the return's flash says why, or one started before today;
  #   * ended: with no connection, the latest one, once connected, ended because the
  #     integration reported the installation gone: on which day, and, once a listing
  #     named it, for an adapter with items, that the items it brought in left every
  #     backlog while the work items taken in stay, in the adapter's words for its items.
  #     One that ended before it connected is not installed;
  #   * pending, started today, its pass still good: who started the install and when,
  #     and that it may be finished on the integration or started again; with the pass
  #     expired, that it expired. Both say to press Install, so whoever may not connect
  #     one, and has no Install, reads not installed;
  #   * installed: who installed it and when, then its collections, the section's heading
  #     in the adapter's words. Until the adapter's first listing names the connection, a
  #     line says the page waits for the integration to send them; a minute after the page
  #     opened so, it says to install again if nothing appears, beside Install.
  #
  # Once a listing names the connection, its collections are a table, a page of them at a
  # time (`Apiary.Adapters.Collections.list_collections/3`), by title: each one's
  # workspace, or Unassigned, its open items, for an adapter with items, and when it was
  # added. Until a listing of the connection is complete, a line says the integration is
  # still sending them, with how many so far; then the heading says how many there are.
  # A lead says what being assigned means, in the adapter's words for its collections
  # and its items: with one workspace, that every one is assigned to it; for an adapter
  # with no items, only that each is assigned to one workspace. The lead and the foot note
  # show while the page waits too. Past a page, the pager walks the pages, from the first,
  # as the list pages by the row before (`?page=`). Ended collections are not shown: the
  # counts leave them out too. A search finds collections by their names (`?q=`).
  #
  # With several workspaces, the lead says that each is assigned to one workspace and, for
  # an adapter with items, that their items come into that workspace's backlog while their
  # Backlog switches are on. Once a listing is complete, a warning says how many are
  # unassigned, and, for an adapter with items, that their items reach no backlog until
  # they are assigned, by the person or by an owner or an admin. Views over the table
  # show every one or the unassigned ones (`?view=unassigned`), the warning's Show them
  # leads to the second, and a menu keeps those of one workspace (`?workspace_id=`).
  # Whoever may assign them (`collection.assign`, owners and admins) selects rows, of
  # those shown, then picks a workspace from the selection's menu, Assign to workspace
  # (`Apiary.Adapters.Collections.assign_collections/4`); a flash says what went where.
  # Before anything is selected, the menu's button shows disabled. While a listing is
  # still arriving, nothing can be selected, and there is no warning, view or filter.
  #
  # While it is not installed, the install block follows
  # (`ApiaryWeb.IntegrationComponents`), to whoever may connect one (`adapter.connect`,
  # owners and admins), whose Install posts to the Install path, as the line to install
  # again does. The page follows the organisation's connections and collections as they
  # change (`Apiary.Adapters.Collections.subscribe/1`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, Adapters}
  alias Apiary.Adapters.{Collections, Connection, Connections}
  alias Apiary.Organisations

  alias ApiaryWeb.{
    IntegrationComponents,
    People,
    RunComponents,
    SettingsComponents,
    SourceComponents
  }

  # How long the page waits for the first listing before it says to install again.
  @late_after :timer.minutes(1)

  @impl true
  def mount(%{"adapter_id" => adapter_id}, _session, socket) do
    scope = socket.assigns.current_scope
    adapter = Adapters.get_adapter(scope, adapter_id) || raise(ApiaryWeb.NotFound)

    if connected?(socket), do: :ok = Collections.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: IntegrationComponents.page_title(scope, [adapter.name]),
       sections: SettingsComponents.sections(scope, :organisation),
       paths: IntegrationComponents.paths(scope, adapter),
       adapter: adapter,
       connects: Access.can?(scope, :"adapter.connect", scope.organisation),
       may_assign: Access.can?(scope, :"collection.assign", scope.organisation),
       selected: %{},
       menu_q: nil,
       late: false,
       timer: nil,
       sending: false,
       query: %{page: 1, view: :all, q: nil, workspace: nil},
       lead: nil
     )
     |> load()}
  end

  # The collections the address asks for: the page (`?page=`, from 1), the view
  # (`?view=unassigned`), the search (`?q=`) and the workspace (`?workspace_id=`, its id).
  @impl true
  def handle_params(params, _uri, socket) do
    query = %{
      page: page_param(params["page"]),
      view: if(params["view"] == "unassigned", do: :unassigned, else: :all),
      q: search_param(params["q"]),
      workspace: if(is_binary(params["workspace_id"]), do: params["workspace_id"])
    }

    {:noreply, socket |> assign(:query, query) |> listing()}
  end

  defp search_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp search_param(_value), do: nil

  defp page_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 1 -> page
      _other -> 1
    end
  end

  defp page_param(_value), do: 1

  # The connection as it stands, the state it puts the page in, and who started it.
  defp load(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns
    connection = Map.get(Connections.live_by_adapter(scope), adapter.id)
    ended = if is_nil(connection), do: Connections.latest_ended(scope, adapter)
    state = if reported_gone?(ended), do: :ended, else: state(connection)

    person =
      connection &&
        People.member(People.accounts([connection.created_by_id]), connection.created_by_id)

    socket
    |> assign(connection: connection, ended: ended, state: state, person: person)
    |> assign(:ready, IntegrationComponents.ready?(adapter))
    |> wait()
  end

  # Starts the minute the page waits for the first listing, once, as the page opens in
  # that state or comes to it; `timer` keeps the minute's timer.
  defp wait(%{assigns: %{state: :waiting, timer: nil}} = socket) do
    if connected?(socket) do
      assign(socket, :timer, Process.send_after(self(), :late, @late_after))
    else
      socket
    end
  end

  defp wait(socket), do: socket

  # The organisation's latest connection to the adapter, once connected, ended because
  # the adapter said the installation was gone.
  defp reported_gone?(%Connection{ended_reason: :adapter_reported, connected_at: %DateTime{}}),
    do: true

  defp reported_gone?(_ended), do: false

  defp state(nil), do: :not_installed

  defp state(%Connection{state: :connected, listed_at: nil}), do: :waiting
  defp state(%Connection{state: :connected}), do: :listed

  defp state(%Connection{state: :pending, pass_nonce_used_at: nil} = connection) do
    cond do
      not today?(connection.updated_at) -> :not_installed
      is_nil(connection.pass_expires_at) -> :not_installed
      DateTime.compare(connection.pass_expires_at, DateTime.utc_now()) == :gt -> :pending
      true -> :expired
    end
  end

  defp state(%Connection{}), do: :not_installed

  defp today?(at), do: DateTime.to_date(Format.local(at)) == Format.today()

  # Install, pressed while the page offers it: the form then posts to Install's path.
  @impl true
  def handle_event("install", _params, socket) do
    %{connects: connects, ready: ready, state: state, late: late} = socket.assigns

    if connects and ready and (state in [:not_installed, :pending, :expired, :ended] or late),
      do: {:noreply, assign(socket, :sending, true)},
      else: {:noreply, socket}
  end

  def handle_event("search", %{"q" => q}, socket) do
    query = %{socket.assigns.query | q: search_param(q), page: 1}
    {:noreply, push_patch(socket, to: page_path(socket.assigns.paths.show, query))}
  end

  def handle_event("select", %{"collection" => public_id}, %{assigns: %{picks: true}} = socket) do
    %{rows: rows, selected: selected} = socket.assigns

    case Enum.find(rows, &(&1.public_id == public_id)) do
      nil ->
        {:noreply, socket}

      %{id: id} = row ->
        selected =
          if Map.has_key?(selected, id),
            do: Map.delete(selected, id),
            else: Map.put(selected, id, row.name)

        {:noreply, assign(socket, :selected, selected)}
    end
  end

  def handle_event("select_all", _params, %{assigns: %{picks: true}} = socket) do
    %{rows: rows, selected: selected} = socket.assigns
    shown = Map.new(rows, &{&1.id, &1.name})

    selected =
      if map_size(shown) > 0 and Enum.all?(Map.keys(shown), &Map.has_key?(selected, &1)),
        do: Map.drop(selected, Map.keys(shown)),
        else: Map.merge(selected, shown)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, assign(socket, :selected, %{})}

  # The assign menu's field: the workspaces whose names hold its text.
  def handle_event("find_workspace", %{"q" => q}, socket),
    do: {:noreply, assign(socket, :menu_q, search_param(q))}

  # Assigns the selection to the workspace picked from the menu, then says what went
  # where. A refusal (the connection ended, a workspace or a collection gone meanwhile)
  # leaves the page as it now stands.
  def handle_event("assign", %{"workspace" => id}, %{assigns: %{picks: true}} = socket) do
    %{current_scope: scope, connection: connection, selected: selected} = socket.assigns
    workspace = Enum.find(socket.assigns.workspaces, &(&1.id == id))

    socket =
      with true <- map_size(selected) > 0,
           %{} <- workspace || {:error, :not_found},
           {:ok, _changed} <-
             Collections.assign_collections(scope, connection, Map.keys(selected), workspace) do
        put_flash(
          socket,
          :info,
          assigned(socket.assigns.adapter, Map.values(selected), workspace)
        )
      else
        false -> socket
        {:error, reason} -> put_flash(socket, :error, refused(socket.assigns, reason))
      end

    {:noreply, socket |> assign(selected: %{}, menu_q: nil) |> reload()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:late, socket) do
    {:noreply, assign(socket, :late, socket.assigns.state == :waiting)}
  end

  def handle_info({:connection_changed, %{adapter_id: id}}, socket)
      when id == socket.assigns.adapter.id,
      do: {:noreply, reload(socket)}

  def handle_info({:collections_changed, %{connection_id: id}}, socket) do
    case socket.assigns.connection do
      %Connection{id: ^id} -> {:noreply, reload(socket)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The adapter and its connection read again; an adapter deleted meanwhile leaves for the
  # list.
  defp reload(socket) do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    case Adapters.get_adapter(scope, adapter.public_id) do
      nil -> push_navigate(socket, to: paths.list)
      adapter -> socket |> assign(:adapter, adapter) |> load() |> listing()
    end
  end

  # The organisation's workspaces, while installed, for what the lead says; once a listing
  # names the connection, the counts, whether a listing is complete, and the page of rows
  # the query asks for.
  defp listing(%{assigns: %{state: state}} = socket) when state in [:waiting, :listed] do
    %{current_scope: scope, adapter: adapter} = socket.assigns
    workspaces = Organisations.list_workspaces(scope)
    socket = assign(socket, workspaces: workspaces, lead: lead(scope, adapter, workspaces))
    if state == :listed, do: rows(socket), else: socket
  end

  defp listing(socket), do: assign(socket, :lead, nil)

  defp rows(socket) do
    %{current_scope: scope, connection: connection, workspaces: workspaces} = socket.assigns
    counts = Collections.counts(scope, connection)
    complete = Collections.listing_complete?(connection)
    several = complete and length(workspaces) > 1
    query = narrow(socket.assigns.query, several, workspaces)

    opts =
      for {key, value} <- [view: query.view, search: query.q, workspace: query.workspace],
          value != nil,
          do: {key, value}

    {page, rows, before, last?} = walk(scope, connection, opts, query.page)

    total =
      cond do
        query.q && last? -> before + length(rows)
        query.q -> found(scope, connection, opts)
        query.view == :unassigned -> counts.unassigned
        query.workspace -> Map.get(counts.by_workspace, query.workspace, 0)
        true -> counts.total
      end

    shown = Map.new(rows, &{&1.id, &1.name})

    assign(socket,
      counts: counts,
      complete: complete,
      several: several,
      picks: several and socket.assigns.may_assign,
      query: query,
      rows: rows,
      selected: Map.take(socket.assigns.selected, Map.keys(shown)),
      pager: %{
        page: page,
        first: before + 1,
        last: before + length(rows),
        total: total,
        previous: page > 1,
        next: before + length(rows) < total
      }
    )
  end

  # The query as the page can show it: the views and the workspace filter only with
  # several workspaces once a listing is complete, the workspace one of the organisation's
  # and in the view of every collection.
  defp narrow(query, several, workspaces) do
    workspace =
      several && query.view == :all && Enum.find(workspaces, &(&1.id == query.workspace))

    %{
      query
      | view: if(several, do: query.view, else: :all),
        workspace: if(workspace, do: workspace.id)
    }
  end

  # The page `page` of the connection's live collections `opts` asks for, walked to a page
  # at a time from the first, as the list pages by the row before; the last page there is,
  # if `page` is past it. `{page, its live rows, how many live rows the pages before it
  # hold, whether it is the last}`.
  defp walk(scope, connection, opts, page) do
    size = Collections.page_size()

    Enum.reduce_while(1..page//1, {nil, 0}, fn n, {after_id, before} ->
      raw = Collections.list_collections(scope, connection, [after: after_id] ++ opts)
      rows = Enum.filter(raw, &is_nil(&1.ended_at))

      if n == page or length(raw) < size,
        do: {:halt, {n, rows, before, length(raw) < size}},
        else: {:cont, {List.last(raw).public_id, before + length(rows)}}
    end)
  end

  # How many live collections of the connection `opts` finds, every page walked.
  defp found(scope, connection, opts, after_id \\ nil, count \\ 0) do
    raw = Collections.list_collections(scope, connection, [after: after_id] ++ opts)
    count = count + Enum.count(raw, &is_nil(&1.ended_at))

    if length(raw) < Collections.page_size(),
      do: count,
      else: found(scope, connection, opts, List.last(raw).public_id, count)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:integrations}
    >
      <:crumb title={@adapter.name}>{@adapter.name}</:crumb>

      <.settings_page
        section={:integrations}
        title={@adapter.name}
        measure={if @state in [:waiting, :listed], do: "list", else: "read"}
      >
        <:subtitle>
          <span id="integration-status">{status(assigns)}</span>
        </:subtitle>

        <IntegrationComponents.install_block
          :if={@connects && @state in [:not_installed, :pending, :expired, :ended]}
          id="integration-install"
          adapter={@adapter}
          organisation={@current_scope.organisation}
          collections={collection_word(@adapter, :other)}
          named={false}
          action={@paths.install}
          ready={@ready}
          sending={@sending}
        />

        <section
          :if={@state in [:waiting, :listed]}
          id="collections"
          aria-labelledby="collections-heading"
        >
          <h2
            id="collections-heading"
            class="mt-2 mb-1.5 flex items-baseline gap-2 text-sm/5 font-semibold"
          >
            {collection_label(@adapter)}
            <span
              :if={@state == :listed && @complete}
              id="collections-total"
              class="text-xs font-medium text-faint tabular-nums"
            >
              {Format.number(@counts.total)}
            </span>
          </h2>
          <p
            :if={@state == :waiting}
            id="collections-waiting"
            role="status"
            class="mb-3 text-[13.5px]/5"
          >
            <span class="q-sdot q-sdot-running">
              <i aria-hidden="true"></i><span>{gettext(
                "Waiting for %{integration} to send its %{collections}…",
                integration: @adapter.name,
                collections: collection_word(@adapter, :other)
              )}</span>
            </span>
          </p>
          <div
            :if={@state == :waiting && @late && @connects}
            id="collections-late"
            class="mb-3 flex flex-wrap items-center gap-2.5 text-[13.5px] text-muted"
          >
            <span>{gettext("If nothing appears, install again.")}</span>
            <IntegrationComponents.install_form
              id="collections-install"
              adapter={@adapter}
              action={@paths.install}
              ready={@ready}
              sending={@sending}
              variant="default"
              size="xs"
            />
          </div>
          <p
            :if={@state == :listed && !@complete}
            id="collections-filling"
            role="status"
            class="mb-3 text-[13.5px]/5"
          >
            <span class="q-sdot q-sdot-running">
              <i aria-hidden="true"></i><span>{gettext(
                "%{integration} is still sending its %{collections}…",
                integration: @adapter.name,
                collections: collection_word(@adapter, :other)
              )}</span>
            </span>
          </p>
          <p :if={@lead} id="collections-lead" class="mb-3 max-w-[80ch] text-[13.5px]/5 text-muted">
            {@lead}
          </p>

          <.notice
            :if={@state == :listed && @several && @counts.unassigned > 0}
            kind={:warning}
            class="mb-3"
          >
            <div id="collections-unassigned" class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
              <span>{unassigned_words(@adapter, @counts.unassigned, @may_assign)}</span>
              <.link
                :if={@may_assign && @query.view != :unassigned && @selected == %{}}
                id="collections-show-unassigned"
                patch={page_path(@paths.show, %{@query | view: :unassigned, workspace: nil, page: 1})}
                class="ml-auto font-medium whitespace-nowrap underline underline-offset-2"
              >
                {gettext("Show them")}
              </.link>
            </div>
          </.notice>

          <div :if={@state == :listed} id="collections-bar" class="q-bar mb-3">
            <%= if @selected != %{} do %>
              <div
                id="collections-selection"
                class="q-int-selbar"
                role="toolbar"
                aria-labelledby="collections-selected"
              >
                <span id="collections-selected">
                  {ngettext("%{number} selected", "%{number} selected", map_size(@selected),
                    number: Format.number(map_size(@selected))
                  )}
                </span>
                <IntegrationComponents.assign_menu
                  id="collections-assign"
                  heading={
                    ngettext(
                      "Assign %{number} %{collection} to",
                      "Assign %{number} %{collections} to",
                      map_size(@selected),
                      number: Format.number(map_size(@selected)),
                      collection: collection_word(@adapter, 1),
                      collections: collection_word(@adapter, :other)
                    )
                  }
                  find={length(@workspaces) > 8}
                  query={@menu_q}
                  workspaces={
                    for workspace <- @workspaces, named?(workspace, @menu_q) do
                      {workspace,
                       count_words(@adapter, true, Map.get(@counts.by_workspace, workspace.id, 0))}
                    end
                  }
                  foot={
                    Adapters.items?(@adapter) &&
                      ngettext(
                        "Its %{items} go with it. Work items already taken in stay where they are.",
                        "Their %{items} go with them. Work items already taken in stay where they are.",
                        map_size(@selected),
                        items: SourceComponents.items(Adapters.item_noun(@adapter))
                      )
                  }
                />
                <button
                  id="collections-clear"
                  type="button"
                  class="btn btn-ghost btn-sm q-int-clear"
                  phx-click="clear_selection"
                  aria-label={gettext("Clear selection")}
                >
                  <.icon name="hero-x-mark-micro" class="size-4" /><span class="q-int-clear-l">{gettext(
                    "Clear selection"
                  )}</span>
                </button>
              </div>
              <span class="q-grow"></span>
              <span id="collections-count" class="q-int-count">
                {gettext("%{shown} of %{total} shown",
                  shown: Format.number(length(@rows)),
                  total: Format.number(@counts.total)
                )}
              </span>
            <% else %>
              <.views :if={@several} id="collections-views" label={gettext("Views")}>
                <:view
                  id="collections-view-all"
                  patch={page_path(@paths.show, %{@query | view: :all, workspace: nil, page: 1})}
                  count={Format.number(@counts.total)}
                  current={@query.view == :all}
                >
                  {gettext("All")}
                </:view>
                <:view
                  id="collections-view-unassigned"
                  patch={
                    page_path(@paths.show, %{@query | view: :unassigned, workspace: nil, page: 1})
                  }
                  count={Format.number(@counts.unassigned)}
                  current={@query.view == :unassigned}
                >
                  {gettext("Unassigned")}
                </:view>
              </.views>
              <span :if={@several} class="q-grow"></span>
              <.list_search
                id="collections-search"
                label={gettext("Find a %{collection}", collection: collection_word(@adapter, 1))}
                value={@query.q}
              />
              <IntegrationComponents.workspace_filter
                :if={@several}
                id="collections-workspace"
                options={
                  for workspace <- @workspaces do
                    chosen = @query.workspace == workspace.id

                    {workspace.name,
                     page_path(@paths.show, %{
                       @query
                       | view: :all,
                         workspace: if(!chosen, do: workspace.id),
                         page: 1
                     }), chosen}
                  end
                }
              />
              <span :if={@picks} class="contents">
                <button
                  id="collections-assign-button"
                  type="button"
                  class="btn btn-sm"
                  disabled
                  title={
                    gettext("Select %{collections} to assign them",
                      collections: collection_word(@adapter, :other)
                    )
                  }
                  aria-describedby="collections-assign-hint"
                >
                  {gettext("Assign to workspace")}<.icon
                    name="hero-chevron-down-micro"
                    class="size-4"
                  />
                </button>
                <span id="collections-assign-hint" class="sr-only">
                  {gettext("Select %{collections} to assign them",
                    collections: collection_word(@adapter, :other)
                  )}
                </span>
              </span>
              <span :if={!@several} class="q-grow"></span>
              <span :if={!@several} id="collections-count" class="q-int-count">
                {count_words(@adapter, @complete, @counts.total)}
              </span>
            <% end %>
          </div>

          <IntegrationComponents.collections_table
            :if={@state == :listed}
            id="collections-table"
            label={collection_label(@adapter)}
            rows={@rows}
            column={collection_label(@adapter, 1)}
            open={
              Adapters.items?(@adapter) &&
                gettext("Open %{items}", items: SourceComponents.items(Adapters.item_noun(@adapter)))
            }
            picks={@picks}
            selected={@selected}
            every={
              gettext("Select every %{collection} shown", collection: collection_word(@adapter, 1))
            }
            none={
              @query.q && @query.page == 1 &&
                gettext("No %{collections} match “%{search}”.",
                  collections: collection_word(@adapter, :other),
                  search: @query.q
                )
            }
          />

          <RunComponents.pager
            :if={@state == :listed && (@pager.previous || @pager.next)}
            id="collections-pager"
            prefix="collections-pager"
            first={@pager.first}
            last={@pager.last}
            total={@pager.total}
            previous={@pager.previous && page_path(@paths.show, %{@query | page: @pager.page - 1})}
            next={@pager.next && page_path(@paths.show, %{@query | page: @pager.page + 1})}
            previous_label={gettext("Previous")}
            next_label={gettext("Next")}
          />

          <div class="mt-3 grid gap-1.5">
            <p id="collections-targets" class="q-foot-note">
              {gettext(
                "Assigning a %{collection} here doesn't change a workspace's Targets, which list what its runs change.",
                collection: collection_word(@adapter, 1)
              )}
            </p>
          </div>
        </section>
      </.settings_page>
    </Layouts.app>
    """
  end

  # The line under the name: where the connection stands.
  defp status(%{state: state} = assigns) when state in [:waiting, :listed] do
    at = assigns.connection.connected_at

    if today?(at),
      do: gettext("Installed by %{person} today.", person: assigns.person),
      else:
        gettext("Installed by %{person} on %{date}.",
          person: assigns.person,
          date: Format.day(at)
        )
  end

  defp status(%{state: state, connects: false}) when state in [:pending, :expired],
    do: gettext("Not installed.")

  defp status(%{state: :pending} = assigns) do
    gettext(
      "Not installed. %{person} started an install today at %{time} that isn't finished: finish it on %{integration}, or press Install to start again.",
      person: assigns.person,
      time: Format.time(assigns.connection.updated_at),
      integration: assigns.adapter.name
    )
  end

  defp status(%{state: :expired} = assigns) do
    gettext(
      "Not installed. %{person}'s install, started today at %{time}, expired before it was finished. Press Install to start again.",
      person: assigns.person,
      time: Format.time(assigns.connection.updated_at)
    )
  end

  defp status(%{state: :ended, ended: ended, adapter: adapter}) do
    gone =
      gettext(
        "Not installed. The installation ended on %{date}, when %{integration} reported it gone.",
        date: Format.day(ended.ended_at),
        integration: adapter.name
      )

    if ended.listed_at && Adapters.items?(adapter) do
      gone <>
        " " <>
        gettext(
          "The %{items} %{integration} brought in left every backlog; work items already taken in stay.",
          items: SourceComponents.items(Adapters.item_noun(adapter)),
          integration: adapter.name
        )
    else
      gone
    end
  end

  defp status(%{state: :not_installed}), do: gettext("Not installed.")

  # What being assigned means, above the table: for an adapter with no items, that each
  # collection is assigned to one workspace; with one workspace, that every one is
  # assigned to it, and its items come into that workspace's backlog; with several, that
  # each is assigned to one, and their items come into its backlog while their Backlog
  # switches are on.
  defp lead(scope, adapter, workspaces) do
    cond do
      not Adapters.items?(adapter) ->
        gettext("These %{collections} are each assigned to one workspace.",
          collections: collection_word(adapter, :other)
        )

      match?([_one], workspaces) ->
        [workspace] = workspaces

        gettext(
          "%{organisation} has one workspace, %{workspace}, so every %{collection} is assigned to it, and its %{items} come into %{workspace}'s backlog.",
          organisation: scope.organisation.name,
          workspace: workspace.name,
          collection: collection_word(adapter, 1),
          items: SourceComponents.items(Adapters.item_noun(adapter))
        )

      length(workspaces) > 1 ->
        gettext(
          "These %{collections} are each assigned to one workspace, and their %{items} come into that workspace's backlog while their Backlog switches are on.",
          collections: collection_word(adapter, :other),
          items: SourceComponents.items(Adapters.item_noun(adapter))
        )

      true ->
        nil
    end
  end

  # How many collections are unassigned, and, for an adapter with items, that their items
  # reach no backlog until they are assigned: by the person, who may assign them, or by an
  # owner or an admin.
  defp unassigned_words(adapter, number, may_assign) do
    words = [
      number: Format.number(number),
      collection: collection_word(adapter, 1),
      collections: collection_word(adapter, :other),
      items: SourceComponents.items(Adapters.item_noun(adapter))
    ]

    cond do
      not Adapters.items?(adapter) ->
        ngettext(
          "%{number} %{collection} is unassigned.",
          "%{number} %{collections} are unassigned.",
          number,
          words
        )

      may_assign ->
        ngettext(
          "%{number} %{collection} is unassigned. Its %{items} reach no backlog until you assign it to a workspace.",
          "%{number} %{collections} are unassigned. Their %{items} reach no backlog until you assign each to a workspace.",
          number,
          words
        )

      true ->
        ngettext(
          "%{number} %{collection} is unassigned. Its %{items} reach no backlog until an owner or an admin assigns it to a workspace.",
          "%{number} %{collections} are unassigned. Their %{items} reach no backlog until an owner or an admin assigns each to a workspace.",
          number,
          words
        )
    end
  end

  # The flash after assigning: the names of what went where, up to three, else how many.
  defp assigned(_adapter, names, workspace) when length(names) <= 3 do
    gettext("Assigned %{names} to %{workspace}.",
      names: names |> Enum.sort() |> join_names(),
      workspace: workspace.name
    )
  end

  defp assigned(adapter, names, workspace) do
    number = length(names)

    ngettext(
      "Assigned %{number} %{collection} to %{workspace}.",
      "Assigned %{number} %{collections} to %{workspace}.",
      number,
      number: Format.number(number),
      collection: collection_word(adapter, 1),
      collections: collection_word(adapter, :other),
      workspace: workspace.name
    )
  end

  # Whether the workspace's name holds `text`, any case; every one for none.
  defp named?(_workspace, nil), do: true

  defp named?(workspace, text),
    do: String.contains?(String.downcase(workspace.name), String.downcase(text))

  # The flash when an assign is refused: it assigns all or nothing, so nothing moved.
  # A workspace or a collection gone since the page was drawn, or a selection past the
  # most one assign takes, is the page out of date: it shows them anew.
  defp refused(%{current_scope: scope, adapter: adapter}, :forbidden) do
    gettext("Only owners and admins of %{organisation} assign %{collections}.",
      organisation: scope.organisation.name,
      collections: collection_word(adapter, :other)
    )
  end

  defp refused(%{adapter: adapter}, :ended),
    do:
      gettext("Nothing was assigned: the installation of %{integration} ended.",
        integration: adapter.name
      )

  defp refused(%{adapter: adapter}, reason) when reason in [:not_found, :invalid] do
    gettext(
      "Nothing was assigned: the page was out of date. It now shows the %{collections} as they are.",
      collections: collection_word(adapter, :other)
    )
  end

  defp join_names([name]), do: name

  defp join_names(names) do
    {list, [last]} = Enum.split(names, -1)
    gettext("%{list} and %{last}", list: Enum.join(list, ", "), last: last)
  end

  # The count beside the table: while a listing is still to complete, how many so far;
  # then how many the connection reaches.
  defp count_words(_adapter, false, total),
    do: ngettext("%{number} so far", "%{number} so far", total, number: Format.number(total))

  defp count_words(adapter, true, total) do
    ngettext("%{number} %{collection}", "%{number} %{collections}", total,
      number: Format.number(total),
      collection: collection_word(adapter, 1),
      collections: collection_word(adapter, :other)
    )
  end

  # The path of the integration's page with `query`, its defaults (the first page, every
  # collection, no search, no workspace) left out. The workspace goes as `workspace_id`,
  # since a `workspace` parameter names the path's workspace (`ApiaryWeb.UserAuth`).
  defp page_path(show, query) do
    params =
      for {key, name} <- [view: :view, q: :q, workspace: :workspace_id, page: :page],
          value = Map.get(query, key),
          value not in [nil, 1, :all],
          do: {name, value}

    case params do
      [] -> show
      params -> show <> "?" <> URI.encode_query(params)
    end
  end

  # The word for many of the adapter's collections (`:other`), or for one (1), its first
  # letter in upper case: the section's heading and the table's, and the column's.
  defp collection_label(adapter, n \\ :other) do
    {first, rest} = adapter |> collection_word(n) |> String.split_at(1)
    String.upcase(first) <> rest
  end

  # The word for many of the adapter's collections (`:other`), or for one (1): what it
  # calls them (`Apiary.Adapters.collection_noun/1`), else the domain's word.
  defp collection_word(adapter, n) do
    case {Adapters.collection_noun(adapter), n} do
      {%{one: one}, 1} -> one
      {%{other: other}, _n} -> other
      {nil, 1} -> pgettext("source collection, when its adapter names none", "collection")
      {nil, _n} -> pgettext("source collection, when its adapter names none", "collections")
    end
  end
end
