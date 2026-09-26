defmodule ApiaryWeb.PageController do
  use ApiaryWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ApiaryWeb.UserAuth.signed_in_path(conn))
    else
      render(conn, :home, page_title: gettext("Welcome"))
    end
  end

  @doc """
  `/:org` names no page of its own: it sends the user on to their workspace in the
  organisation, which `ApiaryWeb.UserAuth.fetch_path_scope/2` has loaded.
  """
  def organisation(conn, _params) do
    %{organisation: organisation, workspace: workspace} = conn.assigns.current_scope
    redirect(conn, to: ~p"/#{organisation}/#{workspace}")
  end
end
