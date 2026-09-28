defmodule ApiaryWeb.PageController do
  use ApiaryWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ApiaryWeb.UserAuth.signed_in_path(conn))
    else
      render(conn, :home,
        page_title: gettext("Welcome"),
        # Sign-up without an invitation, where the instance offers it.
        sign_up?: Apiary.Organisations.sign_up_offered?()
      )
    end
  end
end
