defmodule ApiaryWeb.ChooseCollectionsLive do
  # The chooser of the set-up's steps Work sources and Destinations, and of Workspace
  # settings › Work sources and › Destinations, with the `factory` feature:
  #
  #   * `/:org/set-up/choose?step=<sources|destinations>&grant=<ag_…>&workspace=<slug>`
  #     (`:set_up`), in the set-up's frame with the progress indicator, the step current;
  #   * `/:org/:workspace/settings/choose?step=<sources|destinations>&grant=<ag_…>`
  #     (`:settings`), in the workspace's settings, the step's section current.
  #
  # It chooses which collections of one grant (`Apiary.Adapters.Grant`) the workspace has
  # in the step's list (`ApiaryWeb.IntegrationComponents.chooser/1`):
  #
  #   * All: every collection of the grant that no other workspace has, and every one the
  #     adapter lists for the grant later (`Apiary.Adapters.GrantRule`);
  #   * Only selected: the collections ticked, a page of 50 at a time
  #     (`Apiary.Adapters.Collections.list_collections/3`, `?page=`), found by their names
  #     (`?q=`), with how many are selected. A row of another workspace has no checkbox
  #     and shows that workspace's name.
  #
  # The chooser opens on All while the grant's rule is the workspace's: chosen in Work
  # sources for Work sources, in either step for Destinations; else on Only selected, with
  # the collections chosen for the workspace ticked (`Apiary.Adapters.Collections.chosen_ids/3`).
  # While another workspace has the rule, the chooser has Only selected alone, and a line
  # that names that workspace. In Destinations, while the rule was chosen in Work sources,
  # it has All alone, and a line that says to change Work sources first. The selection is
  # kept in the page's process until Save, across pages and searches.
  #
  # Save sends the choice (`Apiary.Adapters.Collections.choose/5`) and returns to the
  # page the chooser opened from: the set-up's step (`:set_up`), or the settings' page of
  # the step's list (`:settings`); Back returns there without saving. A refusal leaves the page with the choice read
  # again and a flash that says why: who may, for a person `collection.assign` does not
  # allow, else that nothing changed. Not listed? shows the source's line on its access
  # (`Apiary.Integrations.Description.access/1`, as the adapter's latest start stored it),
  # as an external system's text, with Change access, Install for the connection, to a
  # person `adapter.connect` allows (`ApiaryWeb.IntegrationComponents.install_form/1`);
  # its return leads to the set-up's step (`ApiaryWeb.ConnectSession.back?/1`), from
  # either route.
  #
  # A grant the scope's organisation has no card for (`Apiary.WorkspaceSetup.card/5`), a
  # step that is neither, and a scope without a workspace are a path that does not exist.
  # Every member reads it (`adapter.read`); a person `collection.assign` does not allow
  # sees the choice disabled, no Save, and who may. The page listens to the organisation's
  # collections and connections (`Apiary.Adapters.Collections.subscribe/1`) and reads the
  # grant and its rule again on each change.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, Adapters, WorkspaceSetup}
  alias Apiary.Adapters.Collections
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.{IntegrationComponents, SettingsComponents, SetUpComponents, SourceComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      # Refused to a person who may not read the organisation's adapters, whom the page's
      # check has refused already.
      _subscribed = Collections.subscribe(scope)
    end

    {:ok,
     assign(socket,
       card: nil,
       list: nil,
       steps: nil,
       title: nil,
       sections: nil,
       section: nil,
       crumb: nil,
       selected: %{},
       mode: :only,
       sending: false,
       may: Access.can?(scope, :"collection.assign", scope.organisation),
       may_connect: Access.can?(scope, :"adapter.connect", scope.organisation)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    workspace = scope.workspace || raise(ApiaryWeb.NotFound)
    list = list_param(params["step"]) || raise(ApiaryWeb.NotFound)
    grant_id = params["grant"]

    socket =
      case socket.assigns do
        %{list: ^list, card: %{grant: %{public_id: ^grant_id}}} -> socket
        _other -> open(socket, workspace, list, grant_id)
      end

    query = %{page: page_param(params["page"]), q: search_param(params["q"])}
    {:noreply, socket |> assign(:query, query) |> rows()}
  end

  defp list_param("sources"), do: :sources
  defp list_param("destinations"), do: :destinations
  defp list_param(_step), do: nil

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

  # The grant's card, its frame, and the choice as it is saved.
  defp open(socket, workspace, list, grant_id) do
    scope = socket.assigns.current_scope
    domain = Domain.for_workspace(workspace)

    card =
      WorkspaceSetup.card(scope, domain, list, workspace, grant_id) || raise(ApiaryWeb.NotFound)

    socket
    |> assign(
      list: list,
      domain: domain,
      install:
        IntegrationComponents.paths(scope, card.adapter).install <>
          "?" <> URI.encode_query(back: "set-up:#{list}:workspace=#{workspace.slug}"),
      ready: IntegrationComponents.ready?(card.adapter),
      who_may: IntegrationComponents.who_assigns(scope, [card.adapter])
    )
    |> assign(frame(socket.assigns.live_action, scope, domain, workspace, list, card))
    |> saved(card)
  end

  # The page's frame, where Back and Save lead, and the browser title: the set-up's, with
  # its progress indicator; or the workspace's settings, the step's section current.
  defp frame(:set_up, scope, domain, workspace, list, card) do
    flow = SetUpComponents.flow(scope.organisation, domain, workspace, :set_up)

    [
      steps: SetUpComponents.steps_for(scope, list, flow: flow),
      title: SetUpComponents.flow_title(flow),
      back: SetUpComponents.flow_path(flow, list),
      page_title: heading(card)
    ]
  end

  defp frame(:settings, scope, _domain, workspace, list, card) do
    {section, title, back} =
      case list do
        :sources ->
          {:work_sources, gettext("Work sources"),
           ~p"/#{scope.organisation}/#{workspace}/settings/work-sources"}

        :destinations ->
          {:destinations, gettext("Destinations"),
           ~p"/#{scope.organisation}/#{workspace}/settings/destinations"}
      end

    [
      sections: SettingsComponents.sections(scope, :workspace),
      section: section,
      crumb: heading(card),
      back: back,
      page_title: SettingsComponents.page_title(scope, :workspace, [heading(card), title])
    ]
  end

  # The chooser's heading in plain words, as `IntegrationComponents.chooser/1` shows it:
  # the account name left out where `IntegrationComponents.account/1` has none.
  defp heading(card) do
    collections = SourceComponents.collections(Adapters.collection_noun(card.adapter))
    adapter = Adapters.title(card.adapter)

    case IntegrationComponents.account(card.grant) do
      nil ->
        gettext("Choose %{collections} · %{adapter}", collections: collections, adapter: adapter)

      account ->
        gettext("Choose %{collections} · %{adapter} · %{account}",
          collections: collections,
          adapter: adapter,
          account: Apiary.ExternalText.sent(account)
        )
    end
  end

  # The choice as the grant's rule and its collections stand: All or Only selected, and
  # the selection.
  defp saved(socket, card) do
    %{list: list, current_scope: %{workspace: workspace}} = socket.assigns
    all? = WorkspaceSetup.all?(card, list, workspace)

    socket
    |> assign(
      mode: if(all?, do: :all, else: :only),
      selected: Map.new(Collections.chosen_ids(card.grant, list, workspace), &{&1, true})
    )
    |> card(card)
  end

  # `card`, and what its rule says of the choice: another workspace's rule (`taken`), or
  # the workspace's rule chosen in Work sources, in Destinations (`locked`).
  defp card(socket, card) do
    %{list: list, current_scope: %{workspace: workspace}} = socket.assigns
    rule = card.rule
    taken = rule && rule.workspace_id != workspace.id && rule.workspace
    locked = list == :destinations and WorkspaceSetup.all?(card, :sources, workspace)

    mode =
      cond do
        locked -> :all
        taken -> :only
        true -> socket.assigns.mode
      end

    assign(socket, card: card, taken: taken || nil, locked: locked, mode: mode)
  end

  # The page of rows the query asks for, under Only selected, and its pager: from the
  # first page, as the list pages by the row before; the last page with rows, if the page
  # asked for is past it.
  defp rows(%{assigns: %{mode: :only}} = socket) do
    %{current_scope: scope, card: card, list: list, query: query} = socket.assigns
    opts = [grant: card.grant, list: list] ++ if(query.q, do: [search: query.q], else: [])
    {page, rows, before} = walk(scope, card.connection, opts, query.page)
    total = Collections.count_collections(scope, card.connection, opts)

    assign(socket,
      rows: rows,
      query: %{query | page: page},
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

  defp rows(socket),
    do:
      assign(socket,
        rows: [],
        pager: %{page: 1, first: 0, last: 0, total: 0, previous: false, next: false}
      )

  defp walk(scope, connection, opts, page) do
    Enum.reduce_while(1..page//1, {nil, 0, nil}, fn n, {after_id, before, previous} ->
      rows = Collections.list_collections(scope, connection, [after: after_id] ++ opts)
      last? = length(rows) < Collections.page_size()

      cond do
        rows == [] and previous != nil -> {:halt, previous}
        n == page or last? -> {:halt, {n, rows, before}}
        true -> {:cont, {List.last(rows).public_id, before + length(rows), {n, rows, before}}}
      end
    end)
  end

  # The chooser's path for `query`, its defaults (the first page, no search) left out.
  defp page_path(socket, query) do
    %{current_scope: scope, card: card, list: list} = socket.assigns

    rest =
      for {key, value} <- [q: query.q, page: query.page],
          value not in [nil, 1],
          do: {key, value}

    case socket.assigns.live_action do
      :set_up ->
        params = [step: list, grant: card.grant.public_id, workspace: scope.workspace.slug]
        ~p"/#{scope.organisation}/set-up/choose?#{params ++ rest}"

      :settings ->
        params = [step: list, grant: card.grant.public_id]
        ~p"/#{scope.organisation}/#{scope.workspace}/settings/choose?#{params ++ rest}"
    end
  end

  @impl true
  def handle_event("mode", %{"mode" => mode}, %{assigns: %{may: true}} = socket) do
    %{locked: locked, taken: taken} = socket.assigns

    mode =
      case mode do
        "all" when not is_struct(taken) -> :all
        "only" when not locked -> :only
        _other -> socket.assigns.mode
      end

    {:noreply, socket |> assign(:mode, mode) |> rows()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    query = %{socket.assigns.query | q: search_param(q), page: 1}
    {:noreply, push_patch(socket, to: page_path(socket, query))}
  end

  def handle_event("select", %{"collection" => public_id}, %{assigns: %{may: true}} = socket) do
    case Enum.find(socket.assigns.rows, &(&1.public_id == public_id and pickable?(socket, &1))) do
      nil ->
        {:noreply, socket}

      %{id: id} ->
        {:noreply,
         update(socket, :selected, fn selected ->
           if Map.has_key?(selected, id),
             do: Map.delete(selected, id),
             else: Map.put(selected, id, true)
         end)}
    end
  end

  def handle_event("select_all", _params, %{assigns: %{may: true}} = socket) do
    shown = for row <- socket.assigns.rows, pickable?(socket, row), do: row.id

    {:noreply,
     update(socket, :selected, fn selected ->
       if shown != [] and Enum.all?(shown, &Map.has_key?(selected, &1)),
         do: Map.drop(selected, shown),
         else: Map.merge(selected, Map.new(shown, &{&1, true}))
     end)}
  end

  def handle_event("save", _params, %{assigns: %{may: true}} = socket) do
    %{current_scope: scope, card: card, list: list, mode: mode, selected: selected} =
      socket.assigns

    choice = if mode == :all, do: :all, else: {:only, Map.keys(selected)}

    case Collections.choose(scope, card.grant, scope.workspace, list, choice) do
      {:ok, _count} ->
        {:noreply, push_navigate(socket, to: socket.assigns.back)}

      {:error, :forbidden} ->
        {:noreply,
         socket |> assign(:may, false) |> put_flash(:error, socket.assigns.who_may) |> reload()}

      {:error, _reason} ->
        {:noreply,
         socket |> put_flash(:error, gettext("Nothing was changed. Try again.")) |> reload()}
    end
  end

  # Install for the connection, pressed while the page offers it: the form then posts to
  # Install's path.
  def handle_event("install", _params, socket) do
    %{may_connect: may_connect, ready: ready} = socket.assigns

    if may_connect and ready and access(socket.assigns.card) != nil,
      do: {:noreply, assign(socket, :sending, true)},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A row of no workspace or of this one.
  defp pickable?(socket, %{workspace: workspace}),
    do: is_nil(workspace) or workspace.id == socket.assigns.current_scope.workspace.id

  @impl true
  def handle_info({event, _ids}, socket)
      when event in [:collections_changed, :connection_changed],
      do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The grant's card and its rule read again, the choice and the selection kept, and the
  # rows; a grant gone meanwhile returns to where Back leads.
  defp reload(socket) do
    %{current_scope: scope, domain: domain, list: list, card: card} = socket.assigns

    case WorkspaceSetup.card(scope, domain, list, scope.workspace, card.grant.public_id) do
      nil -> push_navigate(socket, to: socket.assigns.back)
      card -> socket |> card(card) |> rows()
    end
  end

  # The source's line on how to change which collections the adapter reaches, as stored;
  # nil without one, or for one with nothing left once shown, or only whitespace.
  defp access(%{adapter: %{source_access: text}}),
    do: if(Apiary.ExternalText.present(text), do: text)

  defp access(_card), do: nil

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        access: access(assigns.card),
        path: &page_path(%{assigns: assigns}, &1)
      )

    ~H"""
    <.page
      action={@live_action}
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      steps={@steps}
      title={@title}
      sections={@sections}
      section={@section}
      crumb={@crumb}
    >
      <IntegrationComponents.chooser
        id="choose"
        card={@card}
        mode={@mode}
        locked={@locked}
        taken={@taken}
        workspace={@current_scope.workspace}
        may={@may}
        who_may={@who_may}
        rows={@rows}
        selected={@selected}
        query={@query}
        pager={@pager}
        page_path={@path}
        back={@back}
        access={@access}
        may_connect={@may_connect}
        install={@install}
        ready={@ready}
        sending={@sending}
      />
    </.page>
    """
  end

  attr :action, :atom, required: true, values: [:set_up, :settings]
  attr :flash, :map, required: true
  attr :current_scope, :any, required: true
  attr :memberships, :list, required: true
  attr :counts, :any, required: true
  attr :steps, :list, doc: "the set-up's steps, for `:set_up`"
  attr :title, :string, doc: "the set-up's title, for `:set_up`"
  attr :sections, :list, doc: "the workspace's settings' sections, for `:settings`"
  attr :section, :atom, doc: "the step's section, for `:settings`"

  attr :crumb, :string,
    doc: "the chooser's heading, the breadcrumb's last segment, for `:settings`"

  slot :inner_block, required: true

  # The chooser's frame: the set-up's, with no sidebar; or the workspace's settings, with
  # the step's section current and the chooser's heading in the breadcrumb.
  defp page(%{action: :set_up} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@counts}
      place={:organisation}
      sidebar={false}
    >
      <SetUpComponents.frame steps={@steps} title={@title}>
        {render_slot(@inner_block)}
      </SetUpComponents.frame>
    </Layouts.app>
    """
  end

  defp page(%{action: :settings} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@counts}
      nav={:settings}
      sections={@sections}
      section={@section}
    >
      <:crumb>{@crumb}</:crumb>
      <div class="q-settings q-settings-solo">
        <section
          id={"settings-section-#{@section}"}
          class="q-settings-main q-settings-main-list"
        >
          {render_slot(@inner_block)}
        </section>
      </div>
    </Layouts.app>
    """
  end
end
