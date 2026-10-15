defmodule ApiaryWeb.AdapterLive.Show do
  # An integration's page, under Organisation settings › Integrations
  # (`/:org/settings/integrations/:adapter_id`, its public id, `na_…`): an adapter of
  # `Apiary.Adapters`. Its title is its name; under it, its state (connected, with when it
  # last sent a change and how many of its repositories or projects have no workspace; not
  # connected; or no access key yet). Four tabs, each an address:
  #
  # - **Repositories and projects** (the integration's own path, `:collections`): what it
  #   reports, each assigned to a workspace. It is the frame alone for now.
  # - **Node pools** (`…/node-pools`, `:pools`): the node pools it serves in the
  #   workspaces the reader reaches, each with its workspace
  #   (`Apiary.Adapters.served_pools/2`); a pool of a workspace they don't reach is left
  #   out, its page not theirs. A pool names the integration on its settings page, under
  #   Served by.
  # - **Access key** (`…/access-key`): `ApiaryWeb.AdapterLive.AccessKey`'s.
  # - **Settings** (`…/settings`, `:settings`), last and set apart: its name, with
  #   Rename, a page of its own (`…/settings/rename`, `:rename`); and Remove this
  #   integration, asked in place (`…/settings/remove`, `:remove`), which revokes its
  #   access keys and leaves every pool it served served by none
  #   (`Apiary.Adapters.delete_adapter/2`).
  #
  # Everyone in the organisation reads the page (`adapter.read`); owners and admins rename
  # it (`adapter.edit`) and remove it (`adapter.delete`). A member reads Settings without
  # Rename or Remove, with the line that says who changes integrations, and the paths of
  # the acts refuse them; the context functions ask again. An integration of another
  # organisation, a removed one, or none is not found.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, AccessKeys, Adapters, Organisations}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias ApiaryWeb.{AdapterComponents, NodeComponents, SettingsComponents, UserAuth}

  # The acts of the page, and the action each asks.
  @acts %{rename: :"adapter.edit", remove: :"adapter.delete"}

  @impl true
  def mount(%{"adapter_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Adapters.get_adapter(scope, public_id) do
      %Node{} = adapter ->
        if connected?(socket), do: AccessKeys.subscribe(scope, adapter)

        {:ok,
         socket
         |> assign(sections: SettingsComponents.sections(scope, :organisation))
         |> assign(form: nil, pools: [], confirming: false)
         |> assign_adapter(adapter)
         |> assign_may()
         |> UserAuth.on_membership_change(&(&1 |> assign_may() |> pools_again()))
         |> AdapterComponents.leave_when_hidden(~w(rename remove))}

      nil ->
        raise ApiaryWeb.NotFound
    end
  end

  defp assign_adapter(socket, adapter) do
    assign(socket,
      adapter: adapter,
      summary: AdapterComponents.summary(adapter),
      paths: AdapterComponents.paths(socket.assigns.current_scope, adapter)
    )
  end

  defp assign_may(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns

    assign(
      socket,
      :may,
      Map.new(@acts, fn {act, action} -> {act, Access.can?(scope, action, adapter)} end)
    )
  end

  @impl true
  def handle_params(%{"adapter_id" => public_id}, _uri, %{assigns: %{adapter: adapter}} = socket)
      when public_id != adapter.public_id do
    scope = socket.assigns.current_scope
    {:noreply, push_navigate(socket, to: AdapterComponents.paths(scope, public_id).collections)}
  end

  def handle_params(_params, _uri, socket) do
    # Whether a confirmation was open, for the focus to go back to its button once it is
    # gone.
    left = socket.assigns.confirming
    action = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(form: nil, confirming: false)
     |> apply_action(action)
     |> titled()
     |> focus_after_confirm(left)}
  end

  defp apply_action(socket, :collections), do: socket

  defp apply_action(socket, :pools), do: assign_pools(socket)

  defp apply_action(socket, :settings), do: socket

  defp apply_action(socket, :rename) do
    if socket.assigns.may.rename,
      do: assign_form(socket, Adapters.change_adapter(socket.assigns.adapter)),
      else: refused(socket, :rename)
  end

  defp apply_action(socket, :remove) do
    if socket.assigns.may.remove,
      do: assign(socket, :confirming, true),
      else: refused(socket, :remove)
  end

  # The pools it serves in the workspaces the reader reaches
  # (`ApiaryWeb.NodeComponents.reached_workspaces/1`), each with its workspace.
  defp assign_pools(socket) do
    %{current_scope: scope, adapter: adapter, memberships: places} = socket.assigns
    reached = NodeComponents.reached_workspaces(places)
    workspaces = Map.new(Organisations.list_workspaces(scope), &{&1.id, &1})

    pools =
      for pool <- Adapters.served_pools(scope, adapter),
          MapSet.member?(reached, pool.workspace_id),
          %Workspace{} = workspace <- [workspaces[pool.workspace_id]],
          do: %{workspace: workspace, pool: pool}

    assign(socket, :pools, pools)
  end

  # The membership changed while Node pools is open: what the reader reaches is read
  # again.
  defp pools_again(%{assigns: %{live_action: :pools}} = socket), do: assign_pools(socket)
  defp pools_again(socket), do: socket

  # The window's title: the page's act where it has one, then the integration's name.
  defp titled(%{assigns: %{live_action: :rename, form: %{}} = assigns} = socket) do
    title = gettext("Rename %{name}", name: assigns.adapter.name)
    assign(socket, :page_title, AdapterComponents.page_title(assigns.current_scope, [title]))
  end

  defp titled(%{assigns: assigns} = socket),
    do:
      assign(
        socket,
        :page_title,
        AdapterComponents.page_title(assigns.current_scope, [assigns.adapter.name])
      )

  # Once Remove this integration is no longer asked, by Keep it, Escape or a refusal, the
  # focus goes back to its button; never to the page's body.
  defp focus_after_confirm(%{assigns: %{confirming: false}} = socket, true),
    do: push_event(socket, "run:focus", %{id: "adapter-remove"})

  defp focus_after_confirm(socket, _left), do: socket

  @impl true
  def handle_event(
        "validate_rename",
        %{"adapter" => params},
        %{assigns: %{live_action: :rename, form: %{}}} = socket
      ) do
    changeset =
      socket.assigns.adapter
      |> Adapters.change_adapter(form_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event(
        "rename",
        %{"adapter" => params},
        %{assigns: %{live_action: :rename, form: %{}}} = socket
      ) do
    %{current_scope: scope, adapter: adapter} = socket.assigns

    case Adapters.rename_adapter(scope, adapter, form_params(params)) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> assign_adapter(renamed)
         |> push_patch(to: socket.assigns.paths.settings)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, :rename)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}
    end
  end

  def handle_event(
        "remove",
        _params,
        %{assigns: %{live_action: :remove, confirming: true}} = socket
      ) do
    %{current_scope: scope, adapter: adapter} = socket.assigns

    case Adapters.delete_adapter(scope, adapter) do
      {:ok, _deleted} ->
        {:noreply, push_navigate(socket, to: AdapterComponents.index_path(scope))}

      {:error, :forbidden} ->
        {:noreply, refused(socket, :remove)}

      {:error, _not_found} ->
        {:noreply, gone(socket)}
    end
  end

  # An act without its page or its confirmation open: a second click of a button whose
  # confirmation is gone, or an event the page never sent. One who may take the act is
  # shown the page again; one who may not is refused, and nothing is done.
  def handle_event(event, _params, socket) when event in ~w(validate_rename rename remove) do
    act = if event == "remove", do: :remove, else: :rename

    if socket.assigns.may[act],
      do: {:noreply, socket},
      else: {:noreply, refused(socket, act)}
  end

  @impl true
  # A key of the integration arrived: its state is read again.
  def handle_info({:key_enrolled, %{node_id: id}}, %{assigns: %{adapter: %{id: id}}} = socket),
    do: {:noreply, assign(socket, :summary, AdapterComponents.summary(socket.assigns.adapter))}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Answers

  # The act was refused on the membership as the database has it now: the scope is read
  # again, and one who still reads the organisation is told who may, back on Settings; one
  # who no longer reaches it, or from whom the page is hidden now, leaves
  # (`ApiaryWeb.UserAuth.reload_scope/1`).
  defp refused(socket, act) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      socket
    else
      scope = socket.assigns.current_scope

      socket
      |> assign_may()
      |> assign(form: nil, confirming: false)
      |> put_flash(:error, AdapterComponents.only_admins(scope, Map.fetch!(@acts, act)))
      |> push_patch(to: socket.assigns.paths.settings)
    end
  end

  # The integration was removed, or left the reader's reach, since the page opened: the
  # list, where it is no longer.
  defp gone(socket) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected,
      do: socket,
      else: push_navigate(socket, to: AdapterComponents.index_path(socket.assigns.current_scope))
  end

  # The form's name alone, as a string: anything else a crafted event sends is not there.
  defp form_params(%{"name" => name}) when is_binary(name), do: %{"name" => name}
  defp form_params(_params), do: %{}

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(AdapterComponents.name_errors(changeset), as: :adapter))

  ## Render

  @impl true
  # Rename: a form page of the integration, its name alone, Save and Cancel back to
  # Settings.
  def render(%{live_action: :rename, form: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:integrations}
    >
      <:crumb patch={@paths.collections}>{@adapter.name}</:crumb>
      <:crumb>{gettext("Rename")}</:crumb>

      <.page_form id="rename-adapter" title={gettext("Rename %{name}", name: @adapter.name)}>
        <.form
          for={@form}
          id="rename-adapter-form"
          phx-change="validate_rename"
          phx-submit="rename"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.page_form_foot id="rename-adapter-save" cancel={@paths.settings} cancel_by="patch">
            <.button id="rename-adapter-submit" variant="primary" type="submit">
              {gettext("Save")}
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
      nav={:organisation}
      sections={@sections}
      section={:integrations}
    >
      <:crumb patch={@live_action != :collections && @paths.collections}>
        {@adapter.name}
      </:crumb>

      <.settings_page section={:integrations} title={@adapter.name} measure="list">
        <:subtitle><AdapterComponents.state_line summary={@summary} /></:subtitle>

        <AdapterComponents.tabs
          scope={@current_scope}
          adapter={@adapter}
          current={tab(@live_action)}
          live={:show}
        />

        <.pools :if={@live_action == :pools} pools={@pools} scope={@current_scope} />
        <.settings
          :if={@live_action in [:settings, :remove]}
          adapter={@adapter}
          paths={@paths}
          may={@may}
          confirming={@confirming}
          scope={@current_scope}
        />
      </.settings_page>
    </Layouts.app>
    """
  end

  defp tab(:remove), do: :settings
  defp tab(action), do: action

  attr :pools, :list, required: true
  attr :scope, :any, required: true

  # Node pools: the pools the integration serves, each with its workspace.
  defp pools(assigns) do
    ~H"""
    <section id="adapter-pools" class="grid gap-4">
      <p class="text-[13px]/5 text-muted">
        {gettext(
          "Node pools whose runs this integration starts. Set on each pool's settings page, under Served by."
        )}
      </p>
      <p :if={@pools == []} id="adapter-pools-empty" class="text-[13px]/5 text-muted">
        {gettext("It serves no node pool.")}
      </p>
      <.table
        :if={@pools != []}
        id="adapter-pools-table"
        label={gettext("Node pools")}
        rows={@pools}
        row_id={&"pool-#{&1.pool.public_id}"}
      >
        <:col :let={row} label={gettext("Workspace")}>{row.workspace.name}</:col>
        <:col :let={row} label={gettext("Node pool")} kind="title">
          <.link
            navigate={~p"/#{@scope.organisation}/#{row.workspace}/nodes/#{row.pool}"}
            class="q-title hover:underline"
          >
            {row.pool.name}
          </.link>
        </:col>
      </.table>
    </section>
    """
  end

  attr :adapter, Node, required: true
  attr :paths, :map, required: true
  attr :may, :map, required: true
  attr :confirming, :boolean, required: true
  attr :scope, :any, required: true

  # Settings: its name with Rename, then Remove this integration, asked in place.
  defp settings(assigns) do
    ~H"""
    <p :if={!@may.rename and !@may.remove} id="adapter-readers" class="text-[13px]/5 text-muted">
      {AdapterComponents.only_admins(@scope)}
    </p>

    <SettingsComponents.part id="adapter-name" title={gettext("Name")}>
      <p class="flex flex-wrap items-center gap-3 text-[13.5px]/5">
        <span id="adapter-name-value">{@adapter.name}</span>
        <.button
          :if={@may.rename}
          id="adapter-rename"
          size="xs"
          patch={@paths.rename}
        >
          {gettext("Rename")}
        </.button>
      </p>
    </SettingsComponents.part>

    <section :if={@may.remove} id="adapter-remove-part" class="grid gap-3 border-t border-line pt-6">
      <div class="q-danger-act">
        <.button
          id="adapter-remove"
          patch={if @confirming, do: @paths.settings, else: @paths.remove}
          aria-expanded={to_string(@confirming)}
          aria-controls={@confirming && "adapter-remove-confirm"}
          phx-hook="FocusOn"
        >
          {gettext("Remove this integration")}
        </.button>
      </div>
      <div :if={@confirming} class="q-danger-line">
        <div class="q-danger-confirm">
          <.inline_confirm
            id="adapter-remove-confirm"
            question={gettext("Remove %{name}?", name: @adapter.name)}
            cancel={@paths.settings}
            cancel_label={gettext("Keep it")}
          >
            {gettext(
              "Its access keys are revoked, and its repositories and projects leave every backlog. Work items already taken in keep their links."
            )}
            <:action>
              <.button
                id="adapter-remove-confirm-button"
                variant="danger"
                size="xs"
                phx-click="remove"
              >
                {gettext("Remove it")}
              </.button>
            </:action>
          </.inline_confirm>
        </div>
      </div>
    </section>
    """
  end
end
