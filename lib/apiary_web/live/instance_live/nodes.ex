defmodule ApiaryWeb.InstanceLive.Nodes do
  # Instance settings › Nodes, for the instance's admins: the instance's node pool and
  # gateway (`Apiary.Nodes.Installed`), which run with the instance (`:index`). A page of
  # the Instance level, with no organisation: its gate asks the instance whether the
  # feature is on (`use ApiaryWeb.Features, instance: :factory`), and anyone but an
  # instance admin is answered as a path that does not exist, as on the Instance's other
  # pages.
  #
  # Each node is a row: its name, which leads to its Overview
  # (`ApiaryWeb.InstanceLive.Node`), its public id, its kind, and its state
  # (`ApiaryWeb.NodeComponents.node_state/1`). The page reads them again as an instance of
  # either reports (`Apiary.Nodes.topic/1`, `"instance"`). Qory Apiary makes them from its
  # settings, so the page offers no way to add one.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.Adapters
  alias Apiary.Nodes.Installed
  alias ApiaryWeb.{NodeComponents, SettingsComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if Adapters.authorize_instance(scope) != :ok, do: raise(ApiaryWeb.NotFound)
    if connected?(socket), do: Installed.subscribe(scope)

    {:ok,
     socket
     |> assign(page_title: SettingsComponents.page_title(scope, :instance, [gettext("Nodes")]))
     |> load()}
  end

  defp load(%{assigns: %{current_scope: scope}} = socket) do
    nodes = Installed.list(scope)
    assign(socket, nodes: nodes, activity: Installed.activity(scope, nodes))
  end

  @impl true
  def handle_info({:nodes_touched, _place}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:nodes}
    >
      <.settings_page section={:nodes} title={gettext("Nodes")} measure="list">
        <:subtitle>
          {gettext(
            "The node pool and the gateway that run with this instance. Qory Apiary makes them and writes their one-time codes. The pool takes the runs of every workspace that has no node pool in use. The gateway serves every organisation."
          )}
        </:subtitle>

        <.table
          :if={@nodes != []}
          id="instance-nodes"
          label={gettext("Nodes")}
          rows={@nodes}
          row_id={&"instance-node-#{&1.public_id}"}
        >
          <:col :let={node} label={gettext("Name")} kind="title">
            <span class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
              <.link
                id={"instance-node-#{node.public_id}-name"}
                navigate={~p"/instance/nodes/#{node.public_id}"}
                class="font-medium hover:underline"
              >
                {node.name}
              </.link>
              <span class="q-mono text-[12.5px] text-muted">{node.public_id}</span>
            </span>
          </:col>
          <:col :let={node} label={gettext("Kind")} from="sm">
            <span id={"instance-node-#{node.public_id}-kind"}>
              {NodeComponents.kind_label(node.kind)}
            </span>
          </:col>
          <:col :let={node} label={gettext("State")}>
            <NodeComponents.node_state
              id={"instance-node-#{node.public_id}-state"}
              node={node}
              activity={@activity[node.id]}
            />
          </:col>
        </.table>
      </.settings_page>
    </Layouts.app>
    """
  end
end
