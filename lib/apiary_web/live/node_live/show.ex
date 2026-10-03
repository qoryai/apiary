defmodule ApiaryWeb.NodeLive.Show do
  @moduledoc """
  A node's or a node pool's page, `/:org/:workspace/nodes/:node_id`, where `:node_id` is
  the node's public id. A node the workspace does not have, or one that is deleted, is
  not found. Its two tabs are patches of this one LiveView, the operational side first
  and Settings last, set apart (`docs/ui.md`, Nodes):

  - **Overview** (`/nodes/:node_id`): what the node is doing. Its instance (a node's) or
    its running instances (a pool's), and its recent runs, as far as the record holds
    them: until an instance reports, each says so. Beside them, About: its kind, id,
    instance limit and who made it, with the way to its Settings.
  - **Settings** (`/nodes/:node_id/settings`), with the node's list of sections
    (`ApiaryWeb.SettingsComponents`): General, its name, its kind (shown, fixed) and a
    pool's instance limit, then the danger zone, whose Delete opens the confirm dialog at
    `/nodes/:node_id/settings/delete`.

  Everyone in the workspace reads the page (`node.read`); owners and admins change the
  node (`node.edit`) and delete it (`node.delete`). A member reads Settings with its
  fields disabled and no danger zone, and the dialog's path refuses them.

  The header names the node, its public id beside it, then one muted line: its kind, its
  state, and who made it and when. The breadcrumb's segments are Nodes, then the node.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, Nodes}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{People, SettingsComponents}

  @impl true
  def mount(%{"node_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Nodes.get_node(scope, public_id) do
      %Node{} = node ->
        {:ok,
         socket
         |> assign(page_title: node.name, node: node, paths: paths(scope, node.public_id))
         |> assign(sections: SettingsComponents.sections(scope, {:node, node}))
         |> assign_may()
         |> assign_form(Nodes.change_node(node))}

      nil ->
        raise Ecto.NoResultsError, queryable: Node
    end
  end

  defp assign_may(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    assign(socket,
      may_edit: Access.can?(scope, :"node.edit", node),
      may_delete: Access.can?(scope, :"node.delete", node)
    )
  end

  @impl true
  def handle_params(%{"node_id" => public_id}, _uri, %{assigns: %{node: node}} = socket)
      when public_id != node.public_id do
    paths = paths(socket.assigns.current_scope, public_id)
    {:noreply, push_navigate(socket, to: paths.overview)}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action)}

  defp apply_action(socket, :overview),
    do: assign(socket, :page_title, socket.assigns.node.name)

  defp apply_action(socket, :settings),
    do: assign(socket, :page_title, settings_title(socket.assigns.node))

  defp apply_action(socket, :delete) do
    if socket.assigns.may_delete do
      assign(socket, :page_title, settings_title(socket.assigns.node))
    else
      socket
      |> put_flash(:error, gettext("Only owners and admins delete nodes."))
      |> push_patch(to: node_path(socket, :settings))
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
        {:noreply, refused(socket, gettext("Only owners and admins change nodes."))}
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
        {:noreply, refused(socket, gettext("Only owners and admins delete nodes."))}
    end
  end

  # A deletion without its dialog open: a page that offered none, or a dialog that has
  # closed. One who may delete the node is shown the page again; anyone else is refused.
  def handle_event("delete", _params, socket) do
    if socket.assigns.may_delete,
      do: {:noreply, socket},
      else: {:noreply, refused(socket, gettext("Only owners and admins delete nodes."))}
  end

  # The node was deleted, or left the reader's reach, since the page opened.
  defp gone(socket) do
    %{organisation: organisation, workspace: workspace} = socket.assigns.current_scope

    socket
    |> put_flash(:error, gettext("This node is gone: it was deleted."))
    |> push_navigate(to: ~p"/#{organisation}/#{workspace}/nodes")
  end

  # A change the reader may not make, as the database has their membership now: one who
  # still reads the workspace is told why on Settings; one who reads the organisation
  # through the edition's reach is told so; anyone else is sent to `/`.
  defp refused(socket, why) do
    scope = Access.reload(socket.assigns.current_scope)

    cond do
      Access.reader(scope) ->
        socket
        |> put_flash(:error, ApiaryWeb.Access.reads_only(scope))
        |> push_patch(to: node_path(socket, :settings))

      Access.can?(scope, :"node.read", scope.workspace) ->
        socket
        |> assign(may_edit: false, may_delete: false)
        |> assign_form(Nodes.change_node(socket.assigns.node))
        |> put_flash(:error, why)
        |> push_patch(to: node_path(socket, :settings))

      true ->
        socket
        |> put_flash(:error, gettext("You are no longer a member of this workspace."))
        |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :node))

  defp node_path(socket, action), do: Map.fetch!(socket.assigns.paths, action)

  # The page's paths: its tabs and the deletion's dialog.
  defp paths(%{organisation: organisation, workspace: workspace}, public_id) do
    base = ~p"/#{organisation}/#{workspace}/nodes/#{public_id}"
    %{overview: base, settings: base <> "/settings", delete: base <> "/settings/delete"}
  end

  ## Render

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
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/nodes"}>
        {gettext("Nodes")}
      </:crumb>
      <:crumb navigate={@live_action != :overview && @paths.overview}>
        {@node.name}
      </:crumb>

      <.header>
        <span class="inline-flex min-w-0 flex-wrap items-baseline gap-x-2.5">
          <.icon name="hero-server-stack" class="size-5 flex-none self-center text-muted" />
          <span id="node-name" class="min-w-0 break-words">{@node.name}</span>
          <span id="node-public-id" class="q-mono text-[13px] font-normal text-muted">
            {@node.public_id}
          </span>
        </span>
        <:subtitle>
          <span id="node-meta" class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
            <span id="node-kind">{kind_label(@node.kind)}</span>
            <span class="text-faint" aria-hidden="true">·</span>
            <span id="node-state">{gettext("Never seen")}</span>
            <span :if={@node.created_by} class="text-faint" aria-hidden="true">·</span>
            <span :if={@node.created_by} id="node-made">
              {gettext("made by %{person}, %{date}",
                person: People.email(@node.created_by),
                date: Format.day(@node.inserted_at)
              )}
            </span>
          </span>
        </:subtitle>
      </.header>

      <.tabs id="node-tabs" label={@node.name}>
        <:tab
          id="node-tab-overview"
          patch={@paths.overview}
          current={@live_action == :overview}
          icon="hero-book-open"
        >
          {gettext("Overview")}
        </:tab>
        <:tab
          id="node-tab-settings"
          patch={@paths.settings}
          current={@live_action in [:settings, :delete]}
          icon="hero-cog-6-tooth"
          end
        >
          {gettext("Settings")}
        </:tab>
      </.tabs>

      <.overview :if={@live_action == :overview} node={@node} settings={@paths.settings} />

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
          delete={@paths.delete}
        />
      </SettingsComponents.layout>

      <.modal
        :if={@live_action == :delete && @may_delete}
        id="delete-node-dialog"
        title={gettext("Delete %{name}?", name: @node.name)}
        on_cancel={JS.patch(@paths.settings)}
      >
        <p class="text-muted">
          {gettext(
            "%{name} leaves this workspace's nodes at once, and its name is free again. Its runs stay in the record. This cannot be undone.",
            name: @node.name
          )}
        </p>
        <:footer>
          <.button patch={@paths.settings} data-autofocus>
            {gettext("Cancel")}
          </.button>
          <.button
            id="delete-node-confirm"
            variant="danger"
            phx-click="delete"
            loading_text={gettext("Deleting")}
          >
            {if @node.kind == :pool,
              do: gettext("Delete node pool"),
              else: gettext("Delete node")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  attr :node, Node, required: true
  attr :settings, :string, required: true

  # The operational side: the node's instance or a pool's running instances, its recent
  # runs, and About. No instance has reported in the record yet, so each says so.
  defp overview(assigns) do
    ~H"""
    <div id="node-overview" class="grid max-w-[60rem] gap-8">
      <SettingsComponents.part
        id="node-instances"
        title={if @node.kind == :pool, do: gettext("Running instances"), else: gettext("Instance")}
        level={:h2}
      >
        <p id="node-instances-none" class="text-[13px]/5 text-muted">
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
      </SettingsComponents.part>

      <SettingsComponents.part id="node-runs" title={gettext("Recent runs")} level={:h2}>
        <p id="node-runs-none" class="text-[13px]/5 text-muted">
          {gettext("No run of this node is in the record yet.")}
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
            patch={@settings}
            class="text-[13px] text-accent hover:underline"
          >
            {gettext("Settings")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
          </.link>
        </p>
      </SettingsComponents.part>
    </div>
    """
  end

  attr :node, Node, required: true
  attr :form, :any, required: true
  attr :may_edit, :boolean, required: true
  attr :may_delete, :boolean, required: true
  attr :delete, :string, required: true

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
      >
        {gettext(
          "It leaves this workspace's nodes, and its name is free again. Its runs stay in the record."
        )}
        <:action>
          <.button id="delete-node-button" patch={@delete}>
            {if @node.kind == :pool,
              do: gettext("Delete node pool…"),
              else: gettext("Delete node…")}
          </.button>
        </:action>
      </SettingsComponents.danger_action>
    </SettingsComponents.danger_zone>
    """
  end

  defp kind_label(:node), do: gettext("Node")
  defp kind_label(:pool), do: gettext("Node pool")

  defp kind_sentence(:node), do: gettext("Node: one permanent machine.")

  defp kind_sentence(:pool),
    do: gettext("Node pool: short-lived instances that share one access key.")

  defp limit_words(%Node{kind: :node}), do: gettext("1, one instance at a time")
  defp limit_words(%Node{instance_limit: nil}), do: gettext("No limit")
  defp limit_words(%Node{instance_limit: limit}), do: Format.number(limit)
end
