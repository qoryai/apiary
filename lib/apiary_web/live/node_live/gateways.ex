defmodule ApiaryWeb.NodeLive.Gateways do
  @moduledoc """
  The organisation's gateways, `/:org/gateways`, which nodes and node pools in any
  workspace of the organisation can use (`Apiary.Gateways`), on the list pattern
  (`docs/ui.md`, Lists): one row a gateway, its name the title with its public id beside
  it, its URL, Default beside the organisation's default gateway, and whether it is
  connected, holding an active access key (`Apiary.AccessKeys.active_key?/1`). The
  sentence under the heading, and the body of the empty state, say whose nodes can use them
  (`c:ApiaryWeb.Edition.gateway_reach_sentence/2`).

  The console offers it only where an organisation may have more than one workspace
  (`ApiaryWeb.NodeComponents.organisation_gateways?/0`); elsewhere its paths do not exist,
  and a workspace's gateways are its Nodes'.

  Owners and admins add a gateway here (`node.create`, asked of the organisation), on a
  separate page, `/gateways/new`, on the pattern of a form page (`docs/ui.md`, A form is
  a page): its name and its URL. Adding one leads to its Access key tab, with a flash.
  Everyone in the organisation reads the list (`node.read`); a member sees it without the
  button, and the form's path refuses them. A gateway's page is `ApiaryWeb.NodeLive.Show`'s
  and `ApiaryWeb.NodeLive.AccessKey`'s, under `/gateways/:node_id`.

  The sidebar's Gateways leads here: the pages pass `nav: :gateways`. Live: the list reads
  the gateways again on `{:nodes_touched, …}` of the organisation (`Apiary.Nodes.topic/1`).
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, AccessKeys, Nodes}
  alias ApiaryWeb.NodeComponents

  @impl true
  def mount(_params, _session, socket) do
    unless NodeComponents.organisation_gateways?(), do: raise(ApiaryWeb.NotFound)

    scope = socket.assigns.current_scope
    if connected?(socket), do: Nodes.subscribe(scope, :organisation)

    {:ok,
     socket
     |> assign(may_create: Access.can?(scope, :"node.create", scope.organisation), form: nil)
     |> NodeComponents.leave_when_hidden(["create"])
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action)}

  defp apply_action(socket, :index),
    do: assign(socket, form: nil, page_title: gettext("Gateways"))

  defp apply_action(socket, :new) do
    if socket.assigns.may_create do
      socket
      |> assign_form(Nodes.change_new_organisation_gateway())
      |> assign(page_title: gettext("New gateway") <> " · " <> gettext("Gateways"))
    else
      socket
      |> put_flash(:error, only_admins_add(socket.assigns.current_scope))
      |> push_patch(to: list_path(socket.assigns.current_scope))
    end
  end

  # The organisation's gateways, and which of them holds an active access key.
  defp load(socket) do
    gateways = Nodes.list_organisation_gateways(socket.assigns.current_scope)

    assign(socket,
      gateways: gateways,
      connected: Map.new(gateways, &{&1.id, AccessKeys.active_key?(&1)})
    )
  end

  @impl true
  def handle_info({:nodes_touched, _place_id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    changeset =
      params
      |> Nodes.change_new_organisation_gateway()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    scope = socket.assigns.current_scope

    case Nodes.create_organisation_gateway(scope, params) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is added.", name: gateway.name))
         |> push_navigate(to: ~p"/#{scope.organisation}/gateways/#{gateway}/access-key")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _refused} ->
        {:noreply, refused(socket)}
    end
  end

  # A form's event with no form open: the list, which has none, or a form page that has
  # been left.
  def handle_event(event, _params, socket) when event in ~w(validate create) do
    if socket.assigns.may_create,
      do: {:noreply, socket},
      else: {:noreply, refused(socket)}
  end

  # The membership this page was opened with no longer lets them add a gateway, or is
  # gone: one who still reads the organisation is told so on the list; anyone else is sent
  # to `/`.
  defp refused(socket) do
    scope = Access.reload(socket.assigns.current_scope)
    path = list_path(socket.assigns.current_scope)

    cond do
      # The nodes hidden from them meanwhile: the page leaves as it does once it hears of
      # it (`ApiaryWeb.UserAuth.reload_scope/1`).
      not Apiary.Features.visible?(scope, :nodes) ->
        ApiaryWeb.UserAuth.reload_scope(socket)

      Access.reader(scope) ->
        socket |> put_flash(:error, ApiaryWeb.Access.reads_only(scope)) |> push_patch(to: path)

      NodeComponents.reads_nodes?(scope, :organisation) ->
        socket
        |> assign(:may_create, false)
        |> put_flash(:error, only_admins_add(scope))
        |> push_patch(to: path)

      true ->
        socket
        |> put_flash(:error, NodeComponents.no_longer_member(:organisation))
        |> redirect(to: ~p"/")
    end
  end

  defp only_admins_add(scope),
    do:
      NodeComponents.managed_by(
        scope,
        :"node.create",
        gettext("Only owners and admins add nodes.")
      )

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :node))

  defp list_path(scope), do: ~p"/#{scope.organisation}/gateways"

  defp gateway_path(scope, gateway), do: ~p"/#{scope.organisation}/gateways/#{gateway}"

  @impl true
  def render(%{form: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:gateways}
      width="read"
    >
      <:crumb navigate={list_path(@current_scope)}>{gettext("Gateways")}</:crumb>
      <:crumb>{gettext("New gateway")}</:crumb>

      <.page_form
        id="new-gateway"
        title={gettext("New gateway")}
        cancel={list_path(@current_scope)}
        cancel_by="patch"
      >
        <:description>
          {gettext(
            "An address that runs of nodes and node pools in %{organisation}'s workspaces go through, when they choose it.",
            organisation: @current_scope.organisation.name
          )}
        </:description>
        <.form
          for={@form}
          id="new-gateway-form"
          phx-change="validate"
          phx-submit="create"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder="edge-01"
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:url]}
            type="text"
            inputmode="url"
            label={gettext("URL")}
            placeholder="https://gateway.example.com"
            hint={NodeComponents.url_hint(:new)}
            autocomplete="off"
            spellcheck="false"
            required
          />
          <.page_form_foot
            id="new-gateway-save"
            cancel={list_path(@current_scope)}
            cancel_by="patch"
          >
            <.button
              id="new-gateway-submit"
              variant="primary"
              type="submit"
              loading_text={gettext("Adding")}
            >
              {gettext("Add gateway")}
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
      nav={:gateways}
    >
      <:crumb>{gettext("Gateways")}</:crumb>

      <.page_header title={gettext("Gateways")}>
        <:description>
          <span id="gateways-intro">
            {ApiaryWeb.Edition.gateway_reach_sentence(:intro, @current_scope.organisation)}
          </span>
        </:description>
        <:actions :if={@may_create}>
          <.button
            id="new-organisation-gateway"
            patch={~p"/#{@current_scope.organisation}/gateways/new"}
          >
            <.icon name="hero-plus-micro" class="size-4" />{gettext("New gateway")}
          </.button>
        </:actions>
      </.page_header>

      <div :if={@gateways == []} id="gateways-empty">
        <.empty_state icon="hero-arrows-right-left" tone="neutral" title={gettext("No gateways yet")}>
          <p>
            {ApiaryWeb.Edition.gateway_reach_sentence(:empty, @current_scope.organisation)}
          </p>
          <:actions :if={@may_create}>
            <.button patch={~p"/#{@current_scope.organisation}/gateways/new"}>
              {gettext("New gateway")}
            </.button>
          </:actions>
        </.empty_state>
      </div>

      <.table
        :if={@gateways != []}
        id="gateways"
        label={gettext("Gateways")}
        rows={@gateways}
        row_id={&"gateway-#{&1.public_id}"}
      >
        <:col :let={gateway} label={gettext("Name")} kind="title">
          <span class="q-nm">
            <.link
              navigate={gateway_path(@current_scope, gateway)}
              class="q-title hover:underline"
              title={gateway.name}
            >
              {gateway.name}
            </.link>
            <span class="q-side q-mono" title={gateway.public_id}>{gateway.public_id}</span>
          </span>
        </:col>
        <:col :let={gateway} label={gettext("URL")} from="sm">
          <span class="q-mono q-cut" title={gateway.url}>{gateway.url}</span>
        </:col>
        <:col :let={gateway} label={gettext("Default")}>
          <.state_word :if={gateway.default_gateway} id={"gateway-#{gateway.public_id}-default"}>
            {gettext("Default")}
          </.state_word>
        </:col>
        <:col :let={gateway} label={gettext("Connected")}>
          <span id={"gateway-#{gateway.public_id}-connected"}>
            {if @connected[gateway.id], do: gettext("Yes"), else: gettext("No")}
          </span>
        </:col>
      </.table>
    </Layouts.app>
    """
  end
end
