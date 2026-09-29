defmodule ApiaryWeb.MovedController do
  @moduledoc """
  The paths of pages that moved under the settings (`ApiaryWeb.SettingsComponents`), sent
  on to where the page is now, with whatever followed the moved part and the query: an
  organisation's members, `/:org/members/…`, are its people, `/:org/settings/people/…`,
  and a workspace's access keys, `/:org/:workspace/keys/…`, are
  `/:org/:workspace/settings/keys/…`. A bookmark, a link in an old message and a page of a
  browser's history still land; the router answers the new paths only.
  """
  use ApiaryWeb, :controller

  def show(conn, _params) do
    segments =
      case conn.path_info do
        [organisation, "members" | rest] ->
          [organisation, "settings", "people" | rest]

        [organisation, workspace, "keys" | rest] ->
          [organisation, workspace, "settings", "keys" | rest]
      end

    path =
      "/" <>
        Enum.map_join(segments, "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end)

    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    redirect(conn, to: path <> query)
  end
end
