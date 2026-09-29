defmodule ApiaryWeb.MemberLive.Index do
  @moduledoc """
  The members and pending invitations, the People section of an organisation's settings
  (`ApiaryWeb.SettingsComponents`): `/:org/settings/people`. A membership is the
  organisation's: every member is listed, with their level.

  Owners change levels, and remove anyone; admins remove members only, and change no
  level; owners and admins invite; anyone may leave. An invitation is an email address
  and nothing else: it is sent from the workspace the page carries, grants it, and its
  person joins as a member. Members see the page read-only. What each may is asked of
  `Apiary.Access`.

  An edition adds to the page through its slots (`ApiaryWeb.Extension`): under its title
  (`:members_heading`), under each member's name (`:member_access`) and among each
  member's actions (`:member_actions`).

  A suspended membership is listed with its badge: its person acts here no more until it
  is activated. Owners suspend and activate admins and members, admins members only
  (`Apiary.Organisations.suspend_member/2`, `activate_member/2`); suspending is confirmed
  in a modal, `/:org/settings/people/:id/suspend`.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Organisations}
  alias Apiary.Organisations.Membership
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:members}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        kind={:organisation}
        sections={@sections}
        current={:people}
        measure="list"
        title={gettext("People")}
      >
        <:subtitle>
          {gettext(
            "The people in this organisation. Owners and admins manage members and settings; members manage keys and see the runs."
          )}
          <ApiaryWeb.Extension.slot name={:members_heading} scope={@current_scope} />
        </:subtitle>
        <:actions :if={Access.can?(@current_scope, :"member.invite", @current_scope.workspace)}>
          <.button
            id="invite-people"
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/settings/people/invite"}
          >
            <.icon name="hero-user-plus-micro" class="size-4" /> {gettext("Invite people")}
          </.button>
        </:actions>

        <.table id="members" label={gettext("Members")} rows={@members} row_id={&"member-#{&1.id}"}>
          <:col :let={m} label={gettext("Member")}>
            <div class="flex items-center gap-2.5">
              <.avatar
                name={m.user.email}
                kind={if m.user_id == @current_scope.user.id, do: "self", else: "person"}
              />
              <div class="grid min-w-0 gap-1">
                <div class="flex flex-wrap items-center gap-2.5">
                  <span class="font-medium">{m.user.email}</span>
                  <.badge :if={m.user_id == @current_scope.user.id}>{gettext("You")}</.badge>
                  <span :if={m.suspended_at} id={"member-#{m.id}-suspended"}>
                    <.badge color="warning" dot>{gettext("Suspended")}</.badge>
                  </span>
                </div>
                <ApiaryWeb.Extension.slot name={:member_access} scope={@current_scope} member={m} />
              </div>
            </div>
          </:col>
          <:col :let={m} label={gettext("Level")}>
            <%= if Access.can?(@current_scope, :"member.change_level", m) do %>
              <form phx-change="set_level" id={"level-form-#{m.id}"}>
                <input type="hidden" name="membership_id" value={m.id} />
                <label for={"level-#{m.id}"} class="sr-only">
                  {gettext("Level of %{email}", email: m.user.email)}
                </label>
                <select id={"level-#{m.id}"} name="level" class="select select-xs">
                  {Phoenix.HTML.Form.options_for_select(@levels, Atom.to_string(m.level))}
                </select>
              </form>
            <% else %>
              <.level_badge level={m.level} />
            <% end %>
          </:col>
          <:col :let={m} label={gettext("Joined")}>
            <span class="tabular-nums text-muted">{Format.date(m.inserted_at)}</span>
          </:col>
          <:action :let={m}>
            <ApiaryWeb.Extension.slot name={:member_actions} scope={@current_scope} member={m} />
          </:action>
          <:action
            :let={m}
            :if={
              Access.can?(@current_scope, :"member.suspend", @current_scope.organisation) or
                Access.can?(@current_scope, :"member.activate", @current_scope.organisation)
            }
          >
            <.button
              :if={is_nil(m.suspended_at) and Access.can?(@current_scope, :"member.suspend", m)}
              id={"member-#{m.id}-suspend"}
              variant="danger-ghost"
              size="xs"
              patch={~p"/#{@current_scope.organisation}/settings/people/#{m.id}/suspend"}
              aria-label={gettext("Suspend %{email}", email: m.user.email)}
            >
              {suspend_label(m)}
            </.button>
            <.button
              :if={m.suspended_at && Access.can?(@current_scope, :"member.activate", m)}
              id={"member-#{m.id}-activate"}
              size="xs"
              phx-click="activate"
              phx-value-id={m.id}
              aria-label={gettext("Activate %{email}", email: m.user.email)}
              loading_text={gettext("Activating")}
            >
              {gettext("Activate")}
            </.button>
          </:action>
          <%!-- Everyone may leave: the column is there for every reader. --%>
          <:action :let={m}>
            <.button
              :if={Access.can?(@current_scope, :"member.remove", m)}
              id={"member-#{m.id}-remove"}
              variant="danger-ghost"
              size="xs"
              patch={~p"/#{@current_scope.organisation}/settings/people/#{m.id}/remove"}
              aria-label={
                if m.user_id == @current_scope.user.id,
                  do:
                    gettext("Leave %{organisation}", organisation: @current_scope.organisation.name),
                  else: gettext("Remove %{email}", email: m.user.email)
              }
            >
              {if m.user_id == @current_scope.user.id,
                do: gettext("Leave"),
                else: gettext("Remove")}
            </.button>
          </:action>
        </.table>

        <section
          :if={
            Access.can?(@current_scope, :"member.invite", @current_scope.workspace) ||
              @invitations != []
          }
          class="mt-2 grid gap-3"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <h3 class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
              {gettext("Pending invitations")}
            </h3>
            <p class="text-[12.5px]/[18px] text-muted">
              {gettext("Invitations expire after seven days.")}
            </p>
          </div>
          <p :if={@invitations == []} class="text-muted">{gettext("No pending invitations.")}</p>
          <.table
            :if={@invitations != []}
            id="invitations"
            label={gettext("Pending invitations")}
            rows={@invitations}
            row_id={&"invitation-#{&1.id}"}
          >
            <:col :let={i} label={gettext("Email")}>
              <div class="flex items-center gap-2.5">
                <.avatar kind="pending" />
                <span class="font-medium">{i.email}</span>
              </div>
            </:col>
            <:col :let={i} label={gettext("Workspace")}>
              <span id={"invitation-#{i.id}-workspace"}>{i.workspace.name}</span>
            </:col>
            <:col :let={i} label={gettext("Sent")}>
              <span class="tabular-nums text-muted">{Format.date(i.inserted_at)}</span>
            </:col>
            <:col :let={i} label={gettext("Expires")}>
              <span class="tabular-nums text-muted">{Format.date(i.expires_at)}</span>
            </:col>
            <:action
              :let={i}
              :if={Access.can?(@current_scope, :"invitation.revoke", @current_scope.organisation)}
            >
              <.button
                :if={Access.can?(@current_scope, :"invitation.revoke", i)}
                variant="danger-ghost"
                size="xs"
                phx-click="revoke_invitation"
                phx-value-id={i.id}
                aria-label={gettext("Revoke the invitation to %{email}", email: i.email)}
              >
                {gettext("Revoke")}
              </.button>
            </:action>
          </.table>
        </section>
      </SettingsComponents.layout>

      <.modal
        :if={@live_action == :invite}
        id="invite-member"
        title={gettext("Invite a member")}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/settings/people")}
      >
        <p class="text-muted">
          {gettext(
            "We email an invitation link. It works for seven days and brings the person into %{workspace} as a member when they accept. An owner can change their level afterwards.",
            workspace: @current_scope.workspace && @current_scope.workspace.name
          )}
        </p>
        <.form
          for={@form}
          id="invitation-form"
          phx-change="validate_invite"
          phx-submit="invite"
          class="grid gap-4"
        >
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            placeholder={gettext("dana@example.com")}
            autocomplete="off"
            spellcheck="false"
            required
          />
        </.form>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/settings/people"}>{gettext("Cancel")}</.button>
          <.button
            variant="primary"
            type="submit"
            form="invitation-form"
            loading_text={gettext("Sending")}
          >
            {gettext("Send invitation")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :remove && @member}
        id="remove-member"
        title={
          if @member.user_id == @current_scope.user.id,
            do: gettext("Leave %{organisation}", organisation: @current_scope.organisation.name),
            else: gettext("Remove %{email}", email: @member.user.email)
        }
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/settings/people")}
      >
        <p class="text-muted">
          <%= if @member.user_id == @current_scope.user.id do %>
            {gettext(
              "You will leave %{organisation} and lose access to its workspaces and their runs at once. Your account stays; an owner can invite you again.",
              organisation: @current_scope.organisation.name
            )}
          <% else %>
            {gettext(
              "They leave %{organisation} and lose access to its workspaces and their runs at once. Their account stays; you can invite them again.",
              organisation: @current_scope.organisation.name
            )}
          <% end %>
        </p>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/settings/people"} data-autofocus>{gettext(
            "Cancel"
          )}</.button>
          <.button
            :if={@member.user_id == @current_scope.user.id}
            id="leave-confirm"
            variant="danger"
            phx-click="remove"
            loading_text={gettext("Leaving")}
          >
            {gettext("Leave the organisation")}
          </.button>
          <.button
            :if={@member.user_id != @current_scope.user.id}
            id="remove-confirm"
            variant="danger"
            phx-click="remove"
            loading_text={gettext("Removing")}
          >
            {gettext("Remove member")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :suspend && @member}
        id="suspend-member"
        title={gettext("Suspend %{email}", email: @member.user.email)}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/settings/people")}
      >
        <p class="text-muted">
          {suspend_sentence(@member, @current_scope.organisation)}
        </p>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/settings/people"} data-autofocus>
            {gettext("Cancel")}
          </.button>
          <.button
            id="suspend-confirm"
            variant="danger"
            phx-click="suspend"
            loading_text={gettext("Suspending")}
          >
            {suspend_label(@member)}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  # The levels a person may be given here.
  defp level_options do
    for level <- Membership.levels(), do: {level_text(level), Atom.to_string(level)}
  end

  defp level_text(:owner), do: gettext("Owner")
  defp level_text(:admin), do: gettext("Admin")
  defp level_text(:member), do: gettext("Member")

  attr :level, :atom, required: true

  defp level_badge(%{level: :owner} = assigns) do
    ~H"""
    <.badge>{gettext("Owner")}</.badge>
    """
  end

  defp level_badge(%{level: :admin} = assigns) do
    ~H"""
    <.badge>{gettext("Admin")}</.badge>
    """
  end

  defp level_badge(assigns) do
    ~H"""
    <.badge>{gettext("Member")}</.badge>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("People") <> " · " <> gettext("Organisation settings"),
       levels: level_options(),
       member: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, :member, nil)

  defp apply_action(socket, :invite, _params) do
    scope = socket.assigns.current_scope

    if Access.can?(scope, :"member.invite", scope.workspace) do
      socket
      |> assign(:member, nil)
      |> assign(:form, to_form(Organisations.change_invitation()))
    else
      refused(socket)
    end
  end

  defp apply_action(socket, :remove, %{"id" => id}) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        gone(socket)

      member ->
        if Access.can?(socket.assigns.current_scope, :"member.remove", member),
          do: assign(socket, :member, member),
          else: refused(socket)
    end
  end

  defp apply_action(socket, :suspend, %{"id" => id}) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        gone(socket)

      member ->
        cond do
          not Access.can?(socket.assigns.current_scope, :"member.suspend", member) ->
            refused(socket)

          # Suspended already: the list says so, and there is nothing to confirm.
          member.suspended_at ->
            push_patch(socket, to: members_path(socket))

          true ->
            assign(socket, :member, member)
        end
    end
  end

  defp gone(socket) do
    socket
    |> put_flash(:error, gettext("That member is no longer in the organisation."))
    |> push_patch(to: members_path(socket))
  end

  defp refused(socket) do
    socket
    |> put_flash(:error, refused_sentence())
    |> push_patch(to: members_path(socket))
  end

  defp refused_sentence,
    do:
      gettext(
        "Only owners and admins manage members, and only owners change a level or manage an owner or an admin."
      )

  @impl true
  def handle_event("validate_invite", %{"invitation" => params}, socket) do
    changeset = params |> Organisations.change_invitation() |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("invite", %{"invitation" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.invite_member(scope, params, &url(~p"/invitations/#{&1}")) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: invitation.email))
         |> load()
         |> push_patch(to: members_path(socket))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :delivery_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The invitation could not be sent, so it was not created. Try again.")
         )}

      # Undelivered, and it could not be taken back: it is still pending, and the page
      # lists it, where an owner revokes it.
      {:error, :delivery_failed_pending} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "The invitation could not be sent, and is still pending. Revoke it under Pending invitations, then try again."
           )
         )
         |> load()
         |> push_patch(to: members_path(socket))}

      {:error, :unconfirmed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Confirm your email address before you invite anyone: log in again with the link we email you."
           )
         )}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("set_level", %{"membership_id" => id, "level" => level}, socket)
      when level in ["owner", "admin", "member"] do
    scope = socket.assigns.current_scope

    member = Enum.find(socket.assigns.members, &(&1.id == id))

    case Organisations.set_member_level(scope, id, level) do
      {:ok, membership} ->
        socket = reload_scope(socket)
        changed = Enum.find(socket.assigns.members, &(&1.id == membership.id)) || member
        {:noreply, put_flash(socket, :info, level_changed(changed, membership.level))}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "The last owner cannot be removed or demoted. Make someone else an owner first."
           )
         )
         |> load()}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That member is no longer in the organisation."))
         |> load()}
    end
  end

  def handle_event("remove", _params, %{assigns: %{member: member}} = socket)
      when not is_nil(member) do
    scope = socket.assigns.current_scope

    case Organisations.remove_member(scope, member.id) do
      {:ok, _membership} when member.user_id == scope.user.id ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You left %{name}.", name: scope.organisation.name))
         |> redirect(to: ~p"/")}

      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{email} is removed.", email: member.user.email))
         |> load()
         |> push_patch(to: members_path(socket))}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "The last owner cannot be removed or demoted. Make someone else an owner first."
           )
         )
         |> push_patch(to: members_path(socket))}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That member is no longer in the organisation."))
         |> load()
         |> push_patch(to: members_path(socket))}
    end
  end

  def handle_event("suspend", _params, %{assigns: %{member: member}} = socket)
      when not is_nil(member) do
    case Organisations.suspend_member(socket.assigns.current_scope, member.id) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{email} is suspended.", email: member.user.email))
         |> load()
         |> push_patch(to: members_path(socket))}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The last owner who can act cannot be suspended."))
         |> load()
         |> push_patch(to: members_path(socket))}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, socket |> load() |> gone()}
    end
  end

  def handle_event("activate", %{"id" => id}, socket) do
    member = Enum.find(socket.assigns.members, &(&1.id == id))

    case Organisations.activate_member(socket.assigns.current_scope, id) do
      {:ok, _membership} when not is_nil(member) ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{email} is active again.", email: member.user.email))
         |> load()}

      {:ok, _membership} ->
        {:noreply, load(socket)}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, socket |> load() |> gone()}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    case Organisations.revoke_invitation(socket.assigns.current_scope, id) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Invitation to %{email} revoked.", email: invitation.email)
         )
         |> load()}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  # A level that is none of the three, a removal or a suspension without the member's
  # modal open, as a second click of a button whose modal has closed sends, or an
  # activation without a membership's id. One whose role allows the
  # action is shown the list again; one whose role does not is refused, as a path the page
  # offers no button for is.
  def handle_event(event, _params, socket) when event in ~w(set_level remove suspend activate) do
    scope = socket.assigns.current_scope

    action =
      case event do
        "remove" -> :"member.remove"
        "suspend" -> :"member.suspend"
        "activate" -> :"member.activate"
        "set_level" -> :"member.change_level"
      end

    if Access.can?(scope, action, scope.organisation),
      do: {:noreply, load(socket)},
      else: {:noreply, refused(socket)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    members = Organisations.list_members(scope)

    invitations =
      if Access.can?(scope, :"member.invite", scope.workspace),
        do: Organisations.list_invitations(scope),
        else: []

    socket
    |> assign(members: members, invitations: invitations)
    |> assign(:sections, SettingsComponents.sections(scope, :organisation))
    |> assign(:nav_counts, Map.put(socket.assigns.nav_counts || %{}, :members, length(members)))
  end

  # The current user's own level may have changed; reload the scope the path names, so
  # the page and the layout follow, and the members with it. A membership that is gone
  # sends the page to `/`, as `ApiaryWeb.UserAuth` does for every page.
  defp reload_scope(socket), do: socket |> UserAuth.reload_scope() |> load()

  defp members_path(socket),
    do: ~p"/#{socket.assigns.current_scope.organisation}/settings/people"

  # Refused on the membership as it is now: the page's scope is stale, and is loaded again.
  # A membership that is gone has sent the page to `/` by then.
  defp unauthorized(socket) do
    socket =
      socket
      |> put_flash(:error, refused_sentence())
      |> reload_scope()

    if socket.redirected, do: socket, else: push_patch(socket, to: members_path(socket))
  end

  # One sentence per level, and one for a member no longer listed.
  defp level_changed(%{user: %{email: email}}, :owner),
    do: gettext("%{email} is now an owner.", email: email)

  defp level_changed(%{user: %{email: email}}, :admin),
    do: gettext("%{email} is now an admin.", email: email)

  defp level_changed(%{user: %{email: email}}, :member),
    do: gettext("%{email} is now a member.", email: email)

  defp level_changed(nil, :owner), do: gettext("The member is now an owner.")
  defp level_changed(nil, :admin), do: gettext("The member is now an admin.")
  defp level_changed(nil, :member), do: gettext("The member is now a member.")

  defp suspend_label(%{level: :admin}), do: gettext("Suspend admin")
  defp suspend_label(_member), do: gettext("Suspend member")

  # Who may activate them again: an owner for an admin, an owner or an admin for a member.
  defp suspend_sentence(%{level: :admin}, organisation),
    do:
      gettext(
        "They can no longer open %{organisation} or act in it, until an owner activates them again. Nothing of theirs is removed: their level, their workspaces and what they made stay.",
        organisation: organisation.name
      )

  defp suspend_sentence(_member, organisation),
    do:
      gettext(
        "They can no longer open %{organisation} or act in it, until an owner or an admin activates them again. Nothing of theirs is removed: their level, their workspaces and what they made stay.",
        organisation: organisation.name
      )
end
