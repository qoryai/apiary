defmodule ApiaryWeb.InstanceController do
  @moduledoc """
  `/instance`, the Instance level itself, which has no page of its own: sent on to the
  first of its sections the person may open (`ApiaryWeb.Layouts.instance_sections/1`),
  where the Qory Apiary menu's Instance settings and the breadcrumb's lead, and answered
  as a path that does not exist (`ApiaryWeb.NotFound`) for whoever may open none. Not a
  page: a redirect.

      GET /instance

  The sections are read in the scope the Instance's pages have: the person's, with the
  workspace they opened last (`ApiaryWeb.UserAuth.home_scope/1`).
  """
  use ApiaryWeb, :controller

  alias ApiaryWeb.Nav.Entry

  def show(conn, _params) do
    scope = ApiaryWeb.UserAuth.home_scope(conn)

    case ApiaryWeb.Layouts.instance_sections(scope) do
      [first | _] -> redirect(conn, to: Entry.path(first, scope.organisation, scope.workspace))
      [] -> raise ApiaryWeb.NotFound
    end
  end
end
