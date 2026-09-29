defmodule ApiaryWeb.UserLive.Organisations do
  @moduledoc """
  A person's organisations, `/users/organisations`, from the account menu: each
  organisation they are a member of, leading to the first workspace of it they reach, or
  to the organisation's own path when they reach none yet, and the
  organisations marked for deletion that they own, which show here and nowhere else
  until they are purged, each with the day it is purged and a button that cancels the
  deletion (`Apiary.Deletion.restore_organisation/2`), and the organisations where their
  membership is suspended, which they cannot open until an owner or an admin there
  activates it. A person who is not part of an organisation, where `/` and the log-in
  send them, reads how to join one.

  The page offers what the organisation switcher offers after its places, the edition's
  entries (`c:ApiaryWeb.Edition.switcher_entries/1`), as its actions: beside its title,
  or beside the way to join one for a person in none. It is a section of the person's own
  settings, Organisations (`ApiaryWeb.SettingsComponents`), and its sidebar lists the
  settings.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Deletion, Organisations}
  alias ApiaryWeb.Nav.Entry
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={assigns[:nav_counts]}
      nav={:user_organisations}
      width="read"
      settings={@settings_nav}
      section={:user_organisations}
    >
      <%= if @memberships == [] and @pending == [] and @suspended == [] do %>
        <.empty_state
          icon="hero-envelope-open"
          title={gettext("You are not part of an organisation yet")}
          heading="h1"
          class="mx-auto mt-6 w-full max-w-[480px] md:mt-16"
        >
          <p>
            <.rich text={
              rich_gettext(
                "You join an organisation through an invitation. Ask an owner or an admin of yours to invite %{email}; the email they send brings you straight to their workspace.",
                email: {:b, @current_scope.user.email, "font-medium text-base-content"}
              )
            } />
          </p>
          <:actions>
            <.entry_button
              :for={{entry, index} <- Enum.with_index(@entries)}
              entry={entry}
              primary={index == 0}
              scope={@current_scope}
            />
            <.button href={~p"/users/settings"}>{gettext("Your settings")}</.button>
            <.button href={~p"/users/log-out"} method="delete" variant="ghost">
              {gettext("Log out")}
            </.button>
          </:actions>
        </.empty_state>
      <% else %>
        <SettingsComponents.layout
          scope={@current_scope}
          kind={:person}
          current={:user_organisations}
          title={gettext("Organisations")}
        >
          <:subtitle>
            {gettext("The organisations you are a member of, and the workspaces you reach in each.")}
          </:subtitle>
          <:actions :if={@entries != []}>
            <.entry_button
              :for={{entry, index} <- Enum.with_index(@entries)}
              entry={entry}
              primary={index == 0}
              scope={@current_scope}
            />
          </:actions>

          <.table
            :if={@memberships != []}
            id="organisations"
            label={gettext("Your organisations")}
            rows={@memberships}
            row_id={&"organisation-#{&1.organisation.id}"}
          >
            <:col :let={membership} label={gettext("Organisation")} kind="title">
              <span class="q-nm">
                <.avatar name={membership.organisation.name} kind="organisation" />
                <.link href={organisation_path(membership)} class="q-title hover:underline">
                  {membership.organisation.name}
                </.link>
              </span>
            </:col>
            <:col :let={membership} label={gettext("Workspaces")}>
              <span class="block max-w-[40ch] truncate">
                {Enum.map_join(membership.workspaces, ", ", & &1.name)}
              </span>
            </:col>
            <:col :let={membership} label={gettext("Level")} from="sm">
              {level_text(Map.get(membership, :level))}
            </:col>
          </.table>

          <section :if={@suspended != []} id="suspended-memberships" class="grid gap-3">
            <h2 class="text-[14px]/5 font-semibold">{gettext("Suspended memberships")}</h2>
            <p class="max-w-[60ch] text-[12.5px]/[18px] text-muted">
              {gettext(
                "Your membership in these organisations is suspended: you cannot open them or act in them. An owner or an admin of each can activate it."
              )}
            </p>
            <.table
              id="suspended"
              label={gettext("Suspended memberships")}
              rows={@suspended}
              row_id={&"suspended-#{&1.organisation.id}"}
              row_class={fn _ -> "row-off" end}
            >
              <:col :let={membership} label={gettext("Organisation")} kind="title">
                <span class="q-nm">
                  <.avatar name={membership.organisation.name} kind="organisation" />
                  <span class="q-title">{membership.organisation.name}</span>
                </span>
              </:col>
              <:col label={gettext("State")}>
                <.state_word>{gettext("Suspended")}</.state_word>
              </:col>
            </.table>
          </section>

          <section :if={@pending != []} id="pending-deletions" class="grid gap-3">
            <h2 class="text-[14px]/5 font-semibold">{gettext("Deleted, waiting to be purged")}</h2>
            <p class="max-w-[60ch] text-[12.5px]/[18px] text-muted">
              {gettext(
                "Nobody can open these organisations and their access keys do not work. Until the day each is purged, you can cancel its deletion, which brings everything back."
              )}
            </p>
            <.table
              id="pending"
              label={gettext("Deleted, waiting to be purged")}
              rows={@pending}
              row_id={&"pending-#{&1.id}"}
            >
              <:col :let={organisation} label={gettext("Organisation")} kind="title">
                <span class="q-nm">
                  <.avatar name={organisation.name} kind="organisation" />
                  <span class="q-title">{organisation.name}</span>
                </span>
              </:col>
              <:col :let={organisation} label={gettext("Purged")} kind="hot">
                <span class="tabular-nums">
                  {gettext("Purged on %{date}", date: Format.date(organisation.purge_after))}
                </span>
              </:col>
              <:action :let={organisation}>
                <.button
                  id={"restore-#{organisation.id}"}
                  variant="link"
                  phx-click="restore"
                  phx-value-id={organisation.id}
                  aria-label={gettext("Cancel the deletion of %{name}", name: organisation.name)}
                  loading_text={gettext("Cancelling")}
                >
                  {gettext("Cancel deletion")}
                </.button>
              </:action>
            </.table>
          </section>
        </SettingsComponents.layout>
      <% end %>
    </Layouts.app>
    """
  end

  defp level_text(:owner), do: gettext("Owner")
  defp level_text(:admin), do: gettext("Admin")
  defp level_text(:member), do: gettext("Member")
  defp level_text(_none), do: nil

  # An edition's entry, as a button of the page's actions: the first is the main one.
  attr :entry, Entry, required: true
  attr :primary, :boolean, default: false
  attr :scope, :any, required: true

  defp entry_button(assigns) do
    ~H"""
    <.button
      id={"organisations-#{@entry.key}"}
      variant={if @primary, do: "primary", else: "default"}
      navigate={Entry.path(@entry, @scope.organisation, @scope.workspace)}
    >
      <.icon :if={@entry.icon} name={@entry.icon} class="size-4" /> {@entry.label}
    </.button>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:entries, ApiaryWeb.Edition.switcher_entries(socket.assigns.current_scope))
     |> load()
     |> load_settings_nav()
     |> UserAuth.on_membership_change(&(&1 |> load() |> load_settings_nav()))}
  end

  # The settings the reader may change, the sidebar's list: the organisation's and the
  # workspace's of the scope the page carries, and their own.
  defp load_settings_nav(socket),
    do: assign(socket, :settings_nav, SettingsComponents.nav(socket.assigns.current_scope))

  @impl true
  def handle_event("restore", %{"id" => id}, socket) do
    case Deletion.restore_organisation(socket.assigns.current_scope, id) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The deletion of %{name} is cancelled: it is back, with its access keys.",
             name: organisation.name
           )
         )
         |> load()}

      {:error, :purge_started} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("It is being purged: the deletion can no longer be cancelled.")
         )
         |> load()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Only an owner of the organisation can cancel its deletion.")
         )
         |> load()}
    end
  end

  # The first workspace of the organisation the person reaches, or the organisation's own
  # path, which says they reach none yet.
  defp organisation_path(%{organisation: organisation, workspaces: [workspace | _]}),
    do: ~p"/#{organisation}/#{workspace}"

  defp organisation_path(%{organisation: organisation}), do: ~p"/#{organisation}"

  # The memberships in use, which the switcher shows too, the suspended ones, and the
  # organisations pending deletion that the person owns: three short reads, the page's
  # whole content.
  defp load(socket) do
    scope = socket.assigns.current_scope
    memberships = Organisations.list_memberships(scope.user)
    suspended = Organisations.list_suspended_memberships(scope.user)
    pending = Deletion.list_marked_organisations(scope)

    assign(socket,
      memberships: memberships,
      suspended: suspended,
      pending: pending,
      page_title:
        if(memberships == [] and pending == [] and suspended == [],
          do: gettext("No workspace yet"),
          else: gettext("Your organisations")
        )
    )
  end
end
