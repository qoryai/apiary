defmodule ApiaryWeb.MemberLive.Index do
  @moduledoc """
  The members and pending invitations, an organisation's page: `/:org/members`
  (decision 0073). The workspace they are listed for is the one of the user's membership
  in the organisation. Owners invite, change levels and remove; members see the page
  read-only.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Organisations}
  alias ApiaryWeb.UserAuth

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
      <.header>
        {gettext("Members")}
        <:subtitle>
          {gettext(
            "The people in this workspace. Owners manage members, keys and settings; members manage keys and see every run."
          )}
        </:subtitle>
        <:actions :if={Access.can?(@current_scope, :"member.invite", @current_scope.workspace)}>
          <.button variant="primary" patch={~p"/#{@current_scope.organisation}/members/invite"}>
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("Invite member")}
          </.button>
        </:actions>
      </.header>

      <.table id="members" label={gettext("Members")} rows={@members} row_id={&"member-#{&1.id}"}>
        <:col :let={m} label={gettext("Member")}>
          <div class="flex items-center gap-2.5">
            <.avatar
              name={m.user.email}
              kind={if m.user_id == @current_scope.user.id, do: "self", else: "person"}
            />
            <span class="font-medium">{m.user.email}</span>
            <.badge :if={m.user_id == @current_scope.user.id}>{gettext("You")}</.badge>
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
        <:action
          :let={m}
          :if={Access.can?(@current_scope, :"member.remove", @current_scope.workspace)}
        >
          <.button
            variant="danger-ghost"
            size="xs"
            patch={~p"/#{@current_scope.organisation}/members/#{m.id}/remove"}
            aria-label={gettext("Remove %{email}", email: m.user.email)}
          >
            {gettext("Remove")}
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
          <h2 class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
            {gettext("Pending invitations")}
          </h2>
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
          <:col :let={i} label={gettext("Level")}><.level_badge level={i.level} /></:col>
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

      <.modal
        :if={@live_action == :invite}
        id="invite-member"
        title={gettext("Invite a member")}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/members")}
      >
        <p class="text-muted">
          {gettext(
            "We email an invitation link. It works for seven days and brings the person into this workspace when they accept."
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
          <.input
            field={@form[:level]}
            type="select"
            label={gettext("Level")}
            options={@levels}
            hint={
              gettext("Owners manage members and settings. Members manage keys and see every run.")
            }
          />
        </.form>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/members"}>{gettext("Cancel")}</.button>
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
        title={gettext("Remove %{email}", email: @member.user.email)}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/members")}
      >
        <p class="text-muted">
          <%= if @member.user_id == @current_scope.user.id do %>
            {gettext(
              "You will leave this workspace and lose access to its runs at once. Your account stays; an owner can invite you again."
            )}
          <% else %>
            {gettext(
              "They lose access to this workspace and its runs at once. Their account stays; you can invite them again."
            )}
          <% end %>
        </p>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/members"} data-autofocus>{gettext(
            "Cancel"
          )}</.button>
          <.button variant="danger" phx-click="remove" loading_text={gettext("Removing")}>
            {gettext("Remove member")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  attr :level, :atom, required: true

  defp level_badge(%{level: :owner} = assigns) do
    ~H"""
    <.badge>{gettext("Owner")}</.badge>
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
       page_title: gettext("Members"),
       levels: [{gettext("Owner"), "owner"}, {gettext("Member"), "member"}],
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
        socket
        |> put_flash(:error, gettext("That member is no longer in the workspace."))
        |> push_patch(to: members_path(socket))

      member ->
        if Access.can?(socket.assigns.current_scope, :"member.remove", member),
          do: assign(socket, :member, member),
          else: refused(socket)
    end
  end

  defp refused(socket) do
    socket
    |> put_flash(:error, gettext("Only owners can manage members."))
    |> push_patch(to: members_path(socket))
  end

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

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("set_level", %{"membership_id" => id, "level" => level}, socket)
      when level in ["owner", "member"] do
    scope = socket.assigns.current_scope

    member = Enum.find(socket.assigns.members, &(&1.id == id))

    case Organisations.set_member_level(scope, id, level) do
      {:ok, membership} ->
        {:noreply,
         socket
         |> put_flash(:info, level_changed(member, membership.level))
         |> reload_scope()}

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
         |> put_flash(:error, gettext("That member is no longer in the workspace."))
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
         |> put_flash(
           :info,
           gettext("You left the %{name} workspace.", name: scope.workspace.name)
         )
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
         |> put_flash(:error, gettext("That member is no longer in the workspace."))
         |> load()
         |> push_patch(to: members_path(socket))}
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

  defp load(socket) do
    scope = socket.assigns.current_scope

    members = Organisations.list_members(scope)

    invitations =
      if Access.can?(scope, :"member.invite", scope.workspace),
        do: Organisations.list_invitations(scope),
        else: []

    socket
    |> assign(members: members, invitations: invitations)
    |> assign(:nav_counts, Map.put(socket.assigns.nav_counts || %{}, :members, length(members)))
  end

  # The current user's own level may have changed; reload the scope the path names, so
  # the page and the layout follow, and the members with it. A membership that is gone
  # sends the page to `/`, as `ApiaryWeb.UserAuth` does for every page.
  defp reload_scope(socket), do: socket |> UserAuth.reload_scope() |> load()

  defp members_path(socket), do: ~p"/#{socket.assigns.current_scope.organisation}/members"

  # Refused on the membership as it is now: the page's scope is stale, and is loaded again.
  # A membership that is gone has sent the page to `/` by then.
  defp unauthorized(socket) do
    socket =
      socket
      |> put_flash(:error, gettext("Only owners can manage members."))
      |> reload_scope()

    if socket.redirected, do: socket, else: push_patch(socket, to: members_path(socket))
  end

  # One sentence per level, and one for a member no longer listed.
  defp level_changed(%{user: %{email: email}}, :owner),
    do: gettext("%{email} is now an owner.", email: email)

  defp level_changed(%{user: %{email: email}}, :member),
    do: gettext("%{email} is now a member.", email: email)

  defp level_changed(nil, :owner), do: gettext("The member is now an owner.")
  defp level_changed(nil, :member), do: gettext("The member is now a member.")
end
