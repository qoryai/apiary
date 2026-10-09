defmodule ApiaryWeb.NodeLive.Index do
  @moduledoc """
  The workspace's nodes and node pools, `/:org/:workspace/nodes`, the places its runs
  run, on the list pattern (`docs/ui.md`, Lists): one line a node, its name the title
  with its public id beside it, its kind in words only for a pool, its state
  (`ApiaryWeb.NodeComponents.node_state/1`: "Running", "3 of 10 running", "Last seen …"
  or "Never seen") and Forager's version it last reported. Under a pool's line, its
  running instances as indented lines, ten at most, then "and 12 more", which leads to the
  pool's page; an instance shows only while it runs. A Node has none: its one instance
  is its line.

  The views are All, Running and Not running (`?view=running`, `?view=idle`), each counted
  under the search and the kind. The list is narrowed by one search, `?q=`, words of a
  name or an id, and the Filter menu's Kind, `?kind=node` or `?kind=pool`, and sorted by
  name or by Last seen (`?sort=seen`: running first, then the last seen first, never seen
  last), all in the URL.

  Owners and admins make a node or a node pool here (`node.create`), each a page of its
  own, `/nodes/new` and `/nodes/new-pool`, on the pattern of a form page (`docs/ui.md`, A
  form is a page): the breadcrumb `Nodes / New node`, the page's heading and one sentence,
  the form in the 720 px column, its button and Cancel back to the list
  (`ApiaryWeb.PageComponents.page_form/1`). The kind is the page's and never changes
  after. Making one leads to its Access key tab, with a flash.
  Everyone in the workspace reads the list (`node.read`); a member sees it without the
  buttons, and a form's path refuses them.

  The sidebar's Nodes leads here: the pages pass `nav: :nodes`, so Nodes is the current entry
  on the list and on the New node and New node pool forms.

  Live: the list reads the nodes and what they do again on `{:nodes_touched, …}`
  (`Apiary.Nodes.topic/1`), on a `{:run_changed, run}` of a run on a node, at most every
  250 ms, and every 15 seconds, since an instance stops running without an event when its
  runs fall silent.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, Nodes, Runs}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run
  alias ApiaryWeb.NodeComponents

  @tick :timer.seconds(15)
  @coalesce_ms 250
  # A pool's running instances shown under its line, before "and N more".
  @sub_rows 10

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    may_runs = Access.can?(scope, :"run.read", scope.workspace)

    if connected?(socket) do
      Nodes.subscribe(scope)
      if may_runs, do: Runs.subscribe(scope)
      Process.send_after(self(), :tick, @tick)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Nodes"),
       may_create: Access.can?(scope, :"node.create", scope.workspace),
       may_runs: may_runs,
       reload_scheduled: false,
       form: nil,
       kind: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      q: blank(params["q"]),
      kind: kind(params["kind"]),
      view: view(params["view"]),
      sort: sort(params["sort"])
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> load()
     |> apply_action(socket.assigns.live_action)}
  end

  defp apply_action(socket, :index),
    do: assign(socket, form: nil, kind: nil, page_title: gettext("Nodes"))

  defp apply_action(socket, action) when action in [:new, :new_pool] do
    if socket.assigns.may_create do
      kind = if action == :new, do: :node, else: :pool

      socket
      |> assign_form(Nodes.change_new_node(Nodes.new_node(kind)))
      |> assign(kind: kind, page_title: form_title(kind) <> " · " <> gettext("Nodes"))
    else
      socket
      |> put_flash(:error, gettext("Only owners and admins add nodes."))
      |> push_patch(to: list_path(socket.assigns.current_scope, socket.assigns.filters))
    end
  end

  defp blank(q) when is_binary(q), do: if(String.trim(q) == "", do: nil, else: q)
  defp blank(_q), do: nil

  defp kind("node"), do: :node
  defp kind("pool"), do: :pool
  defp kind(_kind), do: nil

  defp view("running"), do: :running
  defp view("idle"), do: :idle
  defp view(_view), do: nil

  defp sort("seen"), do: :seen
  defp sort(_sort), do: nil

  # The nodes under the search and the kind, what each is doing now, the views' counts
  # over them, and the rows of the view in force, in its order. A form's page shows none
  # of it: the list is read when it is opened again.
  defp load(%{assigns: %{live_action: action}} = socket) when action != :index, do: socket

  defp load(socket) do
    scope = socket.assigns.current_scope
    filters = socket.assigns.filters
    now = DateTime.utc_now()
    nodes = Nodes.list_nodes(scope, Map.take(filters, [:q, :kind]))
    activity = Nodes.activity(scope, nodes, now)
    running? = &(activity[&1.id].running != [])
    shown = Enum.filter(nodes, &in_view?(filters.view, running?.(&1)))

    assign(socket,
      nodes: shown,
      rows: rows(sorted(shown, activity, filters.sort), activity),
      activity: activity,
      views: %{
        all: length(nodes),
        running: Enum.count(nodes, running?),
        idle: Enum.count(nodes, &(not running?.(&1)))
      },
      counts: Nodes.count_nodes(scope)
    )
  end

  defp in_view?(:running, running?), do: running?
  defp in_view?(:idle, running?), do: not running?
  defp in_view?(nil, _running?), do: true

  defp sorted(nodes, _activity, nil), do: nodes

  defp sorted(nodes, activity, :seen) do
    Enum.sort_by(nodes, fn node ->
      case activity[node.id] do
        %{running: [_ | _]} ->
          {0, 0, node.name}

        %{} = activity ->
          case NodeComponents.seen_at(activity) do
            nil -> {2, 0, node.name}
            at -> {1, -DateTime.to_unix(at, :microsecond), node.name}
          end

        nil ->
          {2, 0, node.name}
      end
    end)
  end

  # The table's rows: each node, and under a pool its running instances, at most
  # #{@sub_rows}, then how many more.
  defp rows(nodes, activity) do
    Enum.flat_map(nodes, fn node ->
      running = activity[node.id].running

      case node.kind do
        :pool ->
          more = length(running) - @sub_rows

          [{:node, node}] ++
            Enum.map(Enum.take(running, @sub_rows), &{:instance, node, &1}) ++
            if(more > 0, do: [{:more, node, more}], else: [])

        :node ->
          [{:node, node}]
      end
    end)
  end

  @impl true
  def handle_info({:nodes_touched, _workspace_id}, socket),
    do: {:noreply, schedule_reload(socket)}

  def handle_info({:run_changed, %Run{node_id: id}}, socket) when is_binary(id),
    do: {:noreply, schedule_reload(socket)}

  def handle_info(:reload, socket),
    do: {:noreply, socket |> assign(:reload_scheduled, false) |> load()}

  # Running ends without an event when a run falls silent: the list looks again.
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_reload(%{assigns: %{reload_scheduled: true}} = socket), do: socket

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload, @coalesce_ms)
    assign(socket, :reload_scheduled, true)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    filters = %{socket.assigns.filters | q: blank(q)}
    {:noreply, push_patch(socket, to: list_path(socket.assigns.current_scope, filters))}
  end

  def handle_event("validate", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    changeset =
      socket.assigns.kind
      |> Nodes.new_node()
      |> Nodes.change_new_node(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    kind = socket.assigns.kind
    scope = socket.assigns.current_scope

    case Nodes.create_node(scope, Map.put(params, "kind", Atom.to_string(kind))) do
      {:ok, node} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is added.", name: node.name))
         |> push_navigate(
           to: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/access-key"
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, refused(socket)}
    end
  end

  # A form's event with no form open: the list, which has none, or a form page that has
  # been left. Only one who may add nodes is shown the list again.
  def handle_event(event, _params, socket) when event in ~w(validate create) do
    if socket.assigns.may_create,
      do: {:noreply, load(socket)},
      else: {:noreply, refused(socket)}
  end

  # The membership this page was opened with no longer allows it, or is gone: one who
  # still reads the workspace is told so on the list; anyone else is sent to `/`.
  defp refused(socket) do
    scope = Access.reload(socket.assigns.current_scope)
    path = list_path(socket.assigns.current_scope, socket.assigns.filters)

    cond do
      Access.reader(scope) ->
        socket |> put_flash(:error, ApiaryWeb.Access.reads_only(scope)) |> push_patch(to: path)

      Access.can?(scope, :"node.read", scope.workspace) ->
        socket
        |> assign(:may_create, false)
        |> put_flash(:error, gettext("Only owners and admins add nodes."))
        |> push_patch(to: path)

      true ->
        socket
        |> put_flash(:error, gettext("You are no longer a member of this workspace."))
        |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :node))

  # The list's path with `filters`: `q`, `kind`, `view` and `sort`, each only when set.
  defp list_path(scope, filters) do
    query =
      [
        q: filters[:q],
        kind: filters[:kind],
        view: filters[:view],
        sort: filters[:sort]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/#{scope.organisation}/#{scope.workspace}/nodes?#{query}"
  end

  defp narrowed?(filters), do: not is_nil(filters.q) or not is_nil(filters.kind)

  defp cleared(filters), do: %{filters | q: nil, kind: nil}

  defp sort_label(nil), do: gettext("Name")
  defp sort_label(:seen), do: gettext("Last seen")

  defp row_id({:node, node}), do: "node-#{node.public_id}"

  defp row_id({:instance, node, instance}),
    do: "node-#{node.public_id}-instance-#{:erlang.phash2(instance.instance_id)}"

  defp row_id({:more, node, _more}), do: "node-#{node.public_id}-more"

  defp node_path(scope, node), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}"

  # Forager's version a node's line says: its running instance's, else the last seen's.
  defp runner_version(%{running: [%{runner_version: version} | _]}) when is_binary(version),
    do: version

  defp runner_version(%{last: %{last_runner_version: version}}), do: version
  defp runner_version(_activity), do: nil

  @impl true
  # A form is a page of the Nodes section, as Add integration is of Settings: the
  # breadcrumb ending with Nodes and the page, its heading and one sentence, the form in
  # the 720 px column, its button and Cancel back to the list.
  def render(%{form: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
      width="read"
    >
      <:crumb navigate={list_path(@current_scope, @filters)}>{gettext("Nodes")}</:crumb>
      <:crumb>{form_title(@kind)}</:crumb>

      <.page_form
        id="new-node"
        title={form_title(@kind)}
        cancel={list_path(@current_scope, @filters)}
        cancel_by="patch"
      >
        <:description>
          {if @kind == :node,
            do: gettext("One permanent machine. It runs one instance at a time."),
            else: gettext("Short-lived instances that share one access key.")}
          {gettext("You can't change the kind later.")}
        </:description>
        <.form
          for={@form}
          id="new-node-form"
          phx-change="validate"
          phx-submit="create"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={if @kind == :node, do: "build-01", else: "spot-runners"}
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            :if={@kind == :pool}
            field={@form[:instance_limit]}
            type="text"
            inputmode="numeric"
            label={gettext("Instance limit")}
            hint={
              gettext("How many instances may run at once, up to %{max}. Empty means no limit.",
                max: Format.number(Node.max_limit())
              )
            }
            autocomplete="off"
            optional
          />
          <.page_form_foot
            id="new-node-save"
            cancel={list_path(@current_scope, @filters)}
            cancel_by="patch"
          >
            <.button
              id="new-node-submit"
              variant="primary"
              type="submit"
              loading_text={gettext("Adding")}
            >
              {if @kind == :node,
                do: gettext("Add node"),
                else: gettext("Add node pool")}
            </.button>
          </.page_form_foot>
        </.form>
      </.page_form>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
    >
      <:crumb>{gettext("Nodes")}</:crumb>

      <.page_header title={gettext("Nodes")}>
        <:description>
          {gettext(
            "A node is one permanent machine; a node pool is a fleet of short-lived instances that share one access key."
          )}
        </:description>
        <:actions :if={@may_create}>
          <.button id="new-node" patch={new_path(@current_scope, :node)}>
            <.icon name="hero-plus-micro" class="size-4" />{gettext("New node")}
          </.button>
          <.button id="new-node-pool" patch={new_path(@current_scope, :pool)}>
            <.icon name="hero-plus-micro" class="size-4" />{gettext("New node pool")}
          </.button>
        </:actions>
      </.page_header>

      <div :if={@counts.node + @counts.pool == 0} id="nodes-empty">
        <.empty_state icon="hero-server-stack" tone="neutral" title={gettext("No nodes yet")}>
          <p :if={@may_create}>
            {gettext(
              "Add a node for a machine that is always there, or a node pool for instances that come and go."
            )}
          </p>
          <p :if={!@may_create}>{gettext("An owner or admin adds nodes.")}</p>
          <:actions :if={@may_create}>
            <.button patch={new_path(@current_scope, :node)}>{gettext("New node")}</.button>
            <.button patch={new_path(@current_scope, :pool)}>{gettext("New node pool")}</.button>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@counts.node + @counts.pool > 0} class="grid gap-3">
        <.views id="nodes-views" label={gettext("Views")}>
          <:view
            id="nodes-view-all"
            patch={list_path(@current_scope, %{@filters | view: nil})}
            current={@filters.view == nil}
            count={Format.number(@views.all)}
          >
            {gettext("All")}
          </:view>
          <:view
            id="nodes-view-running"
            patch={list_path(@current_scope, %{@filters | view: :running})}
            current={@filters.view == :running}
            count={Format.number(@views.running)}
          >
            {gettext("Running")}
          </:view>
          <:view
            id="nodes-view-idle"
            patch={list_path(@current_scope, %{@filters | view: :idle})}
            current={@filters.view == :idle}
            count={Format.number(@views.idle)}
          >
            {gettext("Not running")}
          </:view>
        </.views>

        <div class="q-bar">
          <.list_search
            id="nodes-search"
            value={@filters.q}
            label={gettext("Find a node")}
            placeholder={gettext("Find a node by its name or id")}
          />
          <.filter_menu id="nodes-filter" count={if(@filters.kind, do: 1, else: 0)}>
            <.menu_heading title={gettext("Kind")} />
            <.menu_item
              :for={kind <- Node.kinds()}
              id={"nodes-filter-kind-#{kind}"}
              patch={
                list_path(@current_scope, %{
                  @filters
                  | kind: if(@filters.kind == kind, do: nil, else: kind)
                })
              }
              checked={@filters.kind == kind}
              hint={
                ngettext("%{number} node", "%{number} nodes", @counts[kind],
                  number: Format.number(@counts[kind])
                )
              }
            >
              {kind_label(kind)}
            </.menu_item>
          </.filter_menu>
          <.sort_menu id="nodes-sort" current={sort_label(@filters.sort)}>
            <.menu_item
              :for={sort <- [nil, :seen]}
              id={"nodes-sort-#{sort || :name}"}
              patch={list_path(@current_scope, %{@filters | sort: sort})}
              checked={@filters.sort == sort}
            >
              {sort_label(sort)}
            </.menu_item>
          </.sort_menu>
        </div>

        <.filter_tokens
          id="nodes-tokens"
          clear={narrowed?(@filters) && list_path(@current_scope, cleared(@filters))}
        >
          <:token
            :if={@filters.kind}
            id="nodes-token-kind"
            patch={list_path(@current_scope, %{@filters | kind: nil})}
            label={gettext("Remove %{filter}", filter: kind_label(@filters.kind))}
          >
            {kind_label(@filters.kind)}
          </:token>
        </.filter_tokens>

        <%!-- Always there, so a screen reader hears what the search left. --%>
        <div id="nodes-status" role="status" class="q-status">
          <p :if={narrowed?(@filters) && @nodes != []} id="nodes-summary">
            {ngettext("%{number} node matches", "%{number} nodes match", length(@nodes),
              number: Format.number(length(@nodes))
            )}
          </p>
          <.empty_state
            :if={@nodes == []}
            icon={nil}
            tone="neutral"
            title={
              if narrowed?(@filters), do: gettext("No node matches"), else: gettext("No node here")
            }
          >
            <p :if={narrowed?(@filters)}>{gettext("Nothing here has that name, id or kind.")}</p>
            <p :if={!narrowed?(@filters)}>
              {if @filters.view == :running,
                do: gettext("No node is running now."),
                else: gettext("Every node is running now.")}
            </p>
            <:actions :if={narrowed?(@filters)}>
              <.button patch={list_path(@current_scope, cleared(@filters))}>
                {gettext("Clear filters")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <.table
          :if={@nodes != []}
          id="nodes"
          label={gettext("Nodes")}
          rows={@rows}
          row_id={&row_id/1}
        >
          <:col :let={row} label={gettext("Name")} kind="title">
            <%= case row do %>
              <% {:node, node} -> %>
                <span class="q-nm">
                  <.link navigate={node_path(@current_scope, node)} class="q-title hover:underline">
                    {node.name}
                  </.link>
                  <span class="q-side q-mono">{node.public_id}</span>
                </span>
              <% {:instance, _node, instance} -> %>
                <span class="q-nm pl-5 font-normal">
                  <.icon name="hero-arrow-turn-down-right-micro" class="size-3.5 text-faint" />
                  <span>{instance.name || instance.instance_id}</span>
                  <span :if={instance.name} class="q-side q-mono">{instance.instance_id}</span>
                </span>
              <% {:more, node, more} -> %>
                <.link
                  id={"node-#{node.public_id}-more-link"}
                  navigate={node_path(@current_scope, node)}
                  class="pl-5 text-[12.5px] font-normal text-accent hover:underline"
                >
                  {ngettext("and %{number} more", "and %{number} more", more,
                    number: Format.number(more)
                  )}
                </.link>
            <% end %>
          </:col>
          <:col :let={row} label={gettext("Kind")} from="sm">
            <%= case row do %>
              <% {:node, %{kind: :pool} = node} -> %>
                <span id={"node-#{node.public_id}-kind"}>{gettext("Pool")}</span>
              <% {:node, _node} -> %>
                <span class="sr-only">{gettext("Node")}</span>
              <% _instance -> %>
            <% end %>
          </:col>
          <:col :let={row} label={gettext("State")}>
            <%= case row do %>
              <% {:node, node} -> %>
                <NodeComponents.node_state
                  id={"node-#{node.public_id}-state"}
                  node={node}
                  activity={@activity[node.id]}
                />
              <% {:instance, _node, instance} -> %>
                {gettext("Running since")} <.relative_time format="clock" at={instance.since} />
                <.link
                  :if={@may_runs}
                  navigate={
                    ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs/#{instance.run_id}"
                  }
                  class="q-mono text-accent hover:underline"
                >
                  {gettext("run %{id}", id: short_id(instance.run_id))}
                </.link>
              <% _more -> %>
            <% end %>
          </:col>
          <:col :let={row} label={gettext("Forager")} kind="faint" from="md">
            <%= case row do %>
              <% {:node, node} -> %>
                {runner_version(@activity[node.id])}
              <% {:instance, _node, instance} -> %>
                {instance.runner_version}
              <% _more -> %>
            <% end %>
          </:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end

  defp new_path(scope, :node), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new"
  defp new_path(scope, :pool), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new-pool"

  # A form page's title and its breadcrumb's last segment: the act, by the kind.
  defp form_title(:node), do: gettext("New node")
  defp form_title(:pool), do: gettext("New node pool")

  defp kind_label(kind), do: NodeComponents.kind_label(kind)
end
