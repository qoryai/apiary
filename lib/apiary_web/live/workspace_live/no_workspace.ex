defmodule ApiaryWeb.WorkspaceLive.NoWorkspace do
  @moduledoc """
  A user's organisations, `/users/organisations`: for now the page of a signed-in user who
  is not a member of any organisation, where `/` and the log-in send them. A user who is
  a member is sent on to their workspace; a list of the user's organisations is not
  built yet, and the sidebar's switcher links to each of them.
  """
  use ApiaryWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} memberships={@memberships}>
      <.empty_state
        icon="hero-envelope-open"
        title={gettext("You are not part of an organisation yet")}
        heading="h1"
        class="mx-auto mt-6 w-full max-w-[480px] md:mt-16"
      >
        <p>
          <.rich text={
            rich_gettext(
              "An organisation is created when you register, and you join someone else's through an invitation. Ask an owner to invite %{email}; the email they send brings you straight to their workspace.",
              email: email(@current_scope.user.email)
            )
          } />
        </p>
        <:actions>
          <.button href={~p"/users/settings"}>{gettext("Account settings")}</.button>
          <.button href={~p"/users/log-out"} method="delete" variant="ghost">
            {gettext("Log out")}
          </.button>
        </:actions>
      </.empty_state>
    </Layouts.app>
    """
  end

  defp email(email) do
    assigns = %{email: email}

    ~H"""
    <strong class="font-medium text-base-content">{@email}</strong>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_scope do
      %{organisation: %{} = organisation, workspace: %{} = workspace} ->
        {:ok, push_navigate(socket, to: ~p"/#{organisation}/#{workspace}")}

      _no_membership ->
        {:ok, assign(socket, page_title: gettext("No workspace yet"))}
    end
  end
end
