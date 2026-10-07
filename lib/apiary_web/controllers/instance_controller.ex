defmodule ApiaryWeb.InstanceController do
  @moduledoc """
  `/instance`, the Instance level itself, which has no page of its own: sent on to the
  first of its sections the person may open (`ApiaryWeb.Layouts.instance_sections/1`),
  where the account menu's Instance and the breadcrumb's lead, and answered as a path
  that does not exist (`ApiaryWeb.NotFound`) for whoever may open none. Not a page: a
  redirect.

      GET /instance

  The sections are read in the scope the Instance's pages have: the person's, with the
  workspace they opened last (`ApiaryWeb.UserAuth`'s `:load_organisation`).
  """
  use ApiaryWeb, :controller

  alias Apiary.Organisations
  alias ApiaryWeb.Nav.Entry

  def show(conn, _params) do
    # The session's key for the workspace opened last, as `ApiaryWeb.UserAuth` writes it.
    scope =
      Organisations.load_home_scope(
        conn.assigns.current_scope,
        get_session(conn, :last_workspace_id)
      )

    case ApiaryWeb.Layouts.instance_sections(scope) do
      [first | _] -> redirect(conn, to: Entry.path(first, scope.organisation, scope.workspace))
      [] -> raise ApiaryWeb.NotFound
    end
  end
end
