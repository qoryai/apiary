defmodule ApiaryWeb.AdapterLive.Index do
  # Organisation settings › Integrations, `/:org/settings/integrations`: the systems the
  # organisation works with, each an adapter of `Apiary.Adapters`, on the list pattern
  # (`docs/ui.md`, Lists). A row an integration: its name, a link to its page; how many
  # repositories or projects it has connected; its state, connected, not connected or no
  # access key yet, with how many of its repositories or projects have no workspace; and
  # when it last sent a change (`ApiaryWeb.AdapterComponents.summary/1`). Under the list,
  # that one integration connects one account.
  #
  # Owners and admins add one (`adapter.create`, asked of the organisation) on a page of
  # its own, `/settings/integrations/new` (`docs/ui.md`, A form is a page): its name alone.
  # Adding one opens its page on its Access key tab, where its adapter's key is enrolled.
  # Everyone in the organisation reads the list (`adapter.read`); a member sees it without
  # the button, with the line that says who changes integrations, and the form's path
  # refuses them. `Apiary.Adapters.create_adapter/2` asks again.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, Adapters}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{AdapterComponents, SettingsComponents, UserAuth}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(sections: SettingsComponents.sections(scope, :organisation), form: nil)
     |> assign_may()
     |> load()
     |> UserAuth.on_membership_change(&(&1 |> assign_may() |> load()))}
  end

  defp assign_may(socket) do
    scope = socket.assigns.current_scope

    assign(
      socket,
      :may_create,
      Access.can?(scope, :"adapter.create", scope.organisation)
    )
  end

  defp load(socket),
    do: assign(socket, :summaries, AdapterComponents.summaries(socket.assigns.current_scope))

  @impl true
  def handle_params(_params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action)}

  defp apply_action(socket, :index) do
    scope = socket.assigns.current_scope

    socket
    |> assign(form: nil)
    |> assign(:page_title, AdapterComponents.page_title(scope, []))
    |> load()
  end

  defp apply_action(socket, :new) do
    scope = socket.assigns.current_scope

    if socket.assigns.may_create do
      socket
      |> assign_form(Adapters.change_adapter())
      |> assign(:page_title, AdapterComponents.page_title(scope, [gettext("Add")]))
    else
      refused(socket)
    end
  end

  @impl true
  def handle_event("validate", %{"adapter" => params}, %{assigns: %{form: %{}}} = socket) do
    changeset =
      Adapters.change_adapter(%Node{kind: :adapter}, form_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"adapter" => params}, %{assigns: %{form: %{}}} = socket) do
    scope = socket.assigns.current_scope

    case Adapters.create_adapter(scope, form_params(params)) do
      {:ok, adapter} ->
        {:noreply, push_navigate(socket, to: AdapterComponents.paths(scope, adapter).access_key)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _refused} ->
        {:noreply, refused(socket)}
    end
  end

  # A form's event with no form open: the list, which has none, or a form page that has
  # been left. One who may add an integration is shown the page again; one who may not is
  # refused.
  def handle_event(event, _params, socket) when event in ~w(validate create) do
    if socket.assigns.may_create,
      do: {:noreply, socket},
      else: {:noreply, refused(socket)}
  end

  # The membership this page was opened with no longer lets them add an integration: the
  # scope is read again, and one who still reads the organisation is told who may, on the
  # list; one who no longer reaches it, or from whom the page is hidden now, leaves
  # (`ApiaryWeb.UserAuth.reload_scope/1`).
  defp refused(socket) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      socket
    else
      scope = socket.assigns.current_scope

      socket
      |> assign_may()
      |> put_flash(:error, AdapterComponents.only_admins(scope, :"adapter.create"))
      |> push_patch(to: AdapterComponents.index_path(scope))
    end
  end

  # The form's name alone, as a string: anything else a crafted event sends is not there.
  defp form_params(%{"name" => name}) when is_binary(name), do: %{"name" => name}
  defp form_params(_params), do: %{}

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(AdapterComponents.name_errors(changeset), as: :adapter))

  @impl true
  # Add an integration: a form page of the section, its name alone, its button and Cancel
  # back to the list.
  def render(%{form: %{}} = assigns) do
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
      <:crumb>{gettext("Add")}</:crumb>

      <.page_form id="new-adapter" title={gettext("Add an integration")}>
        <.form
          for={@form}
          id="new-adapter-form"
          phx-change="validate"
          phx-submit="create"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            hint={gettext("What people here call it, such as GitHub or Linear.")}
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.page_form_foot
            id="new-adapter-save"
            cancel={AdapterComponents.index_path(@current_scope)}
            cancel_by="patch"
          >
            <.button id="new-adapter-submit" variant="primary" type="submit">
              {gettext("Add integration")}
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
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:organisation}
        current={:integrations}
        measure="list"
        title={AdapterComponents.section_title()}
      >
        <:subtitle>
          {pgettext(
            "plain",
            "The systems this organisation works with: where tickets come from, and the node pools they serve. Each one reaches Qory through its adapter."
          )}
        </:subtitle>
        <:actions :if={@may_create}>
          <.button
            id="new-adapter"
            variant="primary"
            patch={AdapterComponents.new_path(@current_scope)}
          >
            <.icon name="hero-plus-micro" class="size-4" />{gettext("Add an integration")}
          </.button>
        </:actions>

        <p :if={@summaries == []} id="adapters-empty" class="text-[13px]/5 text-muted">
          {gettext("No integration yet. Add one, enrol its adapter's access key, and connect it.")}
        </p>

        <.table
          :if={@summaries != []}
          id="adapters"
          label={AdapterComponents.section_title()}
          rows={@summaries}
          row_id={&"adapter-#{&1.adapter.public_id}"}
        >
          <:col :let={summary} label={gettext("Integration")} kind="title">
            <span class="q-nm">
              <.icon name="hero-link" class="size-4 flex-none text-muted" />
              <.link
                id={"adapter-#{summary.adapter.public_id}-name"}
                navigate={AdapterComponents.paths(@current_scope, summary.adapter).collections}
                class="q-title hover:underline"
              >
                {summary.adapter.name}
              </.link>
            </span>
          </:col>
          <:col :let={summary} label={gettext("Repositories or projects")} kind="num">
            <span id={"adapter-#{summary.adapter.public_id}-collections"}>
              {if AdapterComponents.state(summary) == :connected,
                do: Format.number(summary.collections),
                else: "—"}
            </span>
          </:col>
          <:col :let={summary} label={gettext("State")}>
            <span class="grid gap-1">
              <AdapterComponents.state_mark
                id={"adapter-#{summary.adapter.public_id}-state"}
                summary={summary}
              />
              <AdapterComponents.without_workspace
                :if={AdapterComponents.state(summary) == :connected and summary.unassigned > 0}
                id={"adapter-#{summary.adapter.public_id}-unassigned"}
                count={summary.unassigned}
              />
            </span>
          </:col>
          <:col :let={summary} label={gettext("Last update")}>
            <span id={"adapter-#{summary.adapter.public_id}-updated"}>
              <%= if AdapterComponents.state(summary) == :connected and summary.last_change_at do %>
                <.time_ago at={summary.last_change_at} />
              <% else %>
                —
              <% end %>
            </span>
          </:col>
        </.table>

        <p id="adapters-one-account" class="text-[12.5px]/[18px] text-muted">
          {pgettext(
            "plain",
            "One integration connects one account. To work with another account of the same system, use another organisation."
          )}
        </p>
        <p :if={!@may_create} id="adapters-readers" class="text-[12.5px]/[18px] text-muted">
          {AdapterComponents.only_admins(@current_scope, :"adapter.create")}
        </p>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end
end
