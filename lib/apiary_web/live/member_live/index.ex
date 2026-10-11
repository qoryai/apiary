defmodule ApiaryWeb.MemberLive.Index do
  @moduledoc """
  The members and pending invitations, the People section of an organisation's settings
  (`ApiaryWeb.SettingsComponents`): `/:org/settings/people`. A membership is the
  organisation's: every member is listed, with their level.

  Owners change levels, and remove anyone; admins remove members only, and change no
  level; owners and admins invite; anyone may leave. An invitation is an email address
  and nothing else: it is sent from the workspace the page carries, grants it, and its
  person joins as a member. Inviting is a form page of the section,
  `/:org/settings/people/invite` (`ApiaryWeb.PageComponents.page_form/1`: Back, its
  title, one sentence, the form, its button and Cancel back to People); a sent invitation
  goes back to People with a flash. Members see the page read-only. What each may is asked of
  `Apiary.Access`.

  **Without mail** (`Apiary.Mail.configured?/0`) nothing is emailed: the form's button
  creates an invitation link, and the page shows it in place of the form, once
  (`CoreComponents.one_time_link/1`), for the inviter to copy and send themselves, with
  Done back to People. A pending invitation's ⋯ menu makes a new link for it, Make a new
  link (`Apiary.Organisations.renew_invitation/3`), which its row shows in place of its
  cells, once, with Done; the old link stops working at once. A link lives in the page's
  process alone, wrapped in a function so no inspection of the process's state prints it,
  until the reader leaves it: any path starts without it, and no path, flash or title
  carries it.

  Each person is one row on the row spec (`docs/ui.md`, Lists): the email is the title,
  the level is plain text, and what a reader may do to a membership is in its ⋯ menu:
  the level, as a choice of three with what each may do, suspending, activating and
  removing, each of the last three but activating confirmed in place, the member's row
  turned into its confirmation (`CoreComponents.inline_confirm/1`) at a path of its own,
  `/:org/settings/people/:id/remove` or `…/suspend`, whose Cancel goes back to People.

  An edition adds to the page through its slots (`ApiaryWeb.Extension`): under its title
  (`:members_heading`), beside each member's name (`:member_access`) and among the items
  of each member's menu (`:member_actions`).

  A suspended membership says so in place of its level: its person acts here no more
  until it is activated. Owners suspend and activate admins and members, admins members only
  (`Apiary.Organisations.suspend_member/2`, `activate_member/2`); suspending is confirmed
  on the member's row, `/:org/settings/people/:id/suspend`.

  **Password links.** On the People page of the instance's organisation, while no mail is
  set (`Apiary.Mail.configured?/0`), an instance admin's ⋯ menu of each other member has
  Make a password link (`Apiary.Accounts.build_password_link/3`): a link that sets that
  account's password, for a person who forgot theirs. It needs a recent sign-in, as
  Account settings do: an admin whose sign-in is older is sent to log in again first. It
  works once, for 24 hours, or until mail is set (`Apiary.Mail.end_password_links/0`), and
  a new one ends the one before. The page shows it once, above the list, to copy and send
  to the person, until Done or until the reader leaves (`CoreComponents.one_time_link/1`,
  `kind: :password`); it keeps the link in its own process alone, never in a path, a flash
  or a title.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Accounts, Mail, Organisations}
  alias Apiary.Organisations.{Invitation, Membership}
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  @impl true
  # Inviting is a form page of the section (`PageComponents.page_form/1`), never a
  # dialog: the section's list beside it, the breadcrumb ending with People and the page,
  # its Back link, title and one sentence, the form, its button and Cancel back to People.
  def render(%{page: :invite} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:members}
      sections={@sections}
      section={:people}
    >
      <:crumb>{gettext("Invite people")}</:crumb>

      <.page_form
        id="invite"
        title={gettext("Invite people")}
        cancel={~p"/#{@current_scope.organisation}/settings/people"}
        cancel_by="patch"
      >
        <:description :if={!@link and @mail?}>
          {gettext(
            "We email them a link that works for seven days and brings them into %{workspace} as a member; an owner can change their level afterwards.",
            workspace: @current_scope.workspace.name
          )}
        </:description>
        <:description :if={!@link and !@mail?}>
          {gettext(
            "You get a link to send them yourself. It works for seven days and brings them into %{workspace} as a member; an owner can change their level afterwards.",
            workspace: @current_scope.workspace.name
          )}
        </:description>
        <%!-- The link made, once, in place of the form. --%>
        <.one_time_link
          :if={@link}
          id="invitation-link"
          url={@link.url.()}
          expires_at={@link.invitation.expires_at}
          for={@link.invitation.email}
        >
          <:actions>
            <.button
              id="invitation-link-done"
              variant="primary"
              patch={~p"/#{@current_scope.organisation}/settings/people"}
            >
              {gettext("Done")}
            </.button>
          </:actions>
        </.one_time_link>
        <.form
          :if={!@link}
          for={@form}
          id="invitation-form"
          phx-change="validate_invite"
          phx-submit="invite"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            placeholder={gettext("dana@example.com")}
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.page_form_foot
            id="invitation-save"
            cancel={~p"/#{@current_scope.organisation}/settings/people"}
            cancel_by="patch"
          >
            <.button
              :if={@mail?}
              variant="primary"
              type="submit"
              loading_text={gettext("Sending")}
            >
              {gettext("Send invitation")}
            </.button>
            <.button
              :if={!@mail?}
              variant="primary"
              type="submit"
              loading_text={gettext("Creating…")}
            >
              {gettext("Create invitation link")}
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
      nav={:members}
      sections={@sections}
      section={:people}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:organisation}
        current={:people}
        measure="list"
        title={gettext("People")}
      >
        <:subtitle>
          {if members_edit_rules?(@current_scope),
            do:
              gettext(
                "The people in this organisation. Owners and admins manage members, settings and nodes; members see the runs and change the policy's rules that are not locked."
              ),
            else:
              gettext(
                "The people in this organisation. Owners and admins manage members, settings and nodes; members see the runs."
              )}
          <ApiaryWeb.Extension.slot name={:members_heading} scope={@current_scope} />
        </:subtitle>
        <:actions :if={Access.can?(@current_scope, :"member.invite", @current_scope.workspace)}>
          <.button
            id="invite-people"
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/settings/people/invite"}
          >
            <.icon name="hero-user-plus" class="size-4" /> {gettext("Invite people")}
          </.button>
        </:actions>

        <.one_time_link
          :if={@password_link}
          id="password-link"
          url={@password_link.url.()}
          expires_at={@password_link.expires_at}
          for={@password_link.email}
          kind={:password}
          class="mb-2"
        >
          <:actions>
            <.button id="password-link-done" size="sm" phx-click="password_link_done">
              {gettext("Done")}
            </.button>
          </:actions>
        </.one_time_link>

        <.list_search
          id="people-search"
          name="q"
          value={@q}
          label={gettext("Find a person")}
          placeholder={gettext("Find a person by email")}
          change="find"
          class="max-w-[28rem]"
        />
        <%!-- Always there, so a screen reader hears what the search left. --%>
        <div id="people-status" role="status" class="q-status">
          <p :if={@q != ""} id="people-summary" class="text-[13px] text-muted">
            {ngettext("%{number} person matches", "%{number} people match", length(@shown),
              number: Format.number(length(@shown))
            )}
          </p>
        </div>

        <p :if={@shown == []} id="people-none" class="text-[13px] text-muted">
          {gettext("No member's email has %{text}.", text: @q)}
        </p>
        <.table
          :if={@shown != []}
          id="members"
          label={gettext("Members")}
          rows={@shown}
          row_id={&"member-#{&1.id}"}
          row_class={&(&1.suspended_at && "row-off")}
          confirming={@member && "member-#{@member.id}"}
        >
          <:col :let={m} label={gettext("Member")} kind="title">
            <span class="q-nm">
              <.avatar
                name={m.user.email}
                kind={if m.user_id == @current_scope.user.id, do: "self", else: "person"}
              />
              <span class="q-title">{m.user.email}</span>
              <span :if={m.user_id == @current_scope.user.id} class="q-side">{gettext("you")}</span>
              <ApiaryWeb.Extension.slot name={:member_access} scope={@current_scope} member={m} />
            </span>
          </:col>
          <:col :let={m} label={gettext("Level")}>
            <.state_word :if={m.suspended_at} id={"member-#{m.id}-suspended"}>
              {gettext("Suspended")}
            </.state_word>
            <span :if={!m.suspended_at} id={"member-#{m.id}-level"}>{level_text(m.level)}</span>
          </:col>
          <:col :let={m} label={gettext("Joined")} from="sm">
            <span class="tabular-nums">{Format.day(m.inserted_at)}</span>
          </:col>
          <:confirm :let={m}>
            <.member_confirm member={m} act={@live_action} scope={@current_scope} />
          </:confirm>
          <:action :let={m}>
            <.row_menu
              id={"member-#{m.id}-menu"}
              label={gettext("Actions for %{email}", email: m.user.email)}
            >
              <%= if Access.can?(@current_scope, :"member.change_level", m) do %>
                <.menu_heading title={m.user.email} sub={gettext("Level")} />
                <.menu_item
                  :for={{level, hint} <- level_hints(@current_scope)}
                  id={"member-#{m.id}-level-#{level}"}
                  checked={m.level == level}
                  hint={hint}
                  phx-click="set_level"
                  phx-value-membership_id={m.id}
                  phx-value-level={level}
                >
                  {level_text(level)}
                </.menu_item>
                <.menu_divider />
              <% end %>
              <ApiaryWeb.Extension.slot name={:member_actions} scope={@current_scope} member={m} />
              <.menu_item
                :if={@password_links? and m.user_id != @current_scope.user.id}
                id={"member-#{m.id}-password-link"}
                phx-click="password_link"
                phx-value-membership_id={m.id}
                aria-label={gettext("Make a password link for %{email}", email: m.user.email)}
              >
                {gettext("Make a password link")}
              </.menu_item>
              <.menu_item
                :if={is_nil(m.suspended_at) and Access.can?(@current_scope, :"member.suspend", m)}
                id={"member-#{m.id}-suspend"}
                patch={~p"/#{@current_scope.organisation}/settings/people/#{m.id}/suspend"}
                aria-label={gettext("Suspend %{email}", email: m.user.email)}
              >
                {gettext("Suspend…")}
              </.menu_item>
              <.menu_item
                :if={m.suspended_at && Access.can?(@current_scope, :"member.activate", m)}
                id={"member-#{m.id}-activate"}
                phx-click="activate"
                phx-value-id={m.id}
                aria-label={gettext("Activate %{email}", email: m.user.email)}
              >
                {gettext("Activate")}
              </.menu_item>
              <.menu_item
                :if={Access.can?(@current_scope, :"member.remove", m)}
                id={"member-#{m.id}-remove"}
                patch={~p"/#{@current_scope.organisation}/settings/people/#{m.id}/remove"}
                aria-label={
                  if m.user_id == @current_scope.user.id,
                    do:
                      gettext("Leave %{organisation}", organisation: @current_scope.organisation.name),
                    else: gettext("Remove %{email}", email: m.user.email)
                }
              >
                {if m.user_id == @current_scope.user.id,
                  do: gettext("Leave…"),
                  else: gettext("Remove…")}
              </.menu_item>
            </.row_menu>
          </:action>
        </.table>

        <section
          :if={
            Access.can?(@current_scope, :"member.invite", @current_scope.workspace) ||
              @invitations != []
          }
          class="mt-4 grid gap-3"
        >
          <h2 class="flex items-baseline gap-2 text-[14px]/5 font-semibold">
            {gettext("Pending invitations")}
            <span :if={@invitations != []} class="text-[12.5px] font-normal tabular-nums text-faint">
              {Format.number(length(@invitations))}
            </span>
          </h2>
          <p :if={@invitations == []} class="text-[12.5px] text-muted">
            {gettext("No pending invitations.")}
          </p>
          <.table
            :if={@invitations != []}
            id="invitations"
            label={gettext("Pending invitations")}
            rows={@invitations}
            row_id={&"invitation-#{&1.id}"}
            confirming={@renewed && "invitation-#{@renewed.invitation.id}"}
          >
            <:col :let={i} label={gettext("Email")} kind="title">
              <span class="q-nm">
                <.avatar kind="pending" />
                <span class="q-title">{i.email}</span>
              </span>
            </:col>
            <:col :let={i} label={gettext("Workspace")}>
              <span id={"invitation-#{i.id}-workspace"}>{i.workspace.name}</span>
            </:col>
            <:col :let={i} label={gettext("Sent")} from="sm">
              <span class="tabular-nums">{Format.day(i.inserted_at)}</span>
            </:col>
            <:col :let={i} label={gettext("Expires")}>
              <span class={["tabular-nums", expires_soon?(i) && "q-hot"]}>
                {Format.day(i.expires_at)}
              </span>
            </:col>
            <%!-- A new link, shown once in place of the row's cells. --%>
            <:confirm :let={i}>
              <.one_time_link
                id={"invitation-#{i.id}-link"}
                url={@renewed.url.()}
                expires_at={@renewed.invitation.expires_at}
                for={i.email}
                class="py-1"
              >
                <:actions>
                  <.button
                    id={"invitation-#{i.id}-link-done"}
                    variant="primary"
                    size="xs"
                    phx-click="link_done"
                  >
                    {gettext("Done")}
                  </.button>
                </:actions>
              </.one_time_link>
            </:confirm>
            <:action
              :let={i}
              :if={Access.can?(@current_scope, :"invitation.revoke", @current_scope.organisation)}
            >
              <.row_menu
                :if={
                  Access.can?(@current_scope, :"invitation.revoke", i) or
                    (!@mail? and Access.can?(@current_scope, :"invitation.renew", i))
                }
                id={"invitation-#{i.id}-menu"}
                label={gettext("Actions for the invitation to %{email}", email: i.email)}
              >
                <.menu_item
                  :if={!@mail? and Access.can?(@current_scope, :"invitation.renew", i)}
                  id={"invitation-#{i.id}-renew"}
                  phx-click="renew_invitation"
                  phx-value-id={i.id}
                  aria-label={gettext("Make a new link for %{email}", email: i.email)}
                >
                  {gettext("Make a new link")}
                </.menu_item>
                <.menu_item
                  :if={Access.can?(@current_scope, :"invitation.revoke", i)}
                  id={"invitation-#{i.id}-revoke"}
                  phx-click="revoke_invitation"
                  phx-value-id={i.id}
                  aria-label={gettext("Revoke the invitation to %{email}", email: i.email)}
                >
                  {gettext("Revoke")}
                </.menu_item>
              </.row_menu>
            </:action>
          </.table>
          <p class="text-[12.5px]/[18px] text-faint">
            {gettext("An invitation expires after seven days.")}
            <span :if={only_owner_held?(@current_scope, @members)}>
              {gettext(
                "The only owner cannot be removed or demoted until another member is an owner."
              )}
            </span>
          </p>
        </section>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  # A removal, a leaving or a suspension, confirmed in place on the member's row, at its
  # own path; Cancel and Escape go back to People.
  attr :member, Membership, required: true
  attr :act, :atom, required: true, values: [:remove, :suspend]
  attr :scope, :any, required: true

  defp member_confirm(%{act: :remove} = assigns) do
    ~H"""
    <.inline_confirm
      id={"member-#{@member.id}-remove-confirm"}
      question={
        if @member.user_id == @scope.user.id,
          do: gettext("Leave %{organisation}?", organisation: @scope.organisation.name),
          else: gettext("Remove %{email}?", email: @member.user.email)
      }
      cancel={~p"/#{@scope.organisation}/settings/people"}
    >
      <%= if @member.user_id == @scope.user.id do %>
        {gettext(
          "You will leave %{organisation} and lose access to its workspaces and their runs at once. Your account stays; an owner can invite you again.",
          organisation: @scope.organisation.name
        )}
      <% else %>
        {gettext(
          "They leave %{organisation} and lose access to its workspaces and their runs at once. Their account stays; you can invite them again.",
          organisation: @scope.organisation.name
        )}
      <% end %>
      <:action>
        <.button
          :if={@member.user_id == @scope.user.id}
          id="leave-confirm"
          variant="danger"
          size="xs"
          phx-click="remove"
          loading_text={gettext("Leaving")}
        >
          {gettext("Yes, leave")}
        </.button>
        <.button
          :if={@member.user_id != @scope.user.id}
          id="remove-confirm"
          variant="danger"
          size="xs"
          phx-click="remove"
          loading_text={gettext("Removing")}
        >
          {gettext("Yes, remove")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp member_confirm(%{act: :suspend} = assigns) do
    ~H"""
    <.inline_confirm
      id={"member-#{@member.id}-suspend-confirm"}
      question={gettext("Suspend %{email}?", email: @member.user.email)}
      cancel={~p"/#{@scope.organisation}/settings/people"}
    >
      {suspend_sentence(@member, @scope.organisation)}
      <:action>
        <.button
          id="suspend-confirm"
          variant="danger"
          size="xs"
          phx-click="suspend"
          loading_text={gettext("Suspending")}
        >
          {gettext("Yes, suspend")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp level_text(:owner), do: gettext("Owner")
  defp level_text(:admin), do: gettext("Admin")
  defp level_text(:member), do: gettext("Member")

  # The levels a person may be given here, each with what it may do.
  defp level_hints(scope) do
    for level <- Membership.levels(), do: {level, level_hint(level, scope)}
  end

  defp level_hint(:owner, _scope),
    do: gettext("Changes everything, including who owns the organisation")

  defp level_hint(:admin, _scope), do: gettext("Manages members, workspaces, nodes and settings")

  defp level_hint(:member, scope) do
    if members_edit_rules?(scope),
      do: gettext("Sees the runs and changes the policy's unlocked rules"),
      else: gettext("Sees the runs")
  end

  # Whether a member changes the policy's rules that are not locked: asked of the roles
  # (`Apiary.Access`) and of the features where the page is, never of a level written here.
  defp members_edit_rules?(scope),
    do:
      :"security_policy.edit" in Map.get(Access.roles(), :member, []) and
        Apiary.Features.on?(scope, :security)

  # Whether the organisation has one owner, whom the last-owner rule holds in place, and
  # the reader is one who would otherwise change that owner's level: only to them does the
  # rule say anything.
  defp only_owner_held?(scope, members) do
    case Enum.filter(members, &(&1.level == :owner)) do
      [owner] -> Access.can?(scope, :"member.change_level", owner)
      _none_or_several -> false
    end
  end

  # An invitation that runs out within a day is the one fact of its row to act on.
  defp expires_soon?(invitation),
    do: DateTime.diff(invitation.expires_at, DateTime.utc_now(), :hour) < 24

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: title(socket.assigns.current_scope, gettext("People")),
       page: nil,
       form: nil,
       member: nil,
       link: nil,
       renewed: nil,
       mail?: Mail.configured?(),
       password_link: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Every path starts without a link shown: it is shown once, until the reader leaves.
    socket =
      assign(socket,
        page: nil,
        form: nil,
        link: nil,
        renewed: nil,
        password_link: nil,
        mail?: Mail.configured?()
      )

    {:noreply, socket |> apply_action(socket.assigns.live_action, params) |> titled()}
  end

  # The browser's title: Invite people is named by its act, the rest by the section.
  defp titled(%{assigns: %{page: :invite}} = socket),
    do: assign(socket, :page_title, title(socket.assigns.current_scope, gettext("Invite people")))

  defp titled(socket),
    do: assign(socket, :page_title, title(socket.assigns.current_scope, gettext("People")))

  defp title(scope, words), do: SettingsComponents.page_title(scope, :organisation, [words])

  defp apply_action(socket, :index, params),
    do: socket |> assign(:member, nil) |> find(params["q"])

  defp apply_action(socket, :invite, _params) do
    scope = socket.assigns.current_scope

    if Access.can?(scope, :"member.invite", scope.workspace) do
      socket
      |> assign(:member, nil)
      |> assign(:page, :invite)
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
  # The search is the URL's `q`: a person is found by their email, whatever its case.
  def handle_event("find", %{"q" => q}, socket) do
    q = String.trim(q)
    path = ~p"/#{socket.assigns.current_scope.organisation}/settings/people"

    {:noreply,
     push_patch(socket,
       to: if(q == "", do: path, else: path <> "?" <> URI.encode_query(q: q)),
       replace: true
     )}
  end

  def handle_event("validate_invite", %{"invitation" => params}, socket) do
    changeset =
      %Invitation{}
      |> Organisations.change_invitation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("invite", %{"invitation" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.invite_member(scope, params, &url(~p"/invitations/#{&1}")) do
      # Without mail: the link, shown once in place of the form, in a function so no
      # inspection of the process's state prints it.
      {:ok, invitation, {:link, link}} ->
        {:noreply,
         socket
         |> assign(:link, %{invitation: invitation, url: fn -> link end})
         |> load()}

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

  # A password link for a member's account, made by an instance admin while no mail is set,
  # shown once above the list: the context asks who may (`Accounts.build_password_link/3`).
  # Only where the page offers them (`password_links?/1`): the context makes one for any
  # account, so an event sent anywhere else is refused here, as the context would refuse
  # it on the instance's organisation's page.
  def handle_event("password_link", %{"membership_id" => id}, socket) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        {:noreply, socket |> load() |> gone()}

      member ->
        case password_link(socket, member) do
          # The link in a function, as an invitation's, so no inspection of the process's
          # state prints it.
          {:ok, url, expires_at} ->
            {:noreply,
             assign(socket, :password_link, %{
               email: member.user.email,
               url: fn -> url end,
               expires_at: expires_at
             })}

          {:error, :mail_set} ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(
               :error,
               gettext(
                 "Qory Apiary sends email now: they get a log-in link from the log-in page instead."
               )
             )
             |> load()}

          {:error, :not_found} ->
            {:noreply, socket |> assign(:password_link, nil) |> load() |> gone()}

          {:error, :own_account} ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(:error, gettext("Change your own password in Account settings."))}

          # The sign-in is not recent: signed in again first, as the Mail page asks.
          {:error, :sudo} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("You must re-authenticate to access this page."))
             |> redirect(to: ~p"/users/log-in")}

          {:error, reason} when reason in [:forbidden, :no_instance_organisation] ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(
               :error,
               gettext(
                 "Only an admin of this Qory Apiary makes password links, while it sends no email."
               )
             )
             |> load()}

          # An account the edition refuses gets no link.
          {:error, _refusal} ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(
               :error,
               gettext("That account cannot log in at the moment, so it gets no password link.")
             )}
        end
    end
  end

  def handle_event("password_link_done", _params, socket),
    do: {:noreply, assign(socket, :password_link, nil)}

  def handle_event("renew_invitation", %{"id" => id}, socket) do
    case Organisations.renew_invitation(
           socket.assigns.current_scope,
           id,
           &url(~p"/invitations/#{&1}")
         ) do
      # Shown once on its row, in a function as the invite page's is.
      {:ok, invitation, {:link, link}} ->
        {:noreply,
         socket
         |> load()
         |> assign(:renewed, %{invitation: invitation, url: fn -> link end})}

      # Mail was set meanwhile: the new link is emailed.
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: invitation.email))
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, no_new_link(changeset, socket.assigns.invitations, id))
         |> load()}

      {:error, :delivery_failed_pending} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "The invitation could not be sent, and is still pending. Revoke it under Pending invitations, then try again."
           )
         )
         |> load()}

      {:error, :unconfirmed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Confirm your email address before you invite anyone: log in again with the link we email you."
           )
         )}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      # Accepted, revoked or expired meanwhile: the list shows it gone.
      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("link_done", _params, socket),
    do: {:noreply, assign(socket, :renewed, nil)}

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
  # confirmation open, as a second click of a button whose confirmation has gone sends, or
  # an activation without a membership's id. One whose role allows the action is shown the
  # list again; one whose role does not is refused, as a path the page offers no button
  # for is.
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

  # The members the search leaves, `shown`, in the list's order.
  defp find(socket, q) do
    q = String.trim(q || "")
    needle = String.downcase(q)

    shown =
      if needle == "",
        do: socket.assigns.members,
        else:
          Enum.filter(
            socket.assigns.members,
            &String.contains?(String.downcase(&1.user.email), needle)
          )

    assign(socket, q: q, shown: shown)
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
    |> assign(:password_links?, password_links?(scope))
    |> find(socket.assigns[:q])
    |> assign(:sections, SettingsComponents.sections(scope, :organisation))
    |> assign(:nav_counts, Map.put(socket.assigns.nav_counts || %{}, :members, length(members)))
  end

  defp password_link(%{assigns: %{password_links?: true}} = socket, member) do
    Accounts.build_password_link(
      socket.assigns.current_scope,
      member.user,
      &url(~p"/users/password/#{&1}")
    )
  end

  defp password_link(_socket, _member),
    do: {:error, if(Mail.configured?(), do: :mail_set, else: :forbidden)}

  # Whether the page offers password links: on the instance's organisation, to an instance
  # admin, while no mail is set. The context asks again when one is made.
  defp password_links?(scope) do
    scope.organisation.id == Apiary.Edition.instance_organisation_id() and
      not Apiary.Mail.configured?() and Access.instance_admin?(scope)
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

  # A new link refused over the day's invitations, in the words of the refusal of an
  # invitation, said of the invitation's address.
  defp no_new_link(%Ecto.Changeset{errors: errors}, invitations, id) do
    email = Enum.find_value(invitations, "", &(&1.id == id && &1.email))
    {_message, opts} = Keyword.fetch!(errors, :email)

    case opts[:validation] do
      :invitation_attempts_per_day ->
        gettext(
          "No new link for %{email}: this organisation has tried to send %{limit} invitations in the last 24 hours, delivered or not, as many as it may. Try again later.",
          email: email,
          limit: Format.number(opts[:limit])
        )

      :invitations_per_day ->
        gettext(
          "No new link for %{email}: this organisation has made %{limit} invitations in the last 24 hours, as many as it may. Try again later.",
          email: email,
          limit: Format.number(opts[:limit])
        )
    end
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
