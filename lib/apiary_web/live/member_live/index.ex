defmodule ApiaryWeb.MemberLive.Index do
  @moduledoc """
  The hive's members and pending invitations. Owners invite, change levels
  and remove; members see the page read-only.
  """
  use ApiaryWeb, :live_view

  alias Apiary.Organisations

  @levels [Owner: "owner", Member: "member"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      nav={:members}
    >
      <.header>
        Members
        <:subtitle>
          The people in this <.term word="hive" />. Owners manage members, keys and settings;
          members manage keys and see every run.
        </:subtitle>
        <:actions :if={@owner?}>
          <.button variant="primary" patch={~p"/hive/members/invite"}>
            <.icon name="hero-plus-micro" class="size-4" /> Invite member
          </.button>
        </:actions>
      </.header>

      <.table id="members" rows={@members} row_id={&"member-#{&1.id}"}>
        <:col :let={m} label="Email">
          <span class="font-medium">{m.user.email}</span>
          <.badge :if={m.user_id == @current_scope.user.id} class="ml-2">you</.badge>
        </:col>
        <:col :let={m} label="Level">
          <%= if @owner? do %>
            <form phx-change="set_level" id={"level-form-#{m.id}"}>
              <input type="hidden" name="membership_id" value={m.id} />
              <label for={"level-#{m.id}"} class="sr-only">Level of {m.user.email}</label>
              <select
                id={"level-#{m.id}"}
                name="level"
                class="select-field h-8 cursor-pointer rounded-field border border-line-strong bg-surface pl-2.5 text-[13px] font-medium text-ink shadow-low transition hover:bg-surface-2"
              >
                {Phoenix.HTML.Form.options_for_select(@levels, Atom.to_string(m.level))}
              </select>
            </form>
          <% else %>
            <.level_badge level={m.level} />
          <% end %>
        </:col>
        <:col :let={m} label="Joined">
          <span class="text-ink-muted">{short_date(m.inserted_at)}</span>
        </:col>
        <:action :let={m} :if={@owner?}>
          <.button
            variant="ghost"
            size="sm"
            patch={~p"/hive/members/#{m.id}/remove"}
            class="text-danger hover:text-danger"
          >
            Remove
          </.button>
        </:action>
      </.table>

      <section :if={@owner? || @invitations != []} class="mt-8">
        <h2 class="mb-3 text-sm font-semibold text-ink">Pending invitations</h2>
        <p :if={@invitations == []} class="text-sm text-ink-muted">
          No pending invitations. Invitations expire after seven days.
        </p>
        <.table
          :if={@invitations != []}
          id="invitations"
          rows={@invitations}
          row_id={&"invitation-#{&1.id}"}
        >
          <:col :let={i} label="Email"><span class="font-medium">{i.email}</span></:col>
          <:col :let={i} label="Level"><.level_badge level={i.level} /></:col>
          <:col :let={i} label="Sent">
            <span class="text-ink-muted">{short_date(i.inserted_at)}</span>
          </:col>
          <:col :let={i} label="Expires">
            <span class="text-ink-muted">{short_date(i.expires_at)}</span>
          </:col>
          <:action :let={i} :if={@owner?}>
            <.button
              variant="ghost"
              size="sm"
              phx-click="revoke_invitation"
              phx-value-id={i.id}
              class="text-danger hover:text-danger"
            >
              Revoke
            </.button>
          </:action>
        </.table>
      </section>

      <.modal
        :if={@live_action == :invite}
        id="invite-member"
        title="Invite a member"
        on_cancel={JS.patch(~p"/hive/members")}
      >
        <p class="mb-4 text-ink-muted">
          We email an invitation link. It works for seven days and brings the person into this
          <.term word="hive" /> when they accept.
        </p>
        <.form for={@form} id="invitation-form" phx-change="validate_invite" phx-submit="invite">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:level]}
            type="select"
            label="Level"
            options={@levels}
            hint="Owners can manage members and settings. Members can manage keys and see runs."
          />
        </.form>
        <:footer>
          <.button patch={~p"/hive/members"}>Cancel</.button>
          <.button
            variant="primary"
            type="submit"
            form="invitation-form"
            phx-disable-with="Sending..."
          >
            Send invitation
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :remove && @member}
        id="remove-member"
        title={"Remove #{@member.user.email}"}
        on_cancel={JS.patch(~p"/hive/members")}
      >
        <p class="text-ink-muted">
          <%= if @member.user_id == @current_scope.user.id do %>
            You will leave this <.term word="hive" /> and lose access to it. Another owner can
            invite you back.
          <% else %>
            They lose access to this <.term word="hive" /> at once. You can invite them again
            later.
          <% end %>
        </p>
        <:footer>
          <.button patch={~p"/hive/members"}>Cancel</.button>
          <.button variant="danger" phx-click="remove" phx-disable-with="Removing...">
            Remove member
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  attr :level, :atom, required: true

  defp level_badge(%{level: :owner} = assigns) do
    ~H"""
    <.badge color="accent">Owner</.badge>
    """
  end

  defp level_badge(assigns) do
    ~H"""
    <.badge>Member</.badge>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Members",
       levels: @levels,
       owner?: Organisations.owner?(socket.assigns.current_scope),
       member: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, :member, nil)

  defp apply_action(%{assigns: %{owner?: false}} = socket, _action, _params) do
    socket
    |> put_flash(:error, "Only owners can manage members.")
    |> push_patch(to: ~p"/hive/members")
  end

  defp apply_action(socket, :invite, _params) do
    socket
    |> assign(:member, nil)
    |> assign(:form, to_form(Organisations.change_invitation()))
  end

  defp apply_action(socket, :remove, %{"id" => id}) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        socket
        |> put_flash(:error, "That member is no longer in the hive.")
        |> push_patch(to: ~p"/hive/members")

      member ->
        assign(socket, :member, member)
    end
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
         |> put_flash(:info, "Invitation sent to #{invitation.email}.")
         |> load()
         |> push_patch(to: ~p"/hive/members")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :delivery_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The invitation could not be sent, so it was not created. Try again."
         )}

      {:error, :unauthorized} ->
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
         |> put_flash(
           :info,
           "#{(member && member.user.email) || "The member"} is now #{level_word(membership.level)}."
         )
         |> reload_scope()
         |> load()}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "The last owner cannot be demoted. Make someone else an owner first."
         )
         |> load()}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, socket |> put_flash(:error, "That member is no longer in the hive.") |> load()}
    end
  end

  def handle_event("remove", _params, %{assigns: %{member: member}} = socket)
      when not is_nil(member) do
    scope = socket.assigns.current_scope

    case Organisations.remove_member(scope, member.id) do
      {:ok, _membership} when member.user_id == scope.user.id ->
        {:noreply,
         socket
         |> put_flash(:info, "You left the #{scope.hive.name} hive.")
         |> redirect(to: ~p"/")}

      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{member.user.email} is removed.")
         |> load()
         |> push_patch(to: ~p"/hive/members")}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "The last owner cannot be removed. Make someone else an owner first."
         )
         |> push_patch(to: ~p"/hive/members")}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That member is no longer in the hive.")
         |> load()
         |> push_patch(to: ~p"/hive/members")}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    case Organisations.revoke_invitation(socket.assigns.current_scope, id) do
      {:ok, invitation} ->
        {:noreply,
         socket |> put_flash(:info, "Invitation to #{invitation.email} revoked.") |> load()}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    members = Organisations.list_members(scope)

    invitations =
      if socket.assigns.owner?, do: Organisations.list_invitations(scope), else: []

    assign(socket, members: members, invitations: invitations)
  end

  # The current user's own level may have changed; reload the scope so the
  # page and the layout follow.
  defp reload_scope(socket) do
    scope = socket.assigns.current_scope

    scope =
      Organisations.load_scope(
        %{scope | organisation: nil, hive: nil, membership: nil},
        scope.organisation.id
      )

    assign(socket, current_scope: scope, owner?: Organisations.owner?(scope))
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Only owners can manage members.")
    |> assign(:owner?, false)
    |> load()
    |> push_patch(to: ~p"/hive/members")
  end

  defp level_word(:owner), do: "an owner"
  defp level_word(:member), do: "a member"
end
