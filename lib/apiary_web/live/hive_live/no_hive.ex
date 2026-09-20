defmodule ApiaryWeb.HiveLive.NoHive do
  @moduledoc """
  Shown to a signed-in user who is not a member of any organisation.
  """
  use ApiaryWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} memberships={@memberships}>
      <.empty_state icon="hero-envelope-open" title="You are not part of an apiary yet" class="py-16">
        <p>
          An <.term word="apiary" /> is created when you register, and you join someone else's
          <.term word="apiary" />
          through an invitation. Ask an owner to invite <span class="font-medium text-ink">{@current_scope.user.email}</span>;
          the email they send brings you straight to their <.term word="hive" />.
        </p>
        <:actions>
          <.button href={~p"/users/settings"}>Account settings</.button>
          <.button href={~p"/users/log-out"} method="delete" variant="ghost">Log out</.button>
        </:actions>
      </.empty_state>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope.organisation do
      {:ok, push_navigate(socket, to: ~p"/hive")}
    else
      {:ok, assign(socket, page_title: "No hive yet")}
    end
  end
end
