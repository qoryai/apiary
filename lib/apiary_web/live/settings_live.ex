defmodule ApiaryWeb.SettingsLive do
  @moduledoc """
  Apiary (organisation) and hive settings: names, and the owners.
  """
  use ApiaryWeb, :live_view

  alias Apiary.Organisations

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      width="narrow"
    >
      <.header>
        Settings
        <:subtitle>
          The names of this <.term word="apiary" /> and its <.term word="hive" />, and who owns
          them.
        </:subtitle>
      </.header>

      <.notice :if={!@owner?} kind={:info}>
        Only owners can change these settings. Ask an owner if a name needs to change.
      </.notice>

      <.card>
        <:title><.term word="Apiary" /> name</:title>
        <.form
          for={@organisation_form}
          id="organisation-form"
          phx-change="validate_organisation"
          phx-submit="save_organisation"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@organisation_form[:name]}
            type="text"
            label="Name"
            debounce="200"
            autocomplete="off"
            disabled={!@owner?}
            required
          />
        </.form>
        <:footer>
          <span>Shown in the sidebar and in invitations.</span>
          <.button
            :if={@owner?}
            type="submit"
            form="organisation-form"
            disabled={!@organisation_form.source.valid?}
            loading_text="Saving"
          >
            Save
          </.button>
        </:footer>
      </.card>

      <.card>
        <:title><.term word="Hive" /> name</:title>
        <.form
          for={@hive_form}
          id="hive-form"
          phx-change="validate_hive"
          phx-submit="save_hive"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@hive_form[:name]}
            type="text"
            label="Name"
            debounce="200"
            autocomplete="off"
            disabled={!@owner?}
            required
          />
        </.form>
        <:footer>
          <span>Shown in the sidebar and as the overview title.</span>
          <.button
            :if={@owner?}
            type="submit"
            form="hive-form"
            disabled={!@hive_form.source.valid?}
            loading_text="Saving"
          >
            Save
          </.button>
        </:footer>
      </.card>

      <.card padding={false}>
        <:title>Owners</:title>
        <:actions>
          <.button navigate={~p"/hive/members"}>Manage members</.button>
        </:actions>
        <ul id="owners" class="divide-y divide-line">
          <li
            :for={owner <- @owners}
            id={"owner-#{owner.id}"}
            class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
          >
            <.avatar
              name={owner.user.email}
              kind={if owner.user_id == @current_scope.user.id, do: "self", else: "person"}
            />
            <span class="min-w-0 truncate font-medium">{owner.user.email}</span>
            <.badge :if={owner.user_id == @current_scope.user.id}>You</.badge>
            <span class="ml-auto text-[13px]/[18px] tabular-nums text-faint">
              since {short_date(owner.inserted_at)}
            </span>
          </li>
        </ul>
        <:footer>
          <span>The last owner cannot be removed or demoted.</span>
        </:footer>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Settings", owner?: Organisations.owner?(scope))
     |> assign_forms()
     |> load_owners()}
  end

  @impl true
  def handle_event("validate_organisation", %{"organisation" => params}, socket) do
    changeset =
      socket.assigns.current_scope.organisation
      |> Organisations.change_organisation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :organisation_form, to_form(changeset))}
  end

  def handle_event("save_organisation", %{"organisation" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.update_organisation(scope, params) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | organisation: organisation})
         |> assign_forms()
         |> put_flash(:info, "Apiary renamed to #{organisation.name}.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :organisation_form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("validate_hive", %{"hive" => params}, socket) do
    changeset =
      socket.assigns.current_scope.hive
      |> Organisations.change_hive(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :hive_form, to_form(changeset))}
  end

  def handle_event("save_hive", %{"hive" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.update_hive(scope, params) do
      {:ok, hive} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | hive: hive})
         |> assign_forms()
         |> put_flash(:info, "Hive renamed to #{hive.name}.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :hive_form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  defp assign_forms(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      organisation_form: to_form(Organisations.change_organisation(scope.organisation)),
      hive_form: to_form(Organisations.change_hive(scope.hive))
    )
  end

  defp load_owners(socket) do
    owners =
      socket.assigns.current_scope
      |> Organisations.list_members()
      |> Enum.filter(&(&1.level == :owner))

    assign(socket, :owners, owners)
  end

  defp unauthorized(socket) do
    socket
    |> assign(:owner?, false)
    |> assign_forms()
    |> put_flash(:error, "Only owners can change these settings.")
  end
end
