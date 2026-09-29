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
  or beside the way to join one for a person in none.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Deletion, Organisations}
  alias ApiaryWeb.Nav.Entry

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
        <.header>
          {gettext("Your organisations")}
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
        </.header>

        <.card :if={@memberships != []} id="organisations" padding={false}>
          <ul class="divide-y divide-line">
            <li
              :for={membership <- @memberships}
              id={"organisation-#{membership.organisation.id}"}
              class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
            >
              <.avatar name={membership.organisation.name} kind="organisation" />
              <.link href={organisation_path(membership)} class="link min-w-0 truncate font-medium">
                {membership.organisation.name}
              </.link>
              <span :for={workspace <- membership.workspaces} class="min-w-0 truncate text-muted">
                {workspace.name}
              </span>
            </li>
          </ul>
        </.card>

        <section :if={@suspended != []} id="suspended-memberships" class="grid gap-3">
          <h2 class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
            {gettext("Suspended memberships")}
          </h2>
          <p class="max-w-[60ch] text-[13px]/[20px] text-muted">
            {gettext(
              "Your membership in these organisations is suspended: you cannot open them or act in them. An owner or an admin of each can activate it."
            )}
          </p>
          <.card padding={false}>
            <ul class="divide-y divide-line">
              <li
                :for={membership <- @suspended}
                id={"suspended-#{membership.organisation.id}"}
                class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
              >
                <.avatar name={membership.organisation.name} kind="organisation" />
                <span class="min-w-0 truncate font-medium">{membership.organisation.name}</span>
                <.badge color="warning" dot class="ml-auto">{gettext("Suspended")}</.badge>
              </li>
            </ul>
          </.card>
        </section>

        <section :if={@pending != []} id="pending-deletions" class="grid gap-3">
          <h2 class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
            {gettext("Deleted, waiting to be purged")}
          </h2>
          <p class="max-w-[60ch] text-[13px]/[20px] text-muted">
            {gettext(
              "Nobody can open these organisations and their access keys do not work. Until the day each is purged, you can cancel its deletion, which brings everything back."
            )}
          </p>
          <.card padding={false}>
            <ul class="divide-y divide-line">
              <li
                :for={organisation <- @pending}
                id={"pending-#{organisation.id}"}
                class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
              >
                <.avatar name={organisation.name} kind="organisation" />
                <span class="min-w-0 truncate font-medium">{organisation.name}</span>
                <span class="text-[13px]/[18px] tabular-nums text-muted">
                  {gettext("Purged on %{date}", date: Format.date(organisation.purge_after))}
                </span>
                <.button
                  id={"restore-#{organisation.id}"}
                  size="xs"
                  class="ml-auto"
                  phx-click="restore"
                  phx-value-id={organisation.id}
                  aria-label={gettext("Cancel the deletion of %{name}", name: organisation.name)}
                  loading_text={gettext("Cancelling")}
                >
                  {gettext("Cancel deletion")}
                </.button>
              </li>
            </ul>
          </.card>
        </section>
      <% end %>
    </Layouts.app>
    """
  end

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
     |> load()}
  end

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
