defmodule ApiaryWeb.InvitationLive.Accept do
  @moduledoc """
  The landing of an invitation link: accept when signed in, otherwise register
  or log in first. An invalid or expired token gets a friendly page.
  """
  use ApiaryWeb, :live_view

  alias Apiary.Organisations

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <%= cond do %>
        <% is_nil(@invitation) -> %>
          <.hex_tile icon="hero-envelope-open" tone="neutral" />
          <Layouts.auth_heading>
            {gettext("This invitation is no longer valid")}
            <:subtitle>
              {gettext(
                "It may have been accepted already, revoked, or it expired after seven days. Ask the person who invited you to send a new one."
              )}
            </:subtitle>
          </Layouts.auth_heading>
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
        <% @current_scope -> %>
          <.invitation_summary invitation={@invitation} />
          <div class="flex items-center gap-2.5 rounded-field border border-line px-3 py-2.5">
            <.avatar name={@current_scope.user.email} kind="self" />
            <p class="min-w-0 truncate text-[13px]/[18px] text-muted">
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
        <% true -> %>
          <.invitation_summary invitation={@invitation} />
          <p class="text-sm/5 text-muted">
            <.rich text={
              rich_gettext(
                "Create an account with %{email} to join, or log in if you already have one.",
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
      <% end %>
    </Layouts.auth>
    """
  end

  attr :invitation, :map, required: true

  defp invitation_summary(assigns) do
    ~H"""
    <Layouts.auth_heading>
      {gettext("Join %{name}", name: @invitation.workspace.name)}
      <:subtitle><.rich text={invitation_sentence(@invitation)} /></:subtitle>
    </Layouts.auth_heading>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Invitation"),
       token: token,
       invitation: Organisations.get_invitation_by_token(token)
     )}
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

  # The workspace the invitation brings the user into: its own page, which the path names,
  # loaded afresh so the session remembers it for `/`.
  defp workspace_path(%{organisation: organisation, workspace: workspace}),
    do: ~p"/#{organisation}/#{workspace}"

  # One sentence per level: the article and the word go together.
  defp invitation_sentence(%{level: :owner} = invitation) do
    rich_gettext(
      "You are invited to the %{workspace} workspace of the %{organisation} organisation, as an owner.",
      workspace: {:b, invitation.workspace.name, "font-medium text-base-content"},
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
