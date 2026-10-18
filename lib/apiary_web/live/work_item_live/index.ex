defmodule ApiaryWeb.WorkItemLive.Index do
  # A workspace's Work items: the list (`:index`).
  #
  # **The list.** The page's head; the stages strip, Explore, Confirm and Shape, each with
  # its count and what in it needs a look, and a link to that stage alone; the views as
  # tabs, each with its count (Open, Waiting on you, Declined, Closed); Search; one Filter
  # menu (Owner, Repository, Updated); the filters in force as tokens under the bar with
  # Clear and how many work items match; the line of a view that needs one; and the rows
  # (`ApiaryWeb.WorkItemListComponents`). The Open view shows the stages as bands, each
  # with its first rows and Show all, a link to that stage alone; a stage alone, and every
  # other view, is a page of rows with the pager. A workspace with no work item, under no
  # search and no filter, shows why and how a work item starts.
  #
  # Everything the list shows is in the address, so a narrowed list can be linked and
  # Back works: `view`, `stage`, `q`, `owner`, `repository`, `updated`, and a page's
  # cursor, `after` or `before`. The page hands each to `Apiary.WorkItems`
  # (`list_work_items/3`, `list_bands/3`), which checks it: a value it does not know
  # matches nothing, or is its default, and breaks nothing. An owner is named by Qory
  # Apiary's id for the account, a work item's page by its number in the workspace, and a
  # row by Qory Apiary's id for the work item (`wi_…`).
  #
  # **Waiting on you** holds the live work items the reader owns whose proposal waits at
  # Confirm, oldest first; the sidebar counts the same
  # (`Apiary.WorkItems.count_waiting_on/1`).
  #
  # **Texts from an external system** (a ticket's title and key, a collection's title) are
  # shown as `ApiaryWeb.ExternalText` shows them.
  #
  # **Live.** The page listens on the topic of its workspace's work items
  # (`Apiary.WorkItems.subscribe/1`). A message carries ids only: the page reads its list,
  # its counts, the filters' values and the sidebar's count again with its scope, and
  # never shows what a message says.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  import ApiaryWeb.WorkItemListComponents

  alias Apiary.{Access, Adapters, ExternalText, WorkItems}
  alias Apiary.Runs.Filters
  alias Apiary.WorkItems.Explore
  alias ApiaryWeb.{People, UserAuth}

  @views [:open, :you, :declined, :closed]
  @stages [:explore, :confirm, :shape]
  @filters [:owner, :repository, :updated]
  @lists [:owner, :repository]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:work_items}
    >
      <:crumb>{gettext("Work items")}</:crumb>

      <%= if @list && empty?(@list, @params) do %>
        <.page_header title={gettext("Work items")} />
        <.work_items_empty backlog_path={backlog_path(@current_scope)} item_noun={@item_noun} />
      <% else %>
        <.work_items_head
          workspace={@current_scope.workspace.name}
          backlog_path={backlog_path(@current_scope)}
          item_noun={@item_noun}
        />

        <div :if={@list} id="work-items" class="q-wl flex flex-col gap-3">
          <.stages_strip
            counts={Map.take(@list.stages, stages())}
            exploring={@list.stages.exploring}
            answers={@list.stages.answers}
            no_result={@list.stages.no_result}
            waiting={@waiting}
            ready={@list.stages.ready}
            paths={stage_paths(@current_scope, @params)}
            item_noun={@item_noun}
          />

          <div id="work-items-bar" class="q-bar">
            <.work_item_views
              current={@params.view}
              counts={@list.counts}
              paths={view_paths(@current_scope, @params)}
            />
            <span class="q-grow"></span>
            <.work_item_search value={@params.q} item_noun={@item_noun} />
            <.work_item_filter
              count={Enum.count(filters(), &on?(@params, &1))}
              values={Map.new(filters(), &{&1, value_words(@params, &1, @options)})}
            >
              <:owner>
                <.filter_options
                  id="work-items-filter-owner"
                  name="owner"
                  label={pgettext("work item", "Owner")}
                  multiple
                  values={@params.owner}
                  options={options(@options, @narrowed, @params, :owner)}
                  query={@narrow["owner"]}
                  search_label={gettext("Find a name")}
                />
              </:owner>
              <:repository>
                <.filter_options
                  id="work-items-filter-repository"
                  name="repository"
                  label={pgettext("work item", "Repository")}
                  multiple
                  values={@params.repository}
                  options={options(@options, @narrowed, @params, :repository)}
                  query={@narrow["repository"]}
                />
              </:repository>
              <:updated>
                <.filter_options
                  id="work-items-filter-updated"
                  name="updated"
                  label={gettext("Updated")}
                  values={List.wrap(@params.updated)}
                  options={for {label, value} <- Filters.windows(), do: {label, value, nil}}
                />
              </:updated>
            </.work_item_filter>
          </div>

          <.work_item_tokens
            filters={tokens(@current_scope, @params, @options)}
            clear={list_path(@current_scope, @params, owner: [], repository: [], updated: nil)}
            match={total(@list, @params)}
          />

          <.view_note view={@params.view} item_noun={@item_noun} />

          <%= if @bands do %>
            <.stage_band
              :for={stage <- stages()}
              :if={Map.fetch!(@list.stages, stage) > 0}
              id={"work-items-#{stage}"}
              stage={stage}
              count={Map.fetch!(@list.stages, stage)}
              shown={length(Map.fetch!(@bands, stage))}
              exploring={@list.stages.exploring}
              answers={@list.stages.answers}
              no_result={@list.stages.no_result}
              waiting={@waiting}
              all_path={list_path(@current_scope, @params, view: :open, stage: stage)}
              item_noun={@item_noun}
            >
              <.rows
                rows={Map.fetch!(@bands, stage)}
                people={@people}
                scope={@current_scope}
                can_act={@can_act}
                now={@now}
              />
            </.stage_band>
          <% else %>
            <.stage_band
              :if={stage_alone?(@params) and @list.rows != []}
              id={"work-items-#{@params.stage}"}
              stage={@params.stage}
              count={Map.fetch!(@list.stages, @params.stage)}
              shown={length(@list.rows)}
              exploring={@list.stages.exploring}
              answers={@list.stages.answers}
              no_result={@list.stages.no_result}
              waiting={@waiting}
              item_noun={@item_noun}
            >
              <.rows
                rows={@list.rows}
                people={@people}
                scope={@current_scope}
                can_act={@can_act}
                now={@now}
              />
            </.stage_band>
            <ul :if={!stage_alone?(@params) and @list.rows != []} id="work-items-rows" class="q-rows">
              <.rows
                rows={@list.rows}
                people={@people}
                scope={@current_scope}
                can_act={@can_act}
                now={@now}
              />
            </ul>
            <.work_items_pager
              :if={@list.prev || @list.next}
              first={@list.first}
              last={@list.first + length(@list.rows) - 1}
              total={total(@list, @params)}
              previous={@list.prev && list_path(@current_scope, @params, before: @list.prev)}
              next={@list.next && list_path(@current_scope, @params, after: @list.next)}
            />
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :rows, :list, required: true
  attr :people, :map, required: true
  attr :scope, :any, required: true
  attr :can_act, :boolean, required: true
  attr :now, :any, required: true

  defp rows(assigns) do
    ~H"""
    <.work_item_row
      :for={row <- @rows}
      id={"work-item-#{row.id}"}
      work_item={work_item(row, @people, @scope)}
      integration={row.integration}
      navigate={work_item_path(@scope, row)}
      can_act={@can_act}
      now={@now}
    />
    """
  end

  ## Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: WorkItems.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Work items"),
       item_noun: Adapters.workspace_item_noun(scope),
       can_act: Access.can?(scope, :"work_item.answer", scope.workspace),
       params: nil,
       list: nil,
       bands: nil,
       people: %{},
       waiting: nil,
       now: DateTime.utc_now(),
       narrow: %{},
       narrowed: %{}
     )
     |> load_options()}
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

  # The box above a section's values: the repositories whose title holds the words,
  # searched on the server; the owners whose name holds them, among those offered.
  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket) when is_binary(q) do
    case filter_key(name) do
      key when key in @lists ->
        {:noreply,
         socket
         |> update(:narrow, &Map.put(&1, name, q))
         |> update(:narrowed, &Map.put(&1, key, narrowed(socket, key, q)))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  # Any other event, forged or from a page of before: nothing happens.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A work item of the workspace changed: the page reads its scope again first, as the
  # work item page does (`ApiaryWeb.UserAuth.reload_scope/1`), which sends away a reader
  # who may no longer be here; any other reads what it shows again, whatever the message
  # names, and the sidebar's count beside Work items.
  @impl true
  def handle_info({:work_items_changed, _ids}, socket) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      {:noreply, socket}
    else
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> assign(:can_act, Access.can?(scope, :"work_item.answer", scope.workspace))
       |> load_options()
       |> load()
       |> count_waiting_on()}
    end
  end

  ## Reads

  # The list the params name, with its counts, read with the page's scope: the Open view
  # by stage, or a page of rows; and the people its rows name.
  defp load(socket) do
    scope = socket.assigns.current_scope
    params = socket.assigns.params
    now = DateTime.utc_now()

    {list, bands} =
      if params.view == :open and is_nil(params.stage) do
        bands = WorkItems.list_bands(scope, query(params), now)
        {Map.merge(bands, %{rows: [], first: 1, next: nil, prev: nil}), bands.bands}
      else
        {WorkItems.list_work_items(scope, query(params), now), nil}
      end

    rows = list.rows ++ Enum.concat(Map.values(bands || %{}))
    people = people(scope, rows, socket.assigns.options.owner)

    assign(socket,
      list: list,
      bands: bands,
      people: people,
      now: now,
      waiting: waiting(list.stages, params, people)
    )
  end

  # What each filter offers, most work items first, the owners by name; and a section's
  # narrowed values, read again with the words it was narrowed by.
  defp load_options(socket) do
    scope = socket.assigns.current_scope
    owners = WorkItems.list_filter_values(scope, :owner)
    names = names(scope, Enum.map(owners, & &1.key))

    options = %{
      owner: Enum.map(owners, &%{key: &1.key, label: Map.fetch!(names, &1.key), count: &1.count}),
      repository: repositories(scope, nil)
    }

    socket = assign(socket, :options, options)

    narrowed =
      Map.new(socket.assigns.narrowed, fn {key, _values} ->
        {key, narrowed(socket, key, socket.assigns.narrow[Atom.to_string(key)])}
      end)

    assign(socket, :narrowed, narrowed)
  end

  defp repositories(scope, q) do
    for value <- WorkItems.list_filter_values(scope, :repository, q),
        do: %{key: value.key, label: ExternalText.line(value.key), count: value.count}
  end

  defp narrowed(socket, :repository, q), do: repositories(socket.assigns.current_scope, q)

  defp narrowed(socket, :owner, q) do
    words = q |> String.trim() |> String.downcase()
    Enum.filter(socket.assigns.options.owner, &String.contains?(String.downcase(&1.label), words))
  end

  # The sidebar's count beside Work items, read again: none at nought.
  defp count_waiting_on(socket) do
    count = WorkItems.count_waiting_on(socket.assigns.current_scope)
    counts = socket.assigns.nav_counts || %{}

    counts =
      if count > 0, do: Map.put(counts, :waiting_on, count), else: Map.delete(counts, :waiting_on)

    assign(socket, :nav_counts, counts)
  end

  # What `Apiary.WorkItems.list_work_items/3` is asked: the params as the address has
  # them, which it checks; a filter with no value is none.
  defp query(params) do
    %{
      view: params.view,
      stage: params.stage,
      search: params.search,
      owner: none_if_empty(params.owner),
      repository: none_if_empty(params.repository),
      updated: params.updated,
      after: params.after,
      before: params.before
    }
  end

  defp none_if_empty([]), do: nil
  defp none_if_empty(values), do: values

  ## People

  # The people the rows name, their owners and who ended them, by account id, with the
  # owners the Filter menu offers: `%{id => name}`.
  defp people(scope, rows, offered) do
    known = Map.new(offered, &{&1.key, &1.label})

    ids =
      rows
      |> Enum.flat_map(&[&1.owner_id, &1.ended_by_id])
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(known, &1)))
      |> Enum.uniq()

    Map.merge(known, names(scope, ids))
  end

  # The name of each person of `ids`, as the work item page names one: the local part of
  # the email address of a member of the organisation, "Former member" for a person who
  # is no longer one, a deleted account, or none.
  defp names(_scope, []), do: %{}

  defp names(scope, ids) do
    members = People.members(scope)
    Map.new(ids, &{&1, People.short(People.member(members, &1))})
  end

  defp person(_people, nil, _scope), do: nil

  defp person(people, id, scope),
    do: %{id: id, name: Map.get(people, id) || People.former_member(), you: id == scope.user.id}

  ## Rows

  # A row as the components draw a work item.
  defp work_item(row, people, scope) do
    %{
      number: row.number,
      title: row.title,
      key: row.key,
      repository: row.repository,
      status: status(row),
      stage: Explore.stage(row.status),
      run: if(row.of, do: %{attempt: row.attempt, of: row.of}),
      owner: person(people, row.owner_id, scope),
      ended_by: person(people, row.ended_by_id, scope),
      ended_at: row.ended_at,
      ended_reason: reason(row.ended_reason),
      updated_at: row.updated_at
    }
  end

  defp status(%{state: :exploring, status: status}), do: status
  defp status(%{state: state}), do: state

  defp reason("adapter_removed"), do: :adapter_removed
  defp reason(_reason), do: nil

  # What waits at Confirm, on the strip and Confirm's band: for the reader where any waits
  # for them, else for the one owner the list is filtered to, else for a member.
  defp waiting(%{waiting_you: n}, _params, _people) when n > 0, do: %{count: n, for: :you}

  defp waiting(%{waiting: n}, params, people) when n > 0 do
    case params.owner do
      [id] -> %{count: n, for: Map.get(people, id) || People.former_member()}
      _many -> %{count: n, for: :member}
    end
  end

  defp waiting(_stages, _params, _people), do: nil

  # Whether the list is one stage alone, a page of the Open view.
  defp stage_alone?(params), do: params.view == :open and params.stage in @stages

  # How many work items the list holds under its search and filters: the stage's, for a
  # stage alone, else the view's.
  defp total(list, params) do
    if stage_alone?(params),
      do: Map.fetch!(list.stages, params.stage),
      else: Map.fetch!(list.counts, params.view)
  end

  # A workspace with no work item at all, under no search and no filter.
  defp empty?(list, params),
    do:
      list.counts |> Map.values() |> Enum.sum() == 0 and is_nil(params.search) and
        not Enum.any?(@filters, &on?(params, &1))

  ## The address

  # The params of the address. A filter's values are a list of strings; a value that is
  # not a string is one that matches nothing (`""` in a list, `:invalid` alone), shown as
  # nothing. `q` is the search as the field shows it, `search` what is searched: a search
  # that is not a string matches nothing (`Apiary.WorkItems.list_work_items/3`). A stage
  # the page does not know matches nothing.
  defp read(params) do
    q = params["q"]

    %{
      view: choice(params["view"], @views, :open),
      stage: stage(params["stage"]),
      q: if(is_binary(q) and String.trim(q) != "", do: q),
      search: if(not is_binary(q) or String.trim(q) != "", do: q),
      owner: many(params["owner"]),
      repository: many(params["repository"]),
      updated: one(params["updated"]),
      after: one(params["after"]),
      before: one(params["before"])
    }
  end

  defp choice(value, choices, default),
    do: Enum.find(choices, default, &(Atom.to_string(&1) == value))

  defp stage(nil), do: nil
  defp stage(""), do: nil
  defp stage(value), do: Enum.find(@stages, :invalid, &(Atom.to_string(&1) == value))

  defp many(nil), do: []
  defp many(""), do: []
  defp many(value) when is_binary(value), do: [value]

  defp many(values) when is_list(values),
    do: Enum.map(values, fn value -> if is_binary(value), do: value, else: "" end)

  defp many(_value), do: [""]

  defp one(nil), do: nil
  defp one(""), do: nil
  defp one(value) when is_binary(value), do: value
  defp one(_value), do: :invalid

  # The list with `changes` made to the params, of the socket or given: a change of the
  # view, the stage, the search or a filter shows the first page; `after:` and `before:`
  # name a page.
  defp list_path(%Phoenix.LiveView.Socket{} = socket, changes),
    do: list_path(socket.assigns.current_scope, socket.assigns.params, changes)

  defp list_path(scope, params, changes) do
    params =
      params
      |> Map.merge(%{after: nil, before: nil})
      |> Map.merge(Map.new(changes))

    query =
      Enum.reject(
        [
          view: params.view != :open && params.view,
          stage: params.view == :open && params.stage,
          q: params.q,
          owner: params.owner,
          repository: params.repository,
          updated: params.updated,
          after: params.after,
          before: params.before
        ],
        fn {_key, value} -> value in [nil, false, [], "", :invalid] end
      )

    ~p"/#{scope.organisation}/#{scope.workspace}/work?#{query}"
  end

  defp stage_paths(scope, params),
    do: Map.new(@stages, &{&1, list_path(scope, params, view: :open, stage: &1)})

  defp view_paths(scope, params),
    do: Map.new(@views, &{&1, list_path(scope, params, view: &1, stage: nil)})

  defp backlog_path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog"

  defp work_item_path(scope, row),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{row.number}"

  ## What the page says

  defp stages, do: @stages
  defp filters, do: @filters

  defp filter_key("owner"), do: :owner
  defp filter_key("repository"), do: :repository
  defp filter_key("updated"), do: :updated
  defp filter_key(_name), do: nil

  defp on?(params, :updated), do: not is_nil(params.updated)
  defp on?(params, key), do: Map.fetch!(params, key) != []

  # A section's values as `filter_options/1` takes them, `{label, value, count}`: the
  # values narrowed by its search, or else those with the most work items, then each
  # chosen value that neither holds, so that every chosen one shows ticked.
  defp options(options, narrowed, params, key) do
    offered = Map.get(narrowed, key) || Map.fetch!(options, key)
    keys = MapSet.new(offered, & &1.key)

    Enum.map(offered, &{&1.label, &1.key, &1.count}) ++
      for value <- Map.fetch!(params, key),
          not MapSet.member?(keys, value),
          do: {words(options, key, value), value, nil}
  end

  # A filter's value as the page says it: an owner by name, a repository by its title, a
  # window by its words; a value that is not one as nothing.
  defp words(options, :owner, id),
    do: Enum.find_value(Map.fetch!(options, :owner), "", &(&1.key == id && &1.label))

  defp words(_options, :repository, title), do: ExternalText.line(title)
  defp words(_options, :updated, :invalid), do: ""

  defp words(_options, :updated, window),
    do:
      Enum.find_value(Filters.windows(), window, fn {label, value} -> value == window && label end)

  # What a filter is set to, in the Filter menu and on its token: nil where it is off.
  defp value_words(params, key, options) do
    cond do
      not on?(params, key) -> nil
      key == :updated -> words(options, :updated, params.updated)
      true -> params |> Map.fetch!(key) |> Enum.map_join(", ", &words(options, key, &1))
    end
  end

  # The tokens of the filters in force, in the Filter menu's order: what each keeps, and
  # the list without it.
  defp tokens(scope, params, options) do
    for key <- @filters, on?(params, key) do
      %{
        key: key,
        value: value_words(params, key, options),
        patch: list_path(scope, params, [{key, if(key == :updated, do: nil, else: [])}])
      }
    end
  end
end
