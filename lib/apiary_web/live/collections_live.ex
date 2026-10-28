defmodule ApiaryWeb.CollectionsLive do
  # Workspace settings › Work sources (`/:org/:workspace/settings/work-sources`,
  # `:sources`) and › Destinations (`/:org/:workspace/settings/destinations`,
  # `:destinations`), with the `factory` feature: the tick lists of the set-up's steps Work
  # sources used and Destinations used (`ApiaryWeb.TickListComponents`), under the step's
  # question, with the same behaviour. A tick (`Apiary.WorkspaceSetup.tick/5`) reads the
  # list again first, and changes nothing for a collection that is now in another
  # workspace. With no collection, the link to the set-up's step that connects one leads
  # to that step of the workspace's flow (`ApiaryWeb.SetUpComponents.flow_path/2`).
  #
  # Every member reads them (`adapter.read`, which the lists' rows need); owners and
  # admins tick (`collection.assign`), and anyone else sees the boxes disabled, and who
  # may. The page listens to the organisation's collections and connections
  # (`Apiary.Adapters.Collections.subscribe/1`) and reads the list again on each change.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.WorkspaceSetup
  alias Apiary.Adapters.Collections
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.{SettingsComponents, SetUpComponents, TickListComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      _subscribed = Collections.subscribe(scope)
    end

    {:ok,
     assign(socket,
       sections: SettingsComponents.sections(scope, :workspace),
       domain: Domain.for_workspace(scope.workspace)
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    title = title(socket.assigns.live_action)

    {:noreply,
     socket
     |> assign(
       list: socket.assigns.live_action,
       title: title,
       page_title:
         SettingsComponents.page_title(socket.assigns.current_scope, :workspace, [title])
     )
     |> load()}
  end

  defp title(:sources), do: gettext("Work sources")
  defp title(:destinations), do: gettext("Destinations")

  # The list as it stands now, and who may act on it.
  defp load(socket) do
    %{current_scope: scope, domain: domain, list: list} = socket.assigns
    flow = SetUpComponents.flow(scope.organisation, domain, scope.workspace, :set_up)

    assign(
      socket,
      TickListComponents.load(scope, domain, list, SetUpComponents.flow_path(flow, list))
    )
  end

  @impl true
  def handle_event("tick", %{"id" => id}, %{assigns: %{may: true}} = socket) do
    %{current_scope: scope, domain: domain, list: list} = socket.assigns
    ticked = WorkspaceSetup.tick(scope, scope.workspace, domain, list, id)

    {:noreply,
     socket |> TickListComponents.put_tick_flash(ticked, socket.assigns.who_may) |> load()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  # A collection or a connection of the organisation changed: the list reads again.
  def handle_info({event, _ids}, socket)
      when event in [:collections_changed, :connection_changed],
      do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The step's question, above the list.
  defp question(:sources, workspace),
    do: gettext("Which work sources does %{workspace} use?", workspace: workspace.name)

  defp question(:destinations, workspace),
    do: gettext("Which targets may %{workspace}'s runs change?", workspace: workspace.name)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={section(@list)}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        kind={:workspace}
        current={section(@list)}
        title={@title}
      >
        <:subtitle>{question(@list, @current_scope.workspace)}</:subtitle>
        <div class="grid gap-3">
          <TickListComponents.tick_list
            id={section_id(@list)}
            list={@list}
            groups={@groups}
            workspace={@current_scope.workspace}
            organisation={@current_scope.organisation}
            may={@may}
            who_may={@who_may}
            may_connect={@may_connect}
            who_connects={@who_connects}
            connect_path={@connect_path}
            connect_by="navigate"
          />
        </div>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  # The key of the page's section in the settings' list.
  defp section(:sources), do: :work_sources
  defp section(:destinations), do: :destinations

  defp section_id(:sources), do: "work-sources"
  defp section_id(:destinations), do: "destinations"
end
