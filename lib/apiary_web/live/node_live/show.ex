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
    dialog, at `/nodes/:node_id/instances/:instance/clear`.
  - **Settings** (`/nodes/:node_id/settings`), with the node's list of sections
    (`ApiaryWeb.SettingsComponents`): General, its name, its kind (shown, fixed) and a
    pool's instance limit, then the danger zone, whose Delete expands its confirmation in
    place, at `/nodes/:node_id/settings/delete`.

  Everyone in the workspace reads the page (`node.read`); owners and admins change the
  node (`node.edit`), delete it (`node.delete`) and clear an instance
  (`node.clear_instance`). A member reads Settings with its fields disabled and no danger
  zone, sees no Clear instance, and the deletion's and the clearing's paths refuse them.

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

  alias Apiary.{Access, Nodes, Runs}
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Runs.{Filters, Run}
  alias ApiaryWeb.{NodeComponents, People, SettingsComponents, UserAuth}

  @tick :timer.seconds(15)
  @coalesce_ms 250
  @recent 5

  @impl true
  def mount(%{"node_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Nodes.get_node(scope, public_id) do
      %Node{} = node ->
        socket =
          socket
          |> assign(page_title: node.name, node: node, paths: paths(scope, node.public_id))
          |> assign(sections: SettingsComponents.sections(scope, {:node, node}))
          |> assign(clearing: nil, recent: nil, reload_scheduled: false)
          |> assign_may()
          |> assign_form(Nodes.change_node(node))
          |> assign_activity()
          |> UserAuth.on_membership_change(&assign_may/1)

        if connected?(socket) do
          Nodes.subscribe(scope)
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
      may_delete: Access.can?(scope, :"node.delete", node),
      may_clear: Access.can?(scope, :"node.clear_instance", node),
      may_runs: Access.can?(scope, :"run.read", scope.workspace)
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
    paths = paths(socket.assigns.current_scope, public_id)
    {:noreply, push_navigate(socket, to: paths.overview)}
  end

  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :overview, _params),
    do: assign(socket, page_title: socket.assigns.node.name, clearing: nil)

  defp apply_action(socket, :clear_instance, %{"instance" => instance_id}) do
    cond do
      not socket.assigns.may_clear ->
        socket
        |> put_flash(:error, gettext("Only owners and admins clear instances."))
        |> push_patch(to: node_path(socket, :overview))

      clearing = clearing(socket, instance_id) ->
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
      assign(socket, :page_title, settings_title(socket.assigns.node))
    else
      socket
      |> put_flash(:error, gettext("Only owners and admins delete nodes."))
      |> push_patch(to: node_path(socket, :settings))
    end
  end

  # The instance the confirmation clears: one running now, or one the record holds a row of.
  defp clearing(socket, instance_id) do
    %{current_scope: scope, node: node, activity: activity} = socket.assigns

    case Enum.find(activity.running, &(&1.instance_id == instance_id)) do
      %{} = running ->
        %{instance_id: instance_id, name: running.name}

      nil ->
        case Instance.instance_id?(instance_id) && Nodes.get_instance(scope, node, instance_id) do
          %Instance{name: name} -> %{instance_id: instance_id, name: name}
          _none -> nil
        end
    end
  end

  defp settings_title(node), do: gettext("Settings · %{name}", name: node.name)

  @impl true
  def handle_event("validate", %{"node" => params}, socket) do
    changeset =
      socket.assigns.node
      |> Nodes.change_node(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"node" => params}, socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.update_node(scope, node, params) do
      {:ok, updated} ->
        updated = %{updated | created_by: node.created_by}

        {:noreply,
         socket
         |> assign(node: updated, page_title: settings_title(updated))
         |> assign_form(Nodes.change_node(updated))
         |> put_flash(:info, gettext("%{name} is saved.", name: updated.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins change nodes."), :settings)}
    end
  end

  def handle_event("delete", _params, %{assigns: %{live_action: :delete}} = socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.delete_node(scope, node) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is deleted.", name: deleted.name))
         |> push_navigate(to: ~p"/#{scope.organisation}/#{scope.workspace}/nodes")}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins delete nodes."), :settings)}
    end
  end

  # A deletion without its confirmation open: a page that offered none, or a confirmation
  # that has folded. One who may delete the node is shown the page again; anyone else is refused.
  def handle_event("delete", _params, socket) do
    if socket.assigns.may_delete,
      do: {:noreply, socket},
      else:
        {:noreply, refused(socket, gettext("Only owners and admins delete nodes."), :settings)}
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
        if Nodes.get_node(scope, node.public_id),
          do:
            {:noreply,
             socket
             |> put_flash(:error, gettext("This node has no such instance."))
             |> push_patch(to: node_path(socket, :overview))},
          else: {:noreply, gone(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins clear instances."), :overview)}
    end
  end

  # A clearing without its confirmation open: a page that offered none, or a confirmation
  # that has been cancelled. One who may clear is shown the page again; anyone else is refused.
  def handle_event("clear_instance", _params, socket) do
    if socket.assigns.may_clear,
      do: {:noreply, socket},
      else:
        {:noreply, refused(socket, gettext("Only owners and admins clear instances."), :overview)}
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

    case Nodes.get_node(scope, node.public_id) do
      %Node{} = current -> socket |> assign(:node, current) |> assign_activity() |> load_recent()
      nil -> gone(socket)
    end
  end

  # The node was deleted, or left the reader's reach, since the page opened.
  defp gone(socket) do
    %{organisation: organisation, workspace: workspace} = socket.assigns.current_scope

    socket
    |> put_flash(:error, gettext("This node is gone: it was deleted."))
    |> push_navigate(to: ~p"/#{organisation}/#{workspace}/nodes")
  end

  # A change the reader may not make, as the database has their membership now: one who
  # still reads the workspace is told why on the tab `back` names; one who reads the
  # organisation through the edition's reach is told so; anyone else is sent to `/`.
  defp refused(socket, why, back) do
    scope = Access.reload(socket.assigns.current_scope)

    cond do
      Access.reader(scope) ->
        socket
        |> put_flash(:error, ApiaryWeb.Access.reads_only(scope))
        |> push_patch(to: node_path(socket, back))

      Access.can?(scope, :"node.read", scope.workspace) ->
        socket
        |> assign(may_edit: false, may_delete: false, may_clear: false)
        |> assign_form(Nodes.change_node(socket.assigns.node))
        |> put_flash(:error, why)
        |> push_patch(to: node_path(socket, back))

      true ->
        socket
        |> put_flash(:error, gettext("You are no longer a member of this workspace."))
        |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :node))

  defp node_path(socket, action), do: Map.fetch!(socket.assigns.paths, action)

  # The page's paths: its tabs, the deletion's confirmation, and the node's runs on the list.
  defp paths(%{organisation: organisation, workspace: workspace}, public_id) do
    base = ~p"/#{organisation}/#{workspace}/nodes/#{public_id}"

    %{
      overview: base,
      access_key: base <> "/access-key",
      settings: base <> "/settings",
      delete: base <> "/settings/delete",
      runs: ~p"/#{organisation}/#{workspace}/runs?#{[node: public_id]}"
    }
  end

  # The path where an instance of the node is asked to be cleared.
  defp clear_path(scope, node, instance_id),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/instances/#{instance_id}/clear"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/nodes"}>
        {gettext("Nodes")}
      </:crumb>
      <:crumb navigate={@live_action != :overview && @paths.overview}>
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
        may_runs={@may_runs}
        recent={@recent}
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
          {gettext("The node's name, its kind and how many instances may run at once.")}
        </:subtitle>
        <.general
          node={@node}
          form={@form}
          may_edit={@may_edit}
          may_delete={@may_delete}
          deleting={@live_action == :delete}
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
  attr :may_runs, :boolean, required: true
  attr :recent, :any, required: true
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
      <SettingsComponents.part
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
              <span>{instance.name || instance.instance_id}</span>
              <span :if={instance.name} class="q-side q-mono">{instance.instance_id}</span>
            </span>
          </:col>
          <:col :let={instance} label={gettext("Running since")}>
            <.relative_time format="clock" at={instance.since} />
          </:col>
          <:col :let={instance} label={gettext("Run")} from="sm">
            <.run_link scope={@scope} run_id={instance.run_id} may_runs={@may_runs} />
          </:col>
          <:col :let={instance} label={gettext("Runner")} kind="faint" from="md">
            {instance.runner_version || gettext("n/a")}
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
                patch={clear_path(@scope, @node, instance.instance_id)}
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
          {if @node.kind == :pool,
            do:
              gettext(
                "No instance of this pool has reported yet. An instance shows here while it runs."
              ),
            else:
              gettext(
                "No instance of this node has reported yet. It shows here once it runs, running or when it was last seen."
              )}
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
          <dt class="text-faint">{gettext("Instance limit")}</dt>
          <dd id="node-about-limit">{limit_words(@node)}</dd>
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
          <.run_link scope={@scope} run_id={@running.run_id} may_runs={@may_runs} />
          <span :if={@running.runner_version} class="text-muted">
            {gettext("runner %{version}", version: @running.runner_version)}
          </span>
        <% else %>
          <span id="node-instance-name" class="font-medium">
            {@last.name || @last.instance_id}
          </span>
          <span :if={@last.name} class="q-mono text-muted">{@last.instance_id}</span>
          <span class="text-muted">
            {gettext("Last seen")}
            <.relative_time id="node-instance-seen" at={@last.last_seen_at} />
          </span>
          <span :if={@last.last_runner_version} class="text-muted">
            {gettext("runner %{version}", version: @last.last_runner_version)}
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
          patch={clear_path(@scope, @node, @running.instance_id)}
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
  attr :run_id, :string, required: true
  attr :may_runs, :boolean, required: true

  # An instance's current run: a link to its page for a reader of the record.
  defp run_link(assigns) do
    ~H"""
    <.link
      :if={@may_runs}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@run_id}"}
      class="q-mono text-accent hover:underline"
    >
      {gettext("run %{id}", id: short_id(@run_id))}
    </.link>
    <span :if={!@may_runs} class="q-mono">{short_id(@run_id)}</span>
    """
  end

  # A running instance's row's DOM id: its instance id is a claim, any characters.
  defp instance_dom_id(instance_id),
    do: "node-instance-" <> Integer.to_string(:erlang.phash2(instance_id))

  attr :node, Node, required: true
  attr :form, :any, required: true
  attr :may_edit, :boolean, required: true
  attr :may_delete, :boolean, required: true
  attr :deleting, :boolean, required: true, doc: "whether the deletion's confirmation is open"
  attr :paths, :map, required: true

  # Settings › General: the name, the kind as it is, a pool's limit, and the danger zone.
  defp general(assigns) do
    ~H"""
    <div :if={!@may_edit} id="node-settings-readonly">
      <.notice kind={:info}>{gettext("Only owners and admins change these settings.")}</.notice>
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
            gettext(
              "Empty means no limit. Lowering it stops nothing running now; new instances wait until fewer run."
            )
          }
          autocomplete="off"
          disabled={!@may_edit}
          optional
        />
        <div :if={@node.kind == :node} id="node-limit-field" class="grid gap-1 text-[13px]/5">
          <span class="font-medium">{gettext("Instance limit")}</span>
          <span>{gettext("1. A node runs one instance at a time.")}</span>
        </div>
        <SettingsComponents.save :if={@may_edit}>
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
        title={
          if @node.kind == :pool,
            do: gettext("Delete this node pool"),
            else: gettext("Delete this node")
        }
        button={
          if @node.kind == :pool,
            do: gettext("Delete node pool…"),
            else: gettext("Delete node…")
        }
        open={@deleting}
        open_path={@paths.delete}
        close_path={@paths.settings}
        question={gettext("Delete %{name}?", name: @node.name)}
        submit="delete"
      >
        {gettext(
          "It leaves this workspace's nodes, its access keys are revoked and its name is free again. Its runs stay in the record."
        )}
        <:lost>
          {gettext(
            "%{name} leaves this workspace's nodes at once, and its name is free again. Its access keys are revoked, and a command not yet run is cancelled. Its runs stay in the record. This cannot be undone.",
            name: @node.name
          )}
        </:lost>
      </SettingsComponents.danger_action>
    </SettingsComponents.danger_zone>
    """
  end

  defp kind_sentence(:node), do: gettext("Node: one permanent machine.")

  defp kind_sentence(:pool),
    do: gettext("Node pool: short-lived instances that share one access key.")

  defp limit_words(%Node{kind: :node}), do: gettext("1, one instance at a time")
  defp limit_words(%Node{instance_limit: nil}), do: gettext("No limit")
  defp limit_words(%Node{instance_limit: limit}), do: Format.number(limit)
end
