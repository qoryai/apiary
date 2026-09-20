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
    <Layouts.auth flash={@flash} current_scope={@current_scope} width="max-w-md">
      <%= cond do %>
        <% is_nil(@invitation) -> %>
          <div class="text-center">
            <div class="mx-auto flex size-12 items-center justify-center rounded-full bg-surface-2 text-ink-faint">
              <.icon name="hero-envelope-open" class="size-6" />
            </div>
            <h1 class="mt-4 text-lg font-semibold tracking-tight text-ink">
              This invitation is no longer valid
            </h1>
            <p class="mt-2 text-sm text-ink-muted">
              It may have been accepted already, revoked, or it expired after seven days. Ask
              the person who invited you to send a new one.
            </p>
            <div class="mt-6 flex justify-center gap-2">
              <.button :if={@current_scope} variant="primary" navigate={~p"/hive"}>
                Go to your hive
              </.button>
              <.button :if={!@current_scope} variant="primary" navigate={~p"/users/log-in"}>
                Log in
              </.button>
            </div>
          </div>
        <% @current_scope -> %>
          <div class="text-center">
            <.invitation_summary invitation={@invitation} />
            <p class="mt-4 text-sm text-ink-muted">
              You are signed in as <span class="font-medium text-ink">{@current_scope.user.email}</span>.
            </p>
            <div class="mt-6 flex flex-col gap-2">
              <.button
                variant="primary"
                phx-click="accept"
                phx-disable-with="Joining..."
                class="w-full"
              >
                Accept invitation
              </.button>
              <.button href={~p"/users/log-out"} method="delete" variant="ghost" class="w-full">
                Not you? Log out
              </.button>
            </div>
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
          </div>
        <% true -> %>
          <div class="text-center">
            <.invitation_summary invitation={@invitation} />
            <p class="mt-4 text-sm text-ink-muted">
              Create an account with <span class="font-medium text-ink">{@invitation.email}</span>
              to join, or log in if you already have one.
            </p>
            <div class="mt-6 flex flex-col gap-2">
              <.button
                variant="primary"
                navigate={~p"/users/register?invitation=#{@token}"}
                class="w-full"
              >
                Create an account
              </.button>
              <.button href={~p"/invitations/#{@token}/continue"} class="w-full">
                Log in
              </.button>
            </div>
          </div>
      <% end %>
    </Layouts.auth>
    """
  end

  attr :invitation, :map, required: true

  defp invitation_summary(assigns) do
    ~H"""
    <div class="mx-auto flex size-12 items-center justify-center rounded-full bg-accent-soft text-accent-soft-ink">
      <.icon name="hero-envelope-open" class="size-6" />
    </div>
    <h1 class="mt-4 text-lg font-semibold tracking-tight text-ink">
      You are invited to join {@invitation.hive.name}
    </h1>
    <p class="mt-2 text-sm text-ink-muted">
      The <span class="font-medium text-ink">{@invitation.hive.name}</span>
      <.term word="hive" /> of the
      <span class="font-medium text-ink">{@invitation.organisation.name}</span>
      <.term word="apiary" />, as {level_word(@invitation.level)}.
    </p>
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
