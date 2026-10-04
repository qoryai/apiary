defmodule ApiaryWeb.MovedController do
  @moduledoc """
  The paths of pages that moved, sent on to where the page is now, with whatever followed
  the moved part and the query. Pages that moved under the settings
  (`ApiaryWeb.SettingsComponents`): an organisation's members, `/:org/members/…`, are its
  people, `/:org/settings/people/…`, and a workspace's access keys,
  `/:org/:workspace/keys/…`, are `/:org/:workspace/settings/keys/…`. An organisation's
  Activity, `/:org/activity`, is its Audit log, `/:org/audit-log`. A section
  of the settings that took a new name: a workspace's Retention,
  `/:org/:workspace/settings/retention`, is its Runs, `/:org/:workspace/settings/runs`.
  Those answer 302, found. A page that took a new name, for good: the workspace's
  connections, `/:org/:workspace/connections`, are its Network access,
  `/:org/:workspace/network`, and a run's Connections tab, `/runs/:run_id/connections`, is
  `/runs/:run_id/network`; those answer 301, moved permanently. A bookmark, a link in an
  old message and a page of a browser's history still land; the router answers the new
  paths only.
  """
  use ApiaryWeb, :controller

  def show(conn, _params) do
    {status, segments} =
      case conn.path_info do
        [organisation, "activity"] ->
          {:found, [organisation, "audit-log"]}

        [organisation, "members" | rest] ->
          {:found, [organisation, "settings", "people" | rest]}

        [organisation, workspace, "keys" | rest] ->
          {:found, [organisation, workspace, "settings", "keys" | rest]}

        [organisation, workspace, "settings", "retention"] ->
          {:found, [organisation, workspace, "settings", "runs"]}

        [organisation, workspace, "connections"] ->
          {:moved_permanently, [organisation, workspace, "network"]}

        [organisation, workspace, "runs", run_id, "connections"] ->
          {:moved_permanently, [organisation, workspace, "runs", run_id, "network"]}
      end

    path =
      "/" <>
        Enum.map_join(segments, "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end)

    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    conn
    |> put_status(status)
    |> redirect(to: path <> query)
  end
end
