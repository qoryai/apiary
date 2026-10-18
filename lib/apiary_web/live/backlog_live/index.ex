defmodule ApiaryWeb.BacklogLive.Index do
  # A workspace's Backlog: the tickets of the repositories assigned to it (`:index`).
  #
  # **The head.** Under the title, while the page lists tickets, a line says where they
  # come from: "Tickets from the 41 repositories assigned to Main. Take one in to make it
  # a work item." The count is of the live repositories assigned to the workspace,
  # whatever their Backlog switch. It and what follows it link to the integration's page
  # in Organisation settings › Integrations, by its adapter's public id, when one
  # integration connects the organisation (`Apiary.Sources.Backlog.backlog_facts/1`);
  # with several, the words are not a link.
  #
  # **The list.** The views as tabs, each with its count (Open, Taken in, Declined,
  # Closed), with a line under them on Closed, and on Declined where one integration
  # connects the organisation, that says which tickets it holds, Search,
  # one Filter menu (Repository, Filed by, its bots each with a neutral tile, Label,
  # Updated), Sort (Recently updated, Newest, Most comments), the filters in force as
  # tokens under the bar, each with its ×, then Clear and how many tickets match, a page
  # of rows (`BacklogComponents.ticket_row/1`, each with its integration's tile), and the
  # pager, Newer and Older. Everything the list shows is in the address, so a narrowed
  # list can be linked and Back works:
  # `view`, `q`, `repository`, `filed_by`, `label`, `updated`, `sort`, and a page's
  # cursor, `after` or `before`. The page hands each to
  # `Apiary.Sources.Backlog.list_tickets/3`, which checks it: a value it does not know
  # matches nothing, or is its default, and breaks nothing. A repository is named by Qory
  # Apiary's id for it and a ticket by Qory Apiary's id for it (`tk_…`), never by the
  # source's id, number or ref.
  #
  # **The words for the items** are their source's
  # (`Apiary.Adapters.workspace_item_noun/1`, `ApiaryWeb.SourceComponents.items/1`),
  # "tickets" where it names none, and so are the words for its collections, the Filter
  # menu's section of them included (`Apiary.Adapters.workspace_collection_noun/1`,
  # `ApiaryWeb.SourceComponents.collections/1`), "repositories" where it names none.
  #
  # **Live.** The page listens on the topic of its workspace's Backlog
  # (`Apiary.Sources.Backlog.subscribe/1`). A message carries ids only: the page reads its
  # page, its counts, the filters' values and the facts of its head again with its scope,
  # and never shows what a message says.
  #
  # The ticket over the list (`?ticket=`), Take in and the empty states are later steps of
  # this page: a row's link puts the ticket's id in the address, and the page draws
  # nothing for it yet; a Backlog with no ticket draws nothing under the page's header.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  alias Apiary.Adapters
  alias Apiary.Runs.Filters
  alias Apiary.Sources.Backlog
  alias ApiaryWeb.{BacklogComponents, SourceComponents}

  @views [:open, :taken, :declined, :closed]
  @most_values 100
  @sorts [:updated, :created, :comments]
  @lists [:repository, :filed_by, :label]
  @filters @lists ++ [:updated]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:backlog}
    >
      <:crumb>{gettext("Backlog")}</:crumb>

      <.page_header title={gettext("Backlog")}>
        <:description :if={@page && !empty_backlog?(@page, @params)}>
          <.rich text={sub_line(@item_noun, assigned(assigns))} />
        </:description>
      </.page_header>

      <div :if={@page && !empty_backlog?(@page, @params)} id="backlog" class="q-bl">
        <div class="q-bl-main flex flex-col gap-3">
          <div id="backlog-bar" class="q-bar">
            <.views id="backlog-views" label={gettext("Views")}>
              <:view
                :for={view <- views()}
                id={"backlog-view-#{view}"}
                patch={list_path(@current_scope, @params, view: view)}
                current={@params.view == view}
                count={Format.number(Map.fetch!(@page.counts, view))}
              >
                {view_label(view)}
              </:view>
            </.views>
            <span class="q-grow"></span>
            <.list_search
              id="backlog-search"
              label={gettext("Search the backlog")}
              placeholder={gettext("Search %{items}", items: SourceComponents.items(@item_noun))}
              value={@params.q}
            />
            <.filter_menu id="backlog-filter" count={Enum.count(filters(), &on?(@params, &1))}>
              <:section
                :for={key <- lists()}
                key={Atom.to_string(key)}
                label={filter_label(key, @collection_noun)}
                icon={filter_icon(key)}
                value={value_words(@params, key, @options)}
              >
                <.filter_options
                  id={"backlog-filter-#{key}"}
                  name={Atom.to_string(key)}
                  label={filter_label(key, @collection_noun)}
                  multiple
                  values={Map.fetch!(@params, key)}
                  options={options(@options, @narrowed, @params, key)}
                  query={@narrow[Atom.to_string(key)]}
                  search_label={key == :filed_by && gettext("Find a name")}
                  always_find={key == :filed_by}
                >
                  <:tile :let={{_label, value, _count}} :if={key == :filed_by}>
                    <BacklogComponents.bot_tile
                      :if={bot?(@options, @narrowed, value)}
                      name={value}
                    />
                  </:tile>
                </.filter_options>
              </:section>
              <:section
                key="updated"
                label={filter_label(:updated, @collection_noun)}
                icon={filter_icon(:updated)}
                value={value_words(@params, :updated, @options)}
              >
                <.filter_options
                  id="backlog-filter-updated"
                  name="updated"
                  label={filter_label(:updated, @collection_noun)}
                  values={List.wrap(@params.updated)}
                  options={for {label, value} <- Filters.windows(), do: {label, value, nil}}
                />
              </:section>
            </.filter_menu>
            <.sort_menu
              id="backlog-sort"
              current={sort_label(@params.sort)}
              label={gettext("Sort")}
            >
              <.menu_heading title={gettext("Sort by")} />
              <.menu_item
                :for={sort <- sorts()}
                id={"backlog-sort-#{sort}"}
                patch={list_path(@current_scope, @params, sort: sort)}
                checked={@params.sort == sort}
              >
                {sort_label(sort)}
              </.menu_item>
            </.sort_menu>
          </div>

          <%!-- Always there, so a screen reader hears what a search or a filter
               left. --%>
          <div id="backlog-status" role="status" class="q-status">
            <.filter_tokens
              id="backlog-tokens"
              clear={
                list_path(@current_scope, @params,
                  repository: [],
                  filed_by: [],
                  label: [],
                  updated: nil
                )
              }
            >
              <:token
                :for={token <- tokens(@params, @options, @collection_noun)}
                id={"backlog-token-#{token.key}"}
                patch={token.remove && list_path(@current_scope, @params, [{token.key, nil}])}
                label={token.remove}
              >
                <span class="q-tok-k">{token.label}</span>
                <b class={["q-tok-v", token.key == :repository && "q-mono"]} title={token.value}>
                  {token.value}
                </b>
              </:token>
              <span id="backlog-match" class="ml-auto text-[0.8125rem] text-muted tabular-nums">
                {match_words(@page, @params, @item_noun)}
              </span>
            </.filter_tokens>
            <p
              :if={@params.q && tokens(@params, @options, @collection_noun) == []}
              id="backlog-match"
              class="text-[0.8125rem] text-muted tabular-nums"
            >
              {match_words(@page, @params, @item_noun)}
            </p>
          </div>

          <p
            :if={@params.view == :closed}
            id="backlog-view-line"
            class="text-[0.8125rem] text-muted"
          >
            {gettext("%{items} that closed after they reached the backlog.",
              items: SourceComponents.items_label(@item_noun)
            )}
          </p>

          <p
            :if={@params.view == :declined and @integration}
            id="backlog-view-line"
            class="text-[0.8125rem] text-muted"
          >
            {gettext(
              "%{items} whose work item a member declined after Explore. They stay open on %{integration}, and Open leaves them out. Take in again brings back the same work item.",
              items: SourceComponents.items_label(@item_noun),
              integration: @integration.name
            )}
          </p>

          <section :if={@row_count > 0} id="backlog-list" class="q-blk">
            <ul id="backlog-rows" class="q-rows" phx-update="stream">
              <BacklogComponents.ticket_row
                :for={{dom_id, ticket} <- @streams.tickets}
                id={dom_id}
                ticket={ticket}
                integration={ticket.integration.name}
                patch={list_path(@current_scope, @params, ticket: ticket.id)}
                now={@now}
              />
            </ul>
          </section>

          <.pager
            :if={@page.prev || @page.next}
            id="backlog-pager"
            prefix="backlog-pager"
            first={@page.first}
            last={@page.first + @row_count - 1}
            total={Map.fetch!(@page.counts, @params.view)}
            previous={@page.prev && list_path(@current_scope, @params, before: @page.prev)}
            next={@page.next && list_path(@current_scope, @params, after: @page.next)}
            previous_label={gettext("Newer")}
            next_label={gettext("Older")}
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
    if connected?(socket), do: Backlog.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Backlog"),
       item_noun: Adapters.workspace_item_noun(scope),
       collection_noun: Adapters.workspace_collection_noun(scope),
       params: nil,
       page: nil,
       row_count: 0,
       now: DateTime.utc_now(),
       narrow: %{},
       narrowed: %{}
     )
     |> load_options()
     |> load_facts()
     |> stream_configure(:tickets, dom_id: &"ticket-#{&1.id}")
     |> stream(:tickets, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:params, read(params)) |> load()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) when is_binary(q),
    do: {:noreply, push_patch(socket, to: list_path(socket, q: q))}

  def handle_event("search", _params, socket), do: {:noreply, socket}

  # A section of the Filter menu sent its values: the boxes ticked, or the window chosen.
  def handle_event("filter", %{"_filter" => name} = params, socket) do
    case filter_key(name) do
      nil ->
        {:noreply, socket}

      :updated ->
        {:noreply, push_patch(socket, to: list_path(socket, updated: one(params[name])))}

      key ->
        {:noreply, push_patch(socket, to: list_path(socket, [{key, many(params[name])}]))}
    end
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  # "Find a name", and the box above the other sections' values: the values of that
  # section that hold the words, searched on the server.
  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket) when is_binary(q) do
    case filter_key(name) do
      key when key in @lists ->
        values = Backlog.filter_values(socket.assigns.current_scope, key, q)

        {:noreply,
         socket
         |> update(:narrow, &Map.put(&1, name, q))
         |> update(:narrowed, &Map.put(&1, key, values))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  # A ticket of the workspace's Backlog was written, ended, closed or taken in: the page
  # reads what it shows again, with its scope, whatever the message names.
  @impl true
  def handle_info({:tickets_changed, _ids}, socket),
    do: {:noreply, socket |> load_options() |> load_facts() |> load()}

  ## Reads

  # The page of the list the params name, with its counts, read with the page's scope.
  defp load(socket) do
    params = socket.assigns.params
    now = DateTime.utc_now()
    page = Backlog.list_tickets(socket.assigns.current_scope, query(params), now)

    socket
    |> assign(page: page, row_count: length(page.rows), now: now)
    |> stream(:tickets, page.rows, reset: true)
  end

  # What each filter offers, most tickets first; and a section's narrowed values, read
  # again with the words it was narrowed by.
  defp load_options(socket) do
    scope = socket.assigns.current_scope
    options = Map.new(@lists, &{&1, Backlog.filter_values(scope, &1, nil)})

    narrowed =
      Map.new(socket.assigns.narrowed, fn {key, _values} ->
        {key, Backlog.filter_values(scope, key, socket.assigns.narrow[Atom.to_string(key)])}
      end)

    assign(socket, options: options, narrowed: narrowed)
  end

  # The facts the head speaks from, and the integration its line links: the one that
  # connects the organisation, or nil where none or several do.
  defp load_facts(socket) do
    facts = Backlog.backlog_facts(socket.assigns.current_scope)

    integration =
      case facts.integrations do
        [integration] -> integration
        _none_or_several -> nil
      end

    assign(socket, facts: facts, integration: integration)
  end

  # What `Apiary.Sources.Backlog.list_tickets/3` is asked: the params as the address has
  # them, which it checks; a filter with no value is none.
  defp query(params) do
    %{
      view: params.view,
      search: params.search,
      repository: none_if_empty(params.repository),
      filed_by: none_if_empty(params.filed_by),
      label: none_if_empty(params.label),
      updated: params.updated,
      sort: params.sort,
      after: params.after,
      before: params.before
    }
  end

  defp none_if_empty([]), do: nil
  defp none_if_empty(values), do: values

  ## The address

  # The params of the address. A filter's values are a list of strings; a value that is
  # not a string is one that matches nothing (`""` in a list, `:invalid` alone), shown as
  # nothing. `q` is the search as the field shows it, `search` what is searched: a search
  # that is not a string matches nothing (`Apiary.Sources.Backlog.list_tickets/3`).
  defp read(params) do
    q = params["q"]

    %{
      view: choice(params["view"], @views, :open),
      q: if(is_binary(q) and String.trim(q) != "", do: q),
      search: if(not is_binary(q) or String.trim(q) != "", do: q),
      repository: many(params["repository"]),
      filed_by: many(params["filed_by"]),
      label: many(params["label"]),
      updated: one(params["updated"]),
      sort: choice(params["sort"], @sorts, :updated),
      after: one(params["after"]),
      before: one(params["before"])
    }
  end

  defp choice(value, choices, default),
    do: Enum.find(choices, default, &(Atom.to_string(&1) == value))

  defp many(nil), do: []
  defp many(""), do: []
  defp many(value) when is_binary(value), do: [value]

  # A filter's list is read to its first 100 values, as many as the Backlog matches on,
  # so a longer list in an address is not drawn in full, as checked values and in its
  # token.
  defp many(values) when is_list(values) do
    values
    |> Enum.take(@most_values)
    |> Enum.map(fn value -> if is_binary(value), do: value, else: "" end)
  end

  defp many(_value), do: [""]

  defp one(nil), do: nil
  defp one(""), do: nil
  defp one(value) when is_binary(value), do: value
  defp one(_value), do: :invalid

  # The list with `changes` made to the params, of the socket or given: a change of the
  # view, the search, a filter or the order shows the first page; `after:` and `before:`
  # name a page; `ticket:` the ticket open over the list.
  defp list_path(%Phoenix.LiveView.Socket{} = socket, changes),
    do: list_path(socket.assigns.current_scope, socket.assigns.params, changes)

  defp list_path(scope, params, changes) do
    changes = Map.new(changes)

    params =
      params
      |> Map.merge(%{after: nil, before: nil})
      |> Map.merge(Map.delete(changes, :ticket))

    query =
      Enum.reject(
        [
          view: params.view != :open && params.view,
          q: params.q,
          repository: params.repository,
          filed_by: params.filed_by,
          label: params.label,
          updated: params.updated,
          sort: params.sort != :updated && params.sort,
          after: params.after,
          before: params.before,
          ticket: changes[:ticket]
        ],
        fn {_key, value} -> value in [nil, false, [], ""] end
      )

    ~p"/#{scope.organisation}/#{scope.workspace}/backlog?#{query}"
  end

  ## What the page says

  defp views, do: @views
  defp sorts, do: @sorts
  defp lists, do: @lists
  defp filters, do: @filters

  defp view_label(:open), do: pgettext("backlog view", "Open")
  defp view_label(:taken), do: gettext("Taken in")
  defp view_label(:declined), do: gettext("Declined")
  defp view_label(:closed), do: gettext("Closed")

  defp sort_label(:updated), do: gettext("Recently updated")
  defp sort_label(:created), do: gettext("Newest")
  defp sort_label(:comments), do: gettext("Most comments")

  # A filter's name; the collections' is in their source's word for one of them.
  defp filter_label(:repository, collection_noun),
    do: SourceComponents.collection_label(collection_noun)

  defp filter_label(:filed_by, _collection_noun), do: gettext("Filed by")
  defp filter_label(:label, _collection_noun), do: gettext("Label")
  defp filter_label(:updated, _collection_noun), do: gettext("Updated")

  defp filter_icon(:repository), do: "hero-folder"
  defp filter_icon(:filed_by), do: "hero-user-circle"
  defp filter_icon(:label), do: "hero-tag"
  defp filter_icon(:updated), do: "hero-calendar"

  defp filter_key("repository"), do: :repository
  defp filter_key("filed_by"), do: :filed_by
  defp filter_key("label"), do: :label
  defp filter_key("updated"), do: :updated
  defp filter_key(_name), do: nil

  defp on?(params, :updated), do: not is_nil(params.updated)
  defp on?(params, key), do: Map.fetch!(params, key) != []

  # A Backlog with no ticket at all, under no search and no filter: its empty states are a
  # later step, so the page draws nothing under its header.
  defp empty_backlog?(page, params),
    do:
      page.counts.total == 0 and is_nil(params.search) and
        not Enum.any?(@filters, &on?(params, &1))

  # A section's values as `filter_options/1` takes them, `{label, value, count}`: the
  # values narrowed by its search, or else those with the most tickets, then each chosen
  # value that neither holds, so that every chosen one shows ticked.
  defp options(options, narrowed, params, key) do
    offered = Map.get(narrowed, key) || Map.fetch!(options, key)
    keys = MapSet.new(offered, & &1.key)

    Enum.map(offered, &{&1.label, &1.key, &1.count}) ++
      for value <- Map.fetch!(params, key),
          not MapSet.member?(keys, value),
          do: {words(options, key, value), value, nil}
  end

  # A filter's value as the page says it: a repository by its title, a filer's name or a
  # label as it is, a window by its words; a value that is not a string as nothing.
  defp words(options, :repository, id),
    do: Enum.find_value(Map.fetch!(options, :repository), id, &(&1.key == id && &1.label))

  defp words(_options, :updated, :invalid), do: ""

  defp words(_options, :updated, window),
    do:
      Enum.find_value(Filters.windows(), window, fn {label, value} -> value == window && label end)

  defp words(_options, _key, value), do: value

  # What a filter is set to, in the Filter menu and on its token: nil where it is off.
  defp value_words(params, key, options) do
    cond do
      not on?(params, key) -> nil
      key == :updated -> words(options, :updated, params.updated)
      true -> params |> Map.fetch!(key) |> Enum.map_join(", ", &words(options, key, &1))
    end
  end

  # The tokens of the filters in force, in the Filter menu's order: what each keeps, and
  # what taking it away says to a screen reader; nil where the page has no words for that,
  # so that token goes with Clear.
  defp tokens(params, options, collection_noun) do
    for key <- @filters, on?(params, key) do
      %{
        key: key,
        label: filter_label(key, collection_noun),
        value: value_words(params, key, options),
        remove: remove_words(key)
      }
    end
  end

  defp remove_words(:repository), do: gettext("Remove the collection filter")
  defp remove_words(:filed_by), do: gettext("Remove the filed-by filter")
  defp remove_words(:label), do: gettext("Remove the label filter")
  defp remove_words(:updated), do: gettext("Remove the updated filter")

  # Whether a value of Filed by is a bot's: one no person filed a ticket under, as the
  # values offered or narrowed say.
  defp bot?(options, narrowed, name) do
    [Map.fetch!(options, :filed_by), Map.get(narrowed, :filed_by, [])]
    |> Enum.concat()
    |> Enum.any?(&(&1.key == name and &1.avatar == :bot))
  end

  # The line under the title: where the tickets come from, with the count and what follows
  # it (`assigned/1`) a link to the integration.
  defp sub_line(item_noun, assigned),
    do:
      rich_gettext("%{items} from the %{assigned}. Take one in to make it a work item.",
        items: SourceComponents.items_label(item_noun),
        assigned: assigned
      )

  # "41 repositories assigned to Main": a link to the integration's page in Organisation
  # settings › Integrations where one integration connects the organisation, else words.
  defp assigned(%{integration: nil} = assigns),
    do: assigned_words(assigns.current_scope, assigns.facts, assigns.collection_noun)

  defp assigned(assigns) do
    assigns =
      assign(assigns,
        words: assigned_words(assigns.current_scope, assigns.facts, assigns.collection_noun),
        title:
          gettext("Organisation settings › Integrations › %{integration}",
            integration: assigns.integration.name
          )
      )

    ~H"""
    <.link
      id="backlog-integration"
      navigate={~p"/#{@current_scope.organisation}/settings/integrations/#{@integration.id}"}
      title={@title}
    >{@words}</.link>
    """
  end

  # "41 repositories assigned to Main", in the source's words for its collections.
  defp assigned_words(scope, facts, collection_noun) do
    n = facts.assigned_collections

    ngettext(
      "%{number} %{collection} assigned to %{workspace}",
      "%{number} %{collections} assigned to %{workspace}",
      n,
      number: Format.number(n),
      collection: SourceComponents.collection(collection_noun),
      collections: SourceComponents.collections(collection_noun),
      workspace: scope.workspace.name
    )
  end

  defp match_words(page, params, item_noun) do
    n = Map.fetch!(page.counts, params.view)

    ngettext("%{number} %{item} matches", "%{number} %{items} match", n,
      number: Format.number(n),
      item: SourceComponents.item(item_noun),
      items: SourceComponents.items(item_noun)
    )
  end
end
