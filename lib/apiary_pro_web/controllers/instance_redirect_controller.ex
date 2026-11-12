defmodule ApiaryProWeb.InstanceRedirectController do
  @moduledoc """
  The Instance's former addresses, `/:org/instance` and the paths under it, which lead to
  where the Instance is now, `/instance/…`, with their query
  (`ApiaryProWeb.InstanceLive.Paths.moved/2`). Whether the person may open it is the
  page's to say.
  """
  use ApiaryProWeb, :controller

  alias ApiaryProWeb.InstanceLive.Paths

  def show(conn, _params) do
    # `/:org/instance/…`: the segments after `instance`.
    [_org, "instance" | rest] = conn.path_info

    case Paths.moved(rest, conn.query_string) do
      nil -> raise ApiaryWeb.NotFound
      path -> redirect(conn, to: path)
    end
  end
end
