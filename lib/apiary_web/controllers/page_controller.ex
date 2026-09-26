defmodule ApiaryWeb.PageController do
  use ApiaryWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/workspace")
    else
      render(conn, :home, page_title: gettext("Welcome"))
    end
  end
end
