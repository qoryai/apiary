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
  #   * ended: with no connection, the latest one ended because the integration reported
  #     the installation gone: on which day, and, for an adapter with items, that the
  #     items it brought in left every backlog while the work items taken in stay, in the
  #     adapter's words for its items;
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
  # counts leave them out too.
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
       late: false,
       timer: false,
       sending: false,
       query: %{page: 1},
       lead: nil
     )
     |> load()}
  end

  # The page of the collections the address asks for (`?page=`, from 1).
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:query, %{page: page_param(params["page"])}) |> listing()}
  end

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
  # that state or comes to it.
  defp wait(%{assigns: %{state: :waiting, timer: false}} = socket) do
    if connected?(socket) do
      Process.send_after(self(), :late, @late_after)
      assign(socket, :timer, true)
    else
      socket
    end
  end

  defp wait(socket), do: socket

  # The organisation's latest connection to the adapter ended because the adapter said
  # the installation was gone.
  defp reported_gone?(%Connection{ended_reason: :adapter_reported}), do: true
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
    %{current_scope: scope, connection: connection, query: query} = socket.assigns
    counts = Collections.counts(scope, connection)
    total = counts.total
    {page, rows, before} = walk(scope, connection, [], query.page)

    assign(socket,
      counts: counts,
      complete: Collections.listing_complete?(connection),
      rows: rows,
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

  # The page `page` of the connection's live collections `opts` asks for, walked to a page
  # at a time from the first, as the list pages by the row before; the last page there is,
  # if `page` is past it. `{page, its live rows, how many live rows the pages before it
  # hold}`.
  defp walk(scope, connection, opts, page) do
    size = Collections.page_size()

    Enum.reduce_while(1..page//1, {nil, 0}, fn n, {after_id, before} ->
      raw = Collections.list_collections(scope, connection, [after: after_id] ++ opts)
      rows = Enum.filter(raw, &is_nil(&1.ended_at))

      if n == page or length(raw) < size,
        do: {:halt, {n, rows, before}},
        else: {:cont, {List.last(raw).public_id, before + length(rows)}}
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

          <div :if={@state == :listed} id="collections-bar" class="q-bar mb-3">
            <span class="q-grow"></span>
            <span id="collections-count" class="q-int-count">
              {count_words(@adapter, @complete, @counts.total)}
            </span>
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

    if Adapters.items?(adapter) do
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
  # assigned to it, and its items come into that workspace's backlog.
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

      true ->
        nil
    end
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

  # The path of the integration's page with `query`, its defaults left out.
  defp page_path(show, query) do
    case for({key, value} <- query, value not in [nil, 1], do: {key, value}) do
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
