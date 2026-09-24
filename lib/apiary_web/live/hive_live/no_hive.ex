defmodule ApiaryWeb.HiveLive.NoHive do
  @moduledoc """
  Shown to a signed-in user who is not a member of any organisation.
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
              "An organisation is created when you register, and you join someone else's through an invitation. Ask an owner to invite %{email}; the email they send brings you straight to their hive.",
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
    if socket.assigns.current_scope.organisation do
      {:ok, push_navigate(socket, to: ~p"/hive")}
    else
      {:ok, assign(socket, page_title: gettext("No hive yet"))}
    end
  end
end
