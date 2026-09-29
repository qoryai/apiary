defmodule ApiaryWeb.TargetLive.Show do
  @moduledoc """
  One target's page: its Overview, Runs, Connections and Policy.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"run.read"}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :page_title, gettext("Targets"))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:targets}
    >
      <.header>{gettext("Targets")}</.header>
    </Layouts.app>
    """
  end
end
