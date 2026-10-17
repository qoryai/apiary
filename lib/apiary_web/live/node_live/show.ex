defmodule ApiaryWeb.NodeLive.Show do
  @moduledoc """
  A node's or a node pool's page, `/:org/:workspace/nodes/:node_id`, where `:node_id` is
  the node's public id. A node the workspace does not have, or one that is deleted, is
  not found. Its tabs are Overview, Access key and Settings, the operational side first
  and Settings last, set apart (`docs/ui.md`, Nodes; `ApiaryWeb.NodeComponents.node_tabs/1`).
  Overview and Settings are patches of this LiveView; Access key is
  `ApiaryWeb.NodeLive.AccessKey`'s, a navigation:

  - **Overview** (`/nodes/:node_id`): what the node is doing (`Apiary.Nodes.activity/3`).
    A Node's instance, running or when it was last seen; a pool's running instances,
    "3 of 10"; the starts refused at the instance limit; the sentence that says an
    instance is a claim; and its recent runs (`runs.node_id`, for a reader of the record,
    `run.read`), with the way to all of them on the runs list (`?node=`). Until an
    instance reports, each says so. Then About: its kind, id, instance limit and who made
    it, with the way to its Settings. Owners and admins clear a running instance
    (`node.clear_instance`): a text action on a Node's, an item of each row's menu on a
    pool's, either turning that line or row into its confirmation in place, never a
    dialog, at `/nodes/:node_id/instances/:instance/clear`, `:instance` the id of the
    instance's row in `node_instances`, or, for an instance with no row, at
    `/nodes/:node_id/runs/:run_id/clear-instance`, `:run_id` the `public_id` of its newest
    open run. Neither address carries the node's instance id.
  - **Settings** (`/nodes/:node_id/settings`), with the node's list of sections
    (`ApiaryWeb.SettingsComponents`): General, its name, its kind (shown, fixed) and a
    pool's instance limit, then the danger zone, whose Delete expands its confirmation in
    place, at `/nodes/:node_id/settings/delete`.

  **A gateway's page** has the same tabs. Its Overview leads with the gateway: its URL,
  and whether it is the workspace's default gateway, with Make default for one that is
  not (`Apiary.Nodes.make_default_gateway/2`, `node.edit`); then its recent runs and
  About, without instances or an instance limit. Its Settings › General changes its name
  and its URL. Deleting it is confirmed in place as a node's is; a gateway that nodes
  point to, or runs go through, is not deleted, and the danger zone says so under its
  line (`ApiaryWeb.NodeComponents.in_use_words/2`), naming the nodes and runs of this
  workspace, the first few, and counting the rest, those of other workspaces among them.

  A node's and a pool's Settings › General choose its gateway
  (`ApiaryWeb.NodeComponents.gateway_field/1`), and its About says where its choice leads:
  Direct, Default gateway and the gateway it is now, or the gateway it names.

  Everyone in the workspace reads the page (`node.read`); owners and admins change the
  node (`node.edit`), set a pool's limit (`node.set_limit`), delete it (`node.delete`) and
  clear an instance (`node.clear_instance`). A member reads Settings with its fields
  disabled and no danger zone, sees no Clear instance, and the deletion's and the
  clearing's paths refuse them. One who changes the node but not its limit, as an edition
  may have it, reads the limit disabled, with a line that says so.

  The header names the node, its public id beside it, then one muted line: its kind, its
  state (`ApiaryWeb.NodeComponents.node_state/1`: running, last seen or never seen), and
  who made it and when. The breadcrumb's segments are Nodes, then the node.

  Live: the page reads the node and what it is doing again on `{:nodes_touched, …}`
  (`Apiary.Nodes.topic/1`), on a `{:run_changed, run}` of one of its runs, at most every
  250 ms, and every 15 seconds, since an instance stops running without an event when
  its runs fall silent.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, Gateways, Nodes, Repo, Runs}
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Runs.{Filters, Run}
  alias ApiaryWeb.{NodeComponents, People, SettingsComponents, UserAuth}

  @tick :timer.seconds(15)
  @coalesce_ms 250
  @recent 5

  @impl true
  def mount(%{"node_id" => public_id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    place = NodeComponents.node_place(params)

    case NodeComponents.find_node(scope, place, public_id) do
      %Node{} = node ->
        socket =
          socket
          |> assign(place: place, node: node, paths: paths(scope, place, node.public_id))
          |> assign(page_title: node.name)
          |> assign(sections: SettingsComponents.sections(scope, {:node, node}))
          |> assign(clearing: nil, recent: nil, reload_scheduled: false, delete_refused: nil)
          |> assign_gateways()
          |> assign_may()
          |> assign_form(Nodes.change_node(node))
          |> assign_activity()
          |> UserAuth.on_membership_change(&assign_may/1)
          |> NodeComponents.leave_when_hidden(~w(save delete make_default clear_instance))

        if connected?(socket) do
          Nodes.subscribe(scope, place)
          if socket.assigns.may_runs, do: Runs.subscribe(scope)
          Process.send_after(self(), :tick, @tick)
        end

        {:ok, load_recent(socket)}

      nil ->
        raise Ecto.NoResultsError, queryable: Node
    end
  end

  defp assign_may(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    assign(socket,
      may_edit: Access.can?(scope, :"node.edit", node),
      may_set_limit: Access.can?(scope, :"node.set_limit", node),
      may_delete: Access.can?(scope, :"node.delete", node),
      may_clear: Access.can?(scope, :"node.clear_instance", node),
      may_runs:
        socket.assigns.place == :workspace and Access.can?(scope, :"run.read", scope.workspace)
    )
  end

  # The gateways the node's form chooses from, the workspace's default, and the gateway
  # the node's choice leads to now, each with its organisation; none of it for a gateway.
  # An organisation's gateway's page says which workspaces' nodes use it now, naming those
  # the reader reaches.
  defp assign_gateways(%{assigns: %{node: %Node{kind: :gateway} = node}} = socket) do
    using =
      if node.workspace_id,
        do: nil,
        else:
          NodeComponents.using_words(
            Gateways.workspaces_using(node),
            NodeComponents.reached_workspaces(socket.assigns.memberships)
          )

    assign(socket, gateways: [], default: nil, through: nil, using: using)
  end

  defp assign_gateways(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    assign(socket,
      gateways: scope |> Gateways.gateway_choices() |> Repo.preload(:organisation),
      default: scope.workspace |> Gateways.default_gateway_for() |> Repo.preload(:organisation),
      through: node |> Gateways.chosen() |> Repo.preload(:organisation),
      using: nil
    )
  end

  # What the node is doing now: the header's state and the Overview's instances.
  defp assign_activity(socket) do
    %{current_scope: scope, node: node} = socket.assigns
    activity = Map.fetch!(Nodes.activity(scope, [node]), node.id)
    assign(socket, :activity, activity)
  end

  # The node's latest runs, off the socket's process, for a reader of the record.
  defp load_recent(%{assigns: %{may_runs: false}} = socket), do: socket

  defp load_recent(socket) do
    if connected?(socket) do
      %{current_scope: scope, node: node} = socket.assigns
      filters = %{Filters.new(:runs) | node: node.public_id, per: @recent}

      start_async(socket, :recent, fn ->
        ApiaryWeb.Lingo.with_locale(scope, fn ->
          listing = Runs.page_runs(scope, filters)
          %{runs: listing.runs, total: listing.total}
        end)
      end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:recent, {:ok, recent}, socket),
    do: {:noreply, assign(socket, :recent, recent)}

  def handle_async(:recent, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_params(%{"node_id" => public_id}, _uri, %{assigns: %{node: node}} = socket)
      when public_id != node.public_id do
    paths = paths(socket.assigns.current_scope, socket.assigns.place, public_id)
    {:noreply, push_navigate(socket, to: paths.overview)}
  end

  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :overview, _params),
    do: assign(socket, page_title: socket.assigns.node.name, clearing: nil, delete_refused: nil)

  defp apply_action(socket, :clear_instance, params) do
    cond do
      not socket.assigns.may_clear ->
        socket
        |> put_flash(
          :error,
          ApiaryWeb.Access.who_may(
            socket.assigns.current_scope,
            :"node.clear_instance",
            gettext("Only owners and admins clear instances.")
          )
        )
        |> push_patch(to: node_path(socket, :overview))

      clearing = clearing(socket, params) ->
        assign(socket, page_title: socket.assigns.node.name, clearing: clearing)

      true ->
        socket
        |> put_flash(:error, gettext("This node has no such instance."))
        |> push_patch(to: node_path(socket, :overview))
    end
  end

  defp apply_action(socket, :settings, _params),
    do: assign(socket, page_title: settings_title(socket.assigns.node), clearing: nil)

  defp apply_action(socket, :delete, _params) do
    if socket.assigns.may_delete do
      assign(socket, page_title: settings_title(socket.assigns.node), delete_refused: nil)
    else
      socket
      |> put_flash(
        :error,
        ApiaryWeb.Access.who_may(
          socket.assigns.current_scope,
          :"node.delete",
          gettext("Only owners and admins delete nodes.")
        )
      )
      |> push_patch(to: node_path(socket, :settings))
    end
  end

  # The instance the confirmation clears, by the address's id: the id of its row, for one
  # the record holds a row of, running now or not; or an open run of its, for one running
  # with no row. The clearing names it by the node's instance id, which the address never
  # carries.
  defp clearing(socket, %{"instance" => row_id}) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.get_instance_by_id(scope, node, row_id) do
      %Instance{node_instance_id: instance_id, name: name} ->
        %{instance_id: instance_id, name: name}

      nil ->
        nil
    end
  end

  defp clearing(socket, %{"run_id" => run_id}) do
    %{current_scope: scope, node: node, activity: activity} = socket.assigns

    with %Run{node_instance_id: instance_id} <- Nodes.get_instance_run(scope, node, run_id) do
      case Enum.find(activity.running, &(&1.instance_id == instance_id)) do
        %{} = running ->
          %{instance_id: instance_id, name: running.name}

        nil ->
          case Nodes.get_instance(scope, node, instance_id) do
            %Instance{name: name} -> %{instance_id: instance_id, name: name}
            nil -> %{instance_id: instance_id, name: nil}
          end
      end
    end
  end

  defp settings_title(node), do: gettext("Settings · %{name}", name: node.name)

  @impl true
  def handle_event("validate", %{"node" => params}, socket) do
    changeset =
      socket.assigns.node
      |> Nodes.change_node(NodeComponents.choice_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"node" => params}, socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.update_node(scope, node, NodeComponents.choice_params(params)) do
      {:ok, updated} ->
        updated = %{updated | created_by: node.created_by}

        {:noreply,
         socket
         |> assign(node: updated, page_title: settings_title(updated))
         |> assign_gateways()
         |> assign_form(Nodes.change_node(updated))
         |> put_flash(:info, gettext("%{name} is saved.", name: updated.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, :forbidden} ->
        {:noreply, refused_save(socket)}
    end
  end

  def handle_event("delete", _params, %{assigns: %{live_action: :delete}} = socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.delete_node(scope, node) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is deleted.", name: deleted.name))
         |> push_navigate(to: NodeComponents.nodes_path(scope, socket.assigns.place))}

      {:error, {:gateway_in_use, blockers}} ->
        {:noreply,
         socket
         |> assign(:delete_refused, in_use_words(socket, blockers))
         |> push_patch(to: node_path(socket, :settings))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Nothing was changed. Try again."))
         |> push_patch(to: node_path(socket, :settings))}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, :forbidden} ->
        {:noreply,
         refused(
           socket,
           :"node.delete",
           gettext("Only owners and admins delete nodes."),
           :settings
         )}
    end
  end

  # A deletion without its confirmation open: a page that offered none, or a confirmation
  # that has folded. One who may delete the node is shown the page again; anyone else is refused.
  def handle_event("delete", _params, socket) do
    if socket.assigns.may_delete,
      do: {:noreply, socket},
      else:
        {:noreply,
         refused(
           socket,
           :"node.delete",
           gettext("Only owners and admins delete nodes."),
           :settings
         )}
  end

  # Make default, on a gateway's Overview: asked of the context whatever the page shows,
  # so one who may not is refused there, and a gateway that is the default already stays so.
  def handle_event("make_default", _params, %{assigns: %{node: %Node{kind: :gateway}}} = socket) do
    %{current_scope: scope, node: node} = socket.assigns

    if socket.assigns.may_edit do
      case Nodes.make_default_gateway(scope, node) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:node, %{updated | created_by: node.created_by})
           |> assign_form(Nodes.change_node(updated))
           |> put_flash(
             :info,
             gettext("%{name} is the default gateway now.", name: updated.name)
           )}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("Nothing was changed. Try again."))}

        {:error, :not_found} ->
          {:noreply, gone(socket)}

        {:error, :forbidden} ->
          {:noreply, refused_default(socket)}
      end
    else
      {:noreply, refused_default(socket)}
    end
  end

  # Make default on a node that is not a gateway: a page that offered none.
  def handle_event("make_default", _params, socket) do
    if socket.assigns.may_edit,
      do: {:noreply, socket},
      else: {:noreply, refused_default(socket)}
  end

  def handle_event(
        "clear_instance",
        _params,
        %{assigns: %{live_action: :clear_instance, clearing: %{} = clearing}} = socket
      ) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.clear_instance(scope, node, clearing.instance_id) do
      {:ok, %{runs: runs}} ->
        {:noreply,
         socket
         |> put_flash(:info, cleared_words(clearing, length(runs)))
         |> reload()
         |> push_patch(to: node_path(socket, :overview))}

      {:error, :not_found} ->
        if NodeComponents.find_node(scope, socket.assigns.place, node.public_id) &&
             not NodeComponents.hidden_now?(scope),
           do:
             {:noreply,
              socket
              |> put_flash(:error, gettext("This node has no such instance."))
              |> push_patch(to: node_path(socket, :overview))},
           else: {:noreply, gone(socket)}

      {:error, :forbidden} ->
        {:noreply,
         refused(
           socket,
           :"node.clear_instance",
           gettext("Only owners and admins clear instances."),
           :overview
         )}
    end
  end

  # A clearing without its confirmation open: a page that offered none, or a confirmation
  # that has been cancelled. One who may clear is shown the page again; anyone else is refused.
  def handle_event("clear_instance", _params, socket) do
    if socket.assigns.may_clear,
      do: {:noreply, socket},
      else:
        {:noreply,
         refused(
           socket,
           :"node.clear_instance",
           gettext("Only owners and admins clear instances."),
           :overview
         )}
  end

  defp cleared_words(clearing, 0),
    do: gettext("%{instance} is cleared.", instance: instance_label(clearing))

  defp cleared_words(clearing, runs),
    do:
      ngettext(
        "%{instance} is cleared: its open run is marked lost.",
        "%{instance} is cleared: its %{count} open runs are marked lost.",
        runs,
        instance: instance_label(clearing)
      )

  # Why the gateway was not deleted: on an organisation's gateway's page, naming the nodes
  # and runs of the workspaces the reader reaches.
  defp in_use_words(%{assigns: %{place: :organisation}} = socket, blockers) do
    reached = NodeComponents.reached_workspaces(socket.assigns.memberships)
    NodeComponents.in_use_words(socket.assigns.current_scope, blockers, reached)
  end

  defp in_use_words(socket, blockers),
    do: NodeComponents.in_use_words(socket.assigns.current_scope, blockers)

  defp refused_default(socket),
    do: refused(socket, :"node.edit", gettext("Only owners and admins change nodes."), :overview)

  defp instance_label(%{name: name}) when is_binary(name), do: name
  defp instance_label(%{instance_id: instance_id}), do: instance_id

  ## Live

  @impl true
  def handle_info({:nodes_touched, _workspace_id}, socket),
    do: {:noreply, schedule_reload(socket)}

  def handle_info({:run_changed, %Run{node_id: id}}, %{assigns: %{node: %Node{id: id}}} = socket),
    do: {:noreply, schedule_reload(socket)}

  def handle_info(:reload, socket),
    do: {:noreply, socket |> assign(:reload_scheduled, false) |> reload()}

  # Running ends without an event when a run falls silent: the page looks again.
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, reload(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_reload(%{assigns: %{reload_scheduled: true}} = socket), do: socket

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload, @coalesce_ms)
    assign(socket, :reload_scheduled, true)
  end

  # The node and what it does, as the database has them now; a node deleted since the
  # page opened sends the reader to the list.
  defp reload(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case NodeComponents.find_node(scope, socket.assigns.place, node.public_id) do
      %Node{} = current ->
        socket
        |> assign(:node, current)
        |> assign_gateways()
        |> assign_activity()
        |> load_recent()

      nil ->
        gone(socket)
    end
  end

  # The node was deleted, or left the reader's reach, since the page opened. Where the
  # nodes were hidden from the reader meanwhile, the page leaves as it does once it hears
  # of it, and says that instead.
  defp gone(socket) do
    if NodeComponents.hidden_now?(socket.assigns.current_scope) do
      UserAuth.reload_scope(socket)
    else
      socket
      |> put_flash(:error, gettext("This node is gone: it was deleted."))
      |> push_navigate(
        to: NodeComponents.nodes_path(socket.assigns.current_scope, socket.assigns.place)
      )
    end
  end

  # A save refused: one who still changes the node was refused its limit alone, and reads
  # it disabled from now on; anyone else is refused the change.
  defp refused_save(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    if Access.can?(Access.reload(scope), :"node.edit", node) do
      socket
      |> assign(may_set_limit: false)
      |> assign_form(Nodes.change_node(node))
      |> put_flash(:error, NodeComponents.limit_refused(scope))
      |> push_patch(to: node_path(socket, :settings))
    else
      refused(socket, :"node.edit", gettext("Only owners and admins change nodes."), :settings)
    end
  end

  # A change the reader may not make, `action`, as the database has their membership now:
  # one who still reads the workspace is told who may on the tab `back` names, `why` in
  # the core's words; one who reads the organisation through the edition's reach is told
  # so; anyone else is sent to `/`.
  defp refused(socket, action, why, back) do
    scope = Access.reload(socket.assigns.current_scope)

    cond do
      # The nodes hidden from them meanwhile: the page leaves as it does once it hears of
      # it (`ApiaryWeb.UserAuth.reload_scope/1`).
      not Apiary.Features.visible?(scope, :nodes) ->
        ApiaryWeb.UserAuth.reload_scope(socket)

      Access.reader(scope) ->
        socket
        |> put_flash(:error, ApiaryWeb.Access.reads_only(scope))
        |> push_patch(to: node_path(socket, back))

      NodeComponents.reads_nodes?(scope, socket.assigns.place) ->
        socket
        |> assign(may_edit: false, may_set_limit: false, may_delete: false, may_clear: false)
        |> assign_form(Nodes.change_node(socket.assigns.node))
        |> put_flash(:error, ApiaryWeb.Access.who_may(scope, action, why))
        |> push_patch(to: node_path(socket, back))

      true ->
        socket
        |> put_flash(:error, NodeComponents.no_longer_member(socket.assigns.place))
        |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :node))

  defp node_path(socket, action), do: Map.fetch!(socket.assigns.paths, action)

  # The page's paths: its tabs, the deletion's confirmation, and, for a page of a
  # workspace, the node's runs on the list.
  defp paths(scope, place, public_id) do
    base = NodeComponents.node_base(scope, place, public_id)

    %{
      overview: base,
      access_key: base <> "/access-key",
      settings: base <> "/settings",
      delete: base <> "/settings/delete",
      runs:
        if(place == :workspace,
          do: ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{[node: public_id]}"
        )
    }
  end

  # The path where a running instance of the node is asked to be cleared: by the id of its
  # row, or, for one with no row, by its newest open run's public id.
  defp clear_path(scope, node, %{row_id: row_id}) when is_binary(row_id),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/instances/#{row_id}/clear"

  defp clear_path(scope, node, %{run_public_id: run_id}),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/runs/#{run_id}/clear-instance"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={NodeComponents.nodes_nav(@place)}
    >
      <:crumb navigate={NodeComponents.nodes_path(@current_scope, @place)}>
        {NodeComponents.nodes_label(@place)}
      </:crumb>
      <:crumb navigate={@live_action != :overview && @paths.overview} title={@node.name}>
        {@node.name}
      </:crumb>

      <NodeComponents.node_header node={@node} activity={@activity} />
      <NodeComponents.node_tabs
        node={@node}
        paths={@paths}
        current={if @live_action in [:settings, :delete], do: :settings, else: :overview}
        view={:show}
      />

      <.overview
        :if={@live_action in [:overview, :clear_instance]}
        scope={@current_scope}
        node={@node}
        activity={@activity}
        paths={@paths}
        may_clear={@may_clear}
        may_edit={@may_edit}
        may_runs={@may_runs}
        recent={@recent}
        through={@through}
        using={@using}
        clearing={@live_action == :clear_instance && @may_clear && @clearing}
      />

      <SettingsComponents.layout
        :if={@live_action in [:settings, :delete]}
        scope={@current_scope}
        kind={:node}
        sections={@sections}
        current={:general}
        title={gettext("General")}
      >
        <:subtitle>
          {if @node.kind == :gateway,
            do: gettext("The gateway's name, its kind and its URL."),
            else: gettext("The node's name, its kind and how many instances may run at once.")}
        </:subtitle>
        <.general
          scope={@current_scope}
          node={@node}
          form={@form}
          may_edit={@may_edit}
          may_set_limit={@may_set_limit}
          may_delete={@may_delete}
          deleting={@live_action == :delete}
          delete_refused={@delete_refused}
          gateways={@gateways}
          default={@default}
          paths={@paths}
        />
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  attr :scope, :map, required: true
  attr :node, Node, required: true
  attr :activity, :map, required: true
  attr :paths, :map, required: true
  attr :may_clear, :boolean, required: true
  attr :may_edit, :boolean, required: true
  attr :may_runs, :boolean, required: true
  attr :recent, :any, required: true
  attr :through, :any, required: true, doc: "the gateway the node's choice leads to, or nil"
  attr :using, :any, required: true, doc: "who uses an organisation's gateway now, or nil"
  attr :clearing, :any, required: true, doc: "the instance asked to be cleared, or false"

  # The operational side: a Node's instance or a pool's running instances, what the
  # instance limit refused, what an instance is, its recent runs, and About. An instance
  # asked to be cleared confirms it in place: its row of a pool's running instances, or
  # the line of a Node's running one; one that does not run now, at the top of the part.
  defp overview(assigns) do
    assigns =
      assign(assigns, :clear_at, clear_place(assigns.clearing, assigns.node, assigns.activity))

    ~H"""
    <div id="node-overview" class="grid max-w-[60rem] gap-8">
      <.gateway_part
        :if={@node.kind == :gateway}
        scope={@scope}
        node={@node}
        using={@using}
        may_edit={@may_edit}
      />

      <SettingsComponents.part
        :if={@node.kind != :gateway}
        id="node-instances"
        title={if @node.kind == :pool, do: gettext("Running instances"), else: gettext("Instance")}
        level={:h2}
      >
        <.clear_confirm :if={@clear_at == :part} clearing={@clearing} cancel={@paths.overview} />

        <p
          :if={@node.kind == :pool && @activity.running != []}
          id="node-instances-count"
          class="text-[13px]/5 text-muted"
        >
          {NodeComponents.running_words(@node, length(@activity.running))}
        </p>

        <.node_instance
          :if={@node.kind == :node && (@activity.running != [] || @activity.last)}
          scope={@scope}
          node={@node}
          activity={@activity}
          may_clear={@may_clear}
          may_runs={@may_runs}
          clearing={@clear_at == :line && @clearing}
          cancel={@paths.overview}
        />

        <.table
          :if={@node.kind == :pool && @activity.running != []}
          id="node-running"
          label={gettext("Running instances")}
          rows={@activity.running}
          row_id={&instance_dom_id(&1.instance_id)}
          confirming={@clear_at == :row && instance_dom_id(@clearing.instance_id)}
        >
          <:col :let={instance} label={gettext("Instance")} kind="title">
            <span class="q-nm">
              <span class="q-cut" title={instance.name || instance.instance_id}>
                {instance.name || instance.instance_id}
              </span>
              <span :if={instance.name} class="q-side q-mono" title={instance.instance_id}>
                {instance.instance_id}
              </span>
            </span>
          </:col>
          <:col :let={instance} label={gettext("Running since")}>
            <.relative_time format="clock" at={instance.since} />
          </:col>
          <:col :let={instance} label={gettext("Run")} from="sm">
            <.run_link scope={@scope} public_id={instance.run_public_id} may_runs={@may_runs} />
          </:col>
          <:col :let={instance} label={gettext("Forager")} kind="faint" from="md">
            {instance.forager_version || gettext("n/a")}
          </:col>
          <:action :let={instance} :if={@may_clear}>
            <.row_menu
              id={"#{instance_dom_id(instance.instance_id)}-menu"}
              label={
                gettext("Actions for %{instance}",
                  instance: instance.name || instance.instance_id
                )
              }
            >
              <.menu_item
                id={"#{instance_dom_id(instance.instance_id)}-clear"}
                patch={clear_path(@scope, @node, instance)}
              >
                {gettext("Clear instance…")}
              </.menu_item>
            </.row_menu>
          </:action>
          <:confirm>
            <.clear_confirm clearing={@clearing} cancel={@paths.overview} />
          </:confirm>
        </.table>

        <p
          :if={@activity.running == [] && @activity.last == nil}
          id="node-instances-none"
          class="text-[13px]/5 text-muted"
        >
          {cond do
            @node.kind == :pool and NodeComponents.seen_at(@activity) != nil ->
              gettext("No instance of this pool is running. An instance shows here while it runs.")

            @node.kind == :pool ->
              gettext(
                "No instance of this pool has reported yet. An instance shows here while it runs."
              )

            true ->
              gettext(
                "No instance of this node has reported yet. It shows here once it runs, running or when it was last seen."
              )
          end}
        </p>
        <p
          :if={@node.kind == :pool && @activity.running == [] && @activity.last}
          id="node-instances-idle"
          class="text-[13px]/5 text-muted"
        >
          {gettext("None is running. An instance shows here only while it runs; the last was seen")}
          <.relative_time id="node-instances-idle-seen" at={@activity.last.last_seen_at} />.
        </p>

        <p
          :if={@node.instance_limit_refused > 0 && @node.instance_limit_refused_at}
          id="node-refused"
          class="text-[13px]/5 text-muted"
        >
          {ngettext(
            "%{number} start was refused at the instance limit; the last",
            "%{number} starts were refused at the instance limit; the last",
            @node.instance_limit_refused,
            number: Format.number(@node.instance_limit_refused)
          )}
          <.relative_time id="node-refused-at" at={@node.instance_limit_refused_at} />.
        </p>
        <p
          :if={@node.instance_ids_over_bound > 0}
          id="node-over-bound"
          class="text-[13px]/5 text-muted"
        >
          {ngettext(
            "%{number} new instance was not recorded: a node records at most 256 new instances a day.",
            "%{number} new instances were not recorded: a node records at most 256 new instances a day.",
            @node.instance_ids_over_bound,
            number: Format.number(@node.instance_ids_over_bound)
          )}
        </p>

        <p id="node-instance-claim" class="text-[13px]/5 text-faint">
          {NodeComponents.instance_sentence()}
        </p>
      </SettingsComponents.part>

      <SettingsComponents.part
        :if={@may_runs}
        id="node-runs"
        title={gettext("Recent runs")}
        level={:h2}
      >
        <p :if={@recent && @recent.runs == []} id="node-runs-none" class="text-[13px]/5 text-muted">
          {gettext("No run of this node is in the record yet.")}
        </p>
        <.runs_table
          :if={@recent == nil || @recent.runs != []}
          id="node-runs-table"
          label={gettext("Recent runs")}
          runs={(@recent && @recent.runs) || []}
          scope={@scope}
          loading={@recent == nil}
        />
        <p :if={@recent && @recent.runs != []}>
          <.link
            id="node-runs-all"
            navigate={@paths.runs}
            class="text-[13px] text-accent hover:underline"
          >
            {ngettext("The run on the runs list", "All %{count} runs on the runs list", @recent.total)}<.icon
              name="hero-arrow-right-micro"
              class="size-3.5"
            />
          </.link>
        </p>
      </SettingsComponents.part>

      <SettingsComponents.part id="node-about" title={gettext("About")} level={:h2}>
        <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-2 text-[13px]/5">
          <dt class="text-faint">{gettext("Kind")}</dt>
          <dd id="node-about-kind">
            {kind_sentence(@node.kind)}
            <span class="text-muted">{gettext("Fixed when it was made.")}</span>
          </dd>
          <dt class="text-faint">{gettext("Id")}</dt>
          <dd class="q-mono">{@node.public_id}</dd>
          <dt :if={@node.kind != :gateway} class="text-faint">{gettext("Instance limit")}</dt>
          <dd :if={@node.kind != :gateway} id="node-about-limit">{limit_words(@node)}</dd>
          <dt :if={@node.kind != :gateway} class="text-faint">{gettext("Gateway")}</dt>
          <dd :if={@node.kind != :gateway} id="node-about-gateway">
            <.choice_words scope={@scope} node={@node} through={@through} />
          </dd>
          <dt :if={@node.created_by} class="text-faint">{gettext("Made")}</dt>
          <dd :if={@node.created_by}>
            {gettext("by %{person}, %{date}",
              person: People.email(@node.created_by),
              date: Format.date(@node.inserted_at)
            )}
          </dd>
        </dl>
        <p>
          <.link
            id="node-about-settings"
            patch={@paths.settings}
            class="text-[13px] text-accent hover:underline"
          >
            {gettext("Settings")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
          </.link>
        </p>
      </SettingsComponents.part>
    </div>
    """
  end

  attr :scope, :map, required: true
  attr :node, Node, required: true
  attr :using, :any, required: true
  attr :may_edit, :boolean, required: true

  # A gateway's Overview leads with the gateway: its URL, and whether it is the
  # workspace's default gateway, with Make default for one that is not. An organisation's
  # says whose nodes can use it, which workspaces' nodes use it now, and whether it is the
  # organisation's default.
  defp gateway_part(assigns) do
    ~H"""
    <SettingsComponents.part id="gateway-overview" title={gettext("Gateway")} level={:h2}>
      <div :if={is_nil(@node.workspace_id)} id="gateway-reach" class="grid gap-1 text-[13px]/5">
        <p id="gateway-who-can-use">
          {ApiaryWeb.Edition.gateway_reach_sentence(:who_can_use, @scope.organisation)}
        </p>
        <p id="gateway-using" class="text-muted">{@using}</p>
      </div>
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] items-baseline gap-x-6 gap-y-2 text-[13px]/5">
        <dt class="text-faint">{gettext("URL")}</dt>
        <dd class="flex min-w-0 items-center gap-1">
          <span id="gateway-url" class="q-mono break-all">{@node.url}</span>
          <.copy_button
            id="gateway-url-copy"
            text={@node.url}
            label={gettext("Copy the URL of %{name}", name: @node.name)}
            placement="right"
            icon_only
          />
        </dd>
        <dt class="text-faint">{gettext("Default")}</dt>
        <dd id="gateway-default" class="grid gap-2">
          <span>
            {cond do
              not @node.default_gateway ->
                gettext("Not the default.")

              is_nil(@node.workspace_id) ->
                ApiaryWeb.Edition.gateway_reach_sentence(:default_row, @scope.organisation)

              true ->
                gettext("This workspace's default gateway.")
            end}
            <span class="text-muted">
              {gettext("Runs of nodes and node pools on Default gateway go through the default.")}
            </span>
          </span>
          <span :if={@may_edit and not @node.default_gateway}>
            <.button id="gateway-make-default" size="xs" phx-click="make_default">
              {gettext("Make default")}
            </.button>
          </span>
        </dd>
      </dl>
    </SettingsComponents.part>
    """
  end

  attr :scope, :map, required: true
  attr :node, Node, required: true
  attr :through, :any, required: true

  # Where a node's choice of gateway leads: Direct; Default gateway, and the gateway that
  # is the default now; or the gateway it names, each gateway a link to its page.
  defp choice_words(assigns) do
    ~H"""
    <%= case @node.gateway_choice do %>
      <% :direct -> %>
        {gettext("Direct")}
      <% :default -> %>
        {gettext("Default gateway")}
        <span :if={@through} class="text-muted">
          · <.gateway_link scope={@scope} node={@node} gateway={@through} />
        </span>
        <span :if={!@through} class="text-muted">
          · {gettext("No gateway is the default now.")}
        </span>
      <% :named -> %>
        <.gateway_link :if={@through} scope={@scope} node={@node} gateway={@through} />
        <span :if={!@through} class="text-muted">{gettext("A gateway that is gone")}</span>
    <% end %>
    """
  end

  attr :scope, :map, required: true
  attr :node, Node, required: true
  attr :gateway, Node, required: true

  # The gateway, named as the node names it, a link to its page where the reader opens
  # it, and its URL, which run keys carry.
  defp gateway_link(assigns) do
    assigns =
      assign(assigns,
        path: NodeComponents.gateway_path(assigns.scope, assigns.gateway),
        name: NodeComponents.gateway_name(assigns.node.organisation_id, assigns.gateway)
      )

    ~H"""
    <.link :if={@path} navigate={@path} class="text-accent hover:underline">{@name}</.link>
    <span :if={!@path}>{@name}</span>
    <span class="q-mono text-muted">{@gateway.url}</span>
    """
  end

  attr :scope, :map, required: true
  attr :node, Node, required: true
  attr :activity, :map, required: true
  attr :may_clear, :boolean, required: true
  attr :may_runs, :boolean, required: true
  attr :clearing, :any, required: true, doc: "the running instance asked to be cleared"
  attr :cancel, :string, required: true

  # A Node's one instance: the one running, or the one seen last. Asked to be cleared, the
  # running one's line is the confirmation.
  defp node_instance(assigns) do
    assigns =
      assign(assigns,
        running: List.first(assigns.activity.running),
        last: assigns.activity.last
      )

    ~H"""
    <div id="node-instance" class="grid gap-2 text-[13px]/5">
      <p class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <%= if @running do %>
          <span id="node-instance-name" class="font-medium">
            {@running.name || @running.instance_id}
          </span>
          <span :if={@running.name} class="q-mono text-muted">{@running.instance_id}</span>
          <span class="q-sdot q-sdot-running">
            <i aria-hidden="true"></i><span>{gettext("Running since")}</span>
          </span>
          <.relative_time format="clock" at={@running.since} />
          <.run_link scope={@scope} public_id={@running.run_public_id} may_runs={@may_runs} />
          <span :if={@running.forager_version} class="text-muted">
            {gettext("Forager %{version}", version: @running.forager_version)}
          </span>
        <% else %>
          <span id="node-instance-name" class="font-medium">
            {@last.name || @last.node_instance_id}
          </span>
          <span :if={@last.name} class="q-mono text-muted">{@last.node_instance_id}</span>
          <span class="text-muted">
            {gettext("Last seen")}
            <.relative_time id="node-instance-seen" at={@last.last_seen_at} />
          </span>
          <span :if={@last.last_forager_version} class="text-muted">
            {gettext("Forager %{version}", version: @last.last_forager_version)}
          </span>
        <% end %>
      </p>
      <.clear_confirm :if={@running && @clearing} clearing={@clearing} cancel={@cancel} />
      <p :if={@running && !@clearing} class="flex flex-wrap items-center gap-3 text-muted">
        {gettext("A node runs one instance at a time.")}
        <.button
          :if={@may_clear}
          id="node-instance-clear"
          variant="link"
          patch={clear_path(@scope, @node, @running)}
        >
          {gettext("Clear instance…")}
        </.button>
      </p>
    </div>
    """
  end

  attr :clearing, :map, required: true
  attr :cancel, :string, required: true

  # The confirmation of clearing an instance, in place of its row or its line.
  defp clear_confirm(assigns) do
    ~H"""
    <.inline_confirm
      id="clear-instance"
      question={gettext("Clear %{instance}?", instance: instance_label(@clearing))}
      cancel={@cancel}
    >
      {gettext(
        "Clear this instance if it stopped without saying so. Another instance can then start at once."
      )}
      {gettext(
        "Its open runs are marked lost. If it is in fact still running, its next heartbeat brings its run back, and it counts against the instance limit again."
      )}
      <:action>
        <.button
          id="clear-instance-confirm"
          variant="danger"
          size="xs"
          phx-click="clear_instance"
          loading_text={gettext("Clearing")}
        >
          {gettext("Yes, clear")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  # Where the instance asked to be cleared confirms it: its row of a pool's running
  # instances, the line of a Node's running one, or, not running now, the top of the part.
  defp clear_place(clearing, _node, _activity) when clearing in [nil, false], do: nil

  defp clear_place(%{instance_id: id}, %Node{kind: :pool}, %{running: running}),
    do: if(Enum.any?(running, &(&1.instance_id == id)), do: :row, else: :part)

  defp clear_place(%{instance_id: id}, %Node{kind: :node}, %{running: [%{instance_id: id} | _]}),
    do: :line

  defp clear_place(_clearing, _node, _activity), do: :part

  attr :scope, :map, required: true
  attr :public_id, :string, required: true
  attr :may_runs, :boolean, required: true

  # An instance's current run: a link to its page for a reader of the record.
  defp run_link(assigns) do
    ~H"""
    <.link
      :if={@may_runs}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@public_id}"}
      class="q-mono text-accent hover:underline"
    >
      {gettext("run %{id}", id: short_id(@public_id))}
    </.link>
    <span :if={!@may_runs} class="q-mono">{short_id(@public_id)}</span>
    """
  end

  # A running instance's row's DOM id: its instance id is a claim, any characters.
  defp instance_dom_id(instance_id),
    do: "node-instance-" <> Integer.to_string(:erlang.phash2(instance_id))

  attr :scope, Apiary.Accounts.Scope, required: true
  attr :node, Node, required: true
  attr :form, :any, required: true
  attr :may_edit, :boolean, required: true
  attr :may_set_limit, :boolean, required: true
  attr :may_delete, :boolean, required: true
  attr :deleting, :boolean, required: true, doc: "whether the deletion's confirmation is open"

  attr :delete_refused, :any,
    required: true,
    doc: "why a gateway's deletion was refused, in words, or nil"

  attr :gateways, :list, required: true
  attr :default, :any, required: true
  attr :paths, :map, required: true

  # Settings › General: the name, the kind as it is, a pool's limit, a gateway's URL or a
  # node's choice of gateway, and the danger zone.
  defp general(assigns) do
    ~H"""
    <div :if={!@may_edit and !@may_set_limit} id="node-settings-readonly">
      <.notice kind={:info}>
        {NodeComponents.managed_by(
          @scope,
          :"node.edit",
          gettext("Only owners and admins change these settings.")
        )}
      </.notice>
    </div>

    <SettingsComponents.part id="node-general">
      <.form
        for={@form}
        id="node-form"
        phx-change="validate"
        phx-submit="save"
        class="q-form"
        novalidate
      >
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Name")}
          debounce="200"
          autocomplete="off"
          spellcheck="false"
          disabled={!@may_edit}
          required
        />
        <div id="node-kind-field" class="grid gap-1 text-[13px]/5">
          <span class="font-medium">{gettext("Kind")}</span>
          <span>
            {kind_sentence(@node.kind)}
            <span class="text-muted">{gettext("It can't be changed.")}</span>
          </span>
        </div>
        <.input
          :if={@node.kind == :pool}
          field={@form[:instance_limit]}
          type="text"
          inputmode="numeric"
          label={gettext("Instance limit")}
          hint={
            if @may_edit and !@may_set_limit,
              do: NodeComponents.limit_refused(@scope),
              else:
                gettext(
                  "Empty means no limit. Lowering it stops nothing running now; new instances wait until fewer run."
                )
          }
          autocomplete="off"
          disabled={!@may_set_limit}
          optional
        />
        <div :if={@node.kind == :node} id="node-limit-field" class="grid gap-1 text-[13px]/5">
          <span class="font-medium">{gettext("Instance limit")}</span>
          <span>{gettext("1. A node runs one instance at a time.")}</span>
        </div>
        <.input
          :if={@node.kind == :gateway}
          field={@form[:url]}
          type="text"
          inputmode="url"
          label={gettext("URL")}
          hint={NodeComponents.url_hint(:settings)}
          debounce="200"
          autocomplete="off"
          spellcheck="false"
          disabled={!@may_edit}
          required
        />
        <NodeComponents.gateway_field
          :if={@node.kind != :gateway and (@gateways != [] or @node.gateway_choice != :direct)}
          form={@form}
          gateways={@gateways}
          default={@default}
          offer_default={@default != nil or @node.gateway_choice == :default}
          disabled={!@may_edit}
        />
        <SettingsComponents.save :if={@may_edit or @may_set_limit}>
          <.button
            id="node-save"
            type="submit"
            variant="primary"
            disabled={!@form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
          <:note>{gettext("Owners and admins can change these.")}</:note>
        </SettingsComponents.save>
      </.form>
    </SettingsComponents.part>

    <SettingsComponents.danger_zone :if={@may_delete} id="node-danger">
      <SettingsComponents.danger_action
        id="delete-node"
        title={delete_title(@node.kind)}
        button={delete_button(@node.kind)}
        open={@deleting}
        open_path={@paths.delete}
        close_path={@paths.settings}
        question={gettext("Delete %{name}?", name: @node.name)}
        submit="delete"
      >
        {cond do
          @node.kind == :gateway and is_nil(@node.workspace_id) ->
            gettext(
              "It leaves %{organisation}'s gateways, its access keys are revoked and its name is free again. A gateway that nodes or node pools still point to, or that runs still go through, isn't deleted.",
              organisation: @scope.organisation.name
            )

          @node.kind == :gateway ->
            gettext(
              "It leaves this workspace's gateways, its access keys are revoked and its name is free again. A gateway that nodes or node pools still point to, or that runs still go through, isn't deleted."
            )

          true ->
            gettext(
              "It leaves this workspace's nodes, its access keys are revoked and its name is free again. Its runs stay in the record."
            )
        end}
        <:lost>
          {cond do
            @node.kind == :gateway and is_nil(@node.workspace_id) ->
              gettext(
                "%{name} leaves %{organisation}'s gateways at once, and its name is free again. Its access keys are revoked, and a command not yet run is cancelled. While nodes or node pools point to it, or runs still go through it, it isn't deleted. This cannot be undone.",
                name: @node.name,
                organisation: @scope.organisation.name
              )

            @node.kind == :gateway ->
              gettext(
                "%{name} leaves this workspace's gateways at once, and its name is free again. Its access keys are revoked, and a command not yet run is cancelled. While nodes or node pools point to it, or runs still go through it, it isn't deleted. This cannot be undone.",
                name: @node.name
              )

            true ->
              gettext(
                "%{name} leaves this workspace's nodes at once, and its name is free again. Its access keys are revoked, and a command not yet run is cancelled. Its runs stay in the record. This cannot be undone.",
                name: @node.name
              )
          end}
        </:lost>
      </SettingsComponents.danger_action>
      <.delete_refused :if={@delete_refused} words={@delete_refused} />
    </SettingsComponents.danger_zone>
    """
  end

  attr :words, :string, required: true

  # Why a gateway was not deleted, under its line, in an error notice.
  defp delete_refused(assigns) do
    ~H"""
    <div id="delete-node-refused">
      <.notice kind={:error}>{@words}</.notice>
    </div>
    """
  end

  defp delete_title(:node), do: gettext("Delete this node")
  defp delete_title(:pool), do: gettext("Delete this node pool")
  defp delete_title(:gateway), do: gettext("Delete this gateway")

  defp delete_button(:node), do: gettext("Delete node…")
  defp delete_button(:pool), do: gettext("Delete node pool…")
  defp delete_button(:gateway), do: gettext("Delete gateway…")

  defp kind_sentence(:node), do: gettext("Node: one permanent machine.")

  defp kind_sentence(:gateway),
    do: gettext("Gateway: the runs of nodes and node pools that choose it go through it.")

  defp kind_sentence(:pool),
    do: gettext("Node pool: short-lived instances that share one access key.")

  defp limit_words(%Node{kind: :node}), do: gettext("1, one instance at a time")
  defp limit_words(%Node{instance_limit: nil}), do: gettext("No limit")
  defp limit_words(%Node{instance_limit: limit}), do: Format.number(limit)
end
