defmodule ApiaryWeb.NodeLive.Index do
  @moduledoc """
  The workspace's nodes and node pools, `/:org/:workspace/nodes`, the places its runs
  run, on the list pattern (`docs/ui.md`, Lists): one line a node, its name the title
  with its public id beside it, its kind in words only for a pool, and its state, which
  says "Never seen" until an instance of it has reported. The list is narrowed by one
  search, `?q=`, words of a name or an id, and the Filter menu's Kind, `?kind=node` or
  `?kind=pool`, both in the URL.

  Owners and admins make a node or a node pool here (`node.create`), each a dialog over
  the list at a path of its own, `/nodes/new` and `/nodes/new-pool`; the kind is the
  dialog's and never changes after. Making one leads to its Settings. Everyone in the
  workspace reads the list (`node.read`); a member sees it without the buttons, and a
  dialog's path refuses them.

  The workspace's sidebar has no entry for it yet: the page is reached by its path.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, Nodes}
  alias Apiary.Nodes.Node

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: gettext("Nodes"),
       may_create: Access.can?(scope, :"node.create", scope.workspace),
       form: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{q: blank(params["q"]), kind: kind(params["kind"])}

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> load()
     |> apply_action(socket.assigns.live_action)}
  end

  defp apply_action(socket, :index), do: assign(socket, :form, nil)

  defp apply_action(socket, action) when action in [:new, :new_pool] do
    if socket.assigns.may_create do
      kind = if action == :new, do: :node, else: :pool
      assign_form(socket, Nodes.change_new_node(Nodes.new_node(kind)))
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

  defp load(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      nodes: Nodes.list_nodes(scope, socket.assigns.filters),
      counts: Nodes.count_nodes(scope)
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    filters = %{socket.assigns.filters | q: blank(q)}
    {:noreply, push_patch(socket, to: list_path(socket.assigns.current_scope, filters))}
  end

  def handle_event("validate", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    changeset =
      socket.assigns.form.data
      |> Nodes.change_new_node(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    %Node{kind: kind} = socket.assigns.form.data
    scope = socket.assigns.current_scope

    case Nodes.create_node(scope, Map.put(params, "kind", Atom.to_string(kind))) do
      {:ok, node} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is added.", name: node.name))
         |> push_navigate(
           to: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/settings"
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, refused(socket)}
    end
  end

  # A dialog's event with no dialog open: a page that offered none, or one whose dialog
  # has closed. Only one who may add nodes is shown the list again.
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

  # The list's path with `filters`: `q` and `kind`, each only when set.
  defp list_path(scope, filters) do
    query =
      [q: filters[:q], kind: filters[:kind]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/#{scope.organisation}/#{scope.workspace}/nodes?#{query}"
  end

  defp narrowed?(filters), do: not is_nil(filters.q) or not is_nil(filters.kind)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:workspace}
    >
      <:crumb>{gettext("Nodes")}</:crumb>

      <.header>
        {gettext("Nodes")}
        <:subtitle>
          {gettext(
            "Where the runs of this workspace run. A node is one permanent machine; a node pool is a fleet of short-lived instances that share one access key."
          )}
        </:subtitle>
        <:actions :if={@may_create}>
          <.button id="new-node-pool" patch={new_path(@current_scope, :pool)}>
            <.icon name="hero-plus-micro" class="size-4" />{gettext("New node pool")}
          </.button>
          <.button id="new-node" variant="primary" patch={new_path(@current_scope, :node)}>
            <.icon name="hero-plus-micro" class="size-4" />{gettext("New node")}
          </.button>
        </:actions>
      </.header>

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
        </div>

        <.filter_tokens
          id="nodes-tokens"
          clear={narrowed?(@filters) && list_path(@current_scope, %{q: nil, kind: nil})}
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
            title={gettext("No node matches")}
          >
            <p>{gettext("Nothing here has that name, id or kind.")}</p>
            <:actions>
              <.button patch={list_path(@current_scope, %{q: nil, kind: nil})}>
                {gettext("Clear filters")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <.table
          :if={@nodes != []}
          id="nodes"
          label={gettext("Nodes")}
          rows={@nodes}
          row_id={&"node-#{&1.public_id}"}
        >
          <:col :let={node} label={gettext("Name")} kind="title">
            <span class="q-nm">
              <.link
                navigate={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/nodes/#{node}"
                }
                class="q-title hover:underline"
              >
                {node.name}
              </.link>
              <span class="q-side q-mono">{node.public_id}</span>
            </span>
          </:col>
          <:col :let={node} label={gettext("Kind")} from="sm">
            <span :if={node.kind == :pool} id={"node-#{node.public_id}-kind"}>
              {gettext("Pool")}
            </span>
            <span :if={node.kind == :node} class="sr-only">{gettext("Node")}</span>
          </:col>
          <:col :let={node} label={gettext("State")}>
            <span id={"node-#{node.public_id}-state"} class="q-faint">
              {gettext("Never seen")}
            </span>
          </:col>
        </.table>
      </div>

      <.modal
        :if={@form}
        id="new-node-dialog"
        title={if @form.data.kind == :node, do: gettext("New node"), else: gettext("New node pool")}
        on_cancel={JS.patch(list_path(@current_scope, @filters))}
      >
        <p class="text-[13px]/[18px] text-muted">
          {if @form.data.kind == :node,
            do: gettext("One permanent machine. It runs one instance at a time."),
            else: gettext("Short-lived instances that share one access key.")}
          {gettext("You can't change the kind later.")}
        </p>
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
            placeholder={if @form.data.kind == :node, do: "build-01", else: "spot-runners"}
            autocomplete="off"
            spellcheck="false"
            required
          />
          <.input
            :if={@form.data.kind == :pool}
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
        </.form>
        <:footer>
          <.button patch={list_path(@current_scope, @filters)}>{gettext("Cancel")}</.button>
          <.button
            id="new-node-submit"
            variant="primary"
            type="submit"
            form="new-node-form"
            loading_text={gettext("Adding")}
          >
            {if @form.data.kind == :node,
              do: gettext("Add node"),
              else: gettext("Add node pool")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  defp new_path(scope, :node), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new"
  defp new_path(scope, :pool), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new-pool"

  defp kind_label(:node), do: gettext("Node")
  defp kind_label(:pool), do: gettext("Node pool")
end
