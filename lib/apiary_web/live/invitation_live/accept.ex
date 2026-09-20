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
            This invitation is no longer valid
            <:subtitle>
              It may have been accepted already, revoked, or it expired after seven days. Ask
              the person who invited you to send a new one.
            </:subtitle>
          </Layouts.auth_heading>
          <.button
            :if={@current_scope}
            variant="primary"
            size="md"
            class="btn-block"
            navigate={~p"/hive"}
          >
            Go to your hive
          </.button>
          <.button
            :if={!@current_scope}
            variant="primary"
            size="md"
            class="btn-block"
            navigate={~p"/users/log-in"}
          >
            Log in
          </.button>
        <% @current_scope -> %>
          <.invitation_summary invitation={@invitation} />
          <div class="flex items-center gap-2.5 rounded-field border border-line px-3 py-2.5">
            <.avatar name={@current_scope.user.email} kind="self" />
            <p class="min-w-0 truncate text-[13px]/[18px] text-muted">
              Signed in as
              <span class="font-medium text-base-content">{@current_scope.user.email}</span>
            </p>
          </div>
          <.button
            variant="primary"
            size="md"
            class="btn-block"
            phx-click="accept"
            loading_text="Joining"
          >
            Accept invitation
          </.button>
          <p class="text-center text-[13px]/[18px] text-muted">
            <.button variant="link" href={~p"/users/log-out"} method="delete">
              Not you? Log out
            </.button>
          </p>
          <.form
            for={%{}}
            id="switch-form"
            action={~p"/organisations/switch"}
            method="post"
            phx-trigger-action={@trigger_submit}
            class="hidden"
          >
            <input type="hidden" name="organisation_id" value={@organisation_id} />
          </.form>
        <% true -> %>
          <.invitation_summary invitation={@invitation} />
          <p class="text-sm/5 text-muted">
            Create an account with
            <strong class="font-medium text-base-content">{@invitation.email}</strong>
            to join, or log in if you already have one.
          </p>
          <div class="grid gap-2">
            <.button
              variant="primary"
              size="md"
              class="btn-block"
              navigate={~p"/users/register?invitation=#{@token}"}
            >
              Create an account
            </.button>
            <.button size="md" class="btn-block" href={~p"/invitations/#{@token}/continue"}>
              Log in
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
      Join {@invitation.hive.name}
      <:subtitle>
        You are invited to the
        <strong class="font-medium text-base-content">{@invitation.hive.name}</strong>
        <.term word="hive" /> of the
        <strong class="font-medium text-base-content">{@invitation.organisation.name}</strong>
        <.term word="apiary" />, as {level_word(@invitation.level)}.
      </:subtitle>
    </Layouts.auth_heading>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Invitation",
       token: token,
       invitation: Organisations.get_invitation_by_token(token),
       trigger_submit: false,
       organisation_id: nil
     )}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    %{current_scope: scope, token: token, invitation: invitation} = socket.assigns

    case Organisations.accept_invitation(scope.user, token) do
      {:ok, membership} ->
        {:noreply,
         assign(socket, organisation_id: membership.organisation_id, trigger_submit: true)}

      {:error, :already_member} ->
        {:noreply,
         socket
         |> put_flash(:info, "You are already a member of #{invitation.organisation.name}.")
         |> assign(organisation_id: invitation.organisation_id, trigger_submit: true)}

      {:error, :invalid} ->
        {:noreply, assign(socket, :invitation, nil)}
    end
  end

  defp level_word(:owner), do: "an owner"
  defp level_word(_level), do: "a member"
end
