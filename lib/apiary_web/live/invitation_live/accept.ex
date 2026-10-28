defmodule ApiaryWeb.InvitationLive.Accept do
  @moduledoc """
  The landing of an invitation link: accept when signed in, otherwise register
  or log in first. An invalid or expired token gets a friendly page. Signed out, the
  page is the set-up's first step, Invitation, where the invitation has no workspace
  (`ApiaryWeb.SetUpComponents.steps_for/3`): its progress indicator lists the account and
  the organisation's first workspace after it.
  """
  use ApiaryWeb, :live_view

  alias Apiary.Organisations
  alias ApiaryWeb.SetUpComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.set_up flash={@flash} current_scope={@current_scope}>
      <%= cond do %>
        <% is_nil(@invitation) -> %>
          <SetUpComponents.frame>
            <.hex_tile icon="hero-envelope-open" tone="neutral" />
            <SetUpComponents.heading>
              {gettext("This invitation is no longer valid")}
              <:subtitle>
                {gettext(
                  "It may have been accepted already, revoked, or it expired after seven days. Ask the person who invited you to send a new one."
                )}
              </:subtitle>
            </SetUpComponents.heading>
            <.button
              :if={@current_scope}
              variant="primary"
              size="md"
              class="btn-block"
              href={~p"/"}
            >
              {gettext("Go to your workspace")}
            </.button>
            <.button
              :if={!@current_scope}
              variant="primary"
              size="md"
              class="btn-block"
              navigate={~p"/users/log-in"}
            >
              {gettext("Log in")}
            </.button>
          </SetUpComponents.frame>
        <% @current_scope -> %>
          <SetUpComponents.frame>
            <.invitation_summary invitation={@invitation} />
            <div class="flex items-center gap-2.5 rounded-field border border-line px-3 py-2.5">
              <.avatar name={@current_scope.user.email} kind="self" />
              <p
                class="min-w-0 truncate text-[13px]/[18px] text-muted"
                title={@current_scope.user.email}
              >
                <.rich text={
                  rich_gettext("Signed in as %{email}",
                    email: {:b, @current_scope.user.email, "font-medium text-base-content"}
                  )
                } />
              </p>
            </div>
            <.button
              variant="primary"
              size="md"
              class="btn-block"
              phx-click="accept"
              loading_text={gettext("Joining")}
            >
              {gettext("Accept invitation")}
            </.button>
            <p class="text-center text-[13px]/[18px] text-muted">
              <.button variant="link" href={~p"/users/log-out"} method="delete">
                {gettext("Not you? Log out")}
              </.button>
            </p>
          </SetUpComponents.frame>
        <% true -> %>
          <SetUpComponents.frame steps={@steps}>
            <.invitation_summary invitation={@invitation} />
            <p id="invitation-email" class="text-sm/5 text-muted">
              <.rich text={
                rich_gettext("The invitation is for %{email}.",
                  email: {:b, @invitation.email, "font-medium text-base-content"}
                )
              } />
            </p>
            <div class="grid gap-2">
              <.button
                variant="primary"
                size="md"
                class="btn-block"
                navigate={~p"/users/register?invitation=#{@token}"}
              >
                {gettext("Create an account")}
              </.button>
              <.button size="md" class="btn-block" href={~p"/invitations/#{@token}/continue"}>
                {gettext("Log in")}
              </.button>
            </div>
            <:context :if={workspace_to_come?(@steps)}>
              <p id="invitation-context">
                {gettext(
                  "The invitation adds you to %{organisation}. %{organisation} has no workspace yet: its first one is set up after your account.",
                  organisation: @invitation.organisation.name
                )}
              </p>
            </:context>
          </SetUpComponents.frame>
      <% end %>
    </Layouts.set_up>
    """
  end

  # Whether the steps after the invitation include the organisation's first workspace,
  # its Name.
  defp workspace_to_come?(steps), do: Enum.any?(steps, &(&1.id == :name))

  attr :invitation, :map, required: true

  defp invitation_summary(assigns) do
    ~H"""
    <SetUpComponents.heading>
      {gettext("Join %{name}", name: (@invitation.workspace || @invitation.organisation).name)}
      <:subtitle><.rich text={invitation_sentence(@invitation)} /></:subtitle>
    </SetUpComponents.heading>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    # Counted before the token is looked up (`ApiaryWeb.AttemptLimits`).
    case ApiaryWeb.AttemptLimits.link_page_mount(socket) do
      {:ok, socket} ->
        invitation = Organisations.get_invitation_by_token(token)

        {:ok,
         assign(socket,
           page_title: gettext("Invitation"),
           token: token,
           invitation: invitation,
           steps:
             invitation &&
               SetUpComponents.steps_for(nil, :invitation, invitation: invitation, token: token)
         )}

      {:limited, socket} ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("accept", _params, socket) do
    %{current_scope: scope, token: token, invitation: invitation} = socket.assigns

    case Organisations.accept_invitation(scope, token) do
      {:ok, _membership} ->
        {:noreply, redirect(socket, to: workspace_path(invitation))}

      {:error, :already_member} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("You are already a member of %{name}.", name: invitation.organisation.name)
         )
         |> redirect(to: ~p"/#{invitation.organisation}")}

      {:error, :invalid} ->
        {:noreply, assign(socket, :invitation, nil)}
    end
  end

  # The workspace the invitation brings the user into: the workspace's page, which the
  # path names, loaded afresh so the session remembers it for `/`. An invitation without
  # a workspace brings them into the organisation: its workspace set-up while it has no
  # workspace in use, else its overview, as `ApiaryWeb.UserAuth.signed_in_path/1` sends
  # a person of an organisation they reach no workspace of yet.
  defp workspace_path(%{organisation: organisation, workspace: nil}) do
    if Organisations.has_workspace?(organisation),
      do: ~p"/#{organisation}",
      else: ~p"/#{organisation}/set-up"
  end

  defp workspace_path(%{organisation: organisation, workspace: workspace}),
    do: ~p"/#{organisation}/#{workspace}"

  # An invitation makes a member, whatever its sender may be.
  defp invitation_sentence(%{workspace: nil} = invitation) do
    rich_gettext(
      "You are invited to the %{organisation} organisation, as a member.",
      organisation: {:b, invitation.organisation.name, "font-medium text-base-content"}
    )
  end

  defp invitation_sentence(invitation) do
    rich_gettext(
      "You are invited to the %{workspace} workspace of the %{organisation} organisation, as a member.",
      workspace: {:b, invitation.workspace.name, "font-medium text-base-content"},
      organisation: {:b, invitation.organisation.name, "font-medium text-base-content"}
    )
  end
end
