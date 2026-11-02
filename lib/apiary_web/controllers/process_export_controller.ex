defmodule ApiaryWeb.ProcessExportController do
  # A workspace's process as a `process.yaml` (`Apiary.Processes.export/1`), for Export
  # process.yaml on the Stages page. Not a page.
  #
  #     GET /:org/:workspace/settings/stages/process.yaml
  #
  # Scoped like the run log (`ApiaryWeb.RunLogController`): the pipeline resolves the
  # organisation and the workspace of the path for a member and answers `404` for anybody
  # else. Reading the file is `process.edit` (`Apiary.Access`), because it has the custom
  # types' JSON Schemas, which only owners and admins open; a reader it refuses is `404`
  # too. A request with no session is sent to sign in, as every page of a workspace.
  #
  # The feature `workflow_model` needs `factory`, so its gate covers both: with either off
  # or hidden, the route is not found.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :workflow_model

  alias Apiary.{Access, Processes}

  def show(conn, _params) do
    with {:ok, scope} <- scope(conn),
         # The pipeline loaded the scope from the database for this request, as fresh as
         # `authorize/3` would read it: `can?/3` asks it without a second read.
         true <- Access.can?(scope, :"process.edit", scope.workspace) do
      conn
      |> put_resp_content_type("application/yaml", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="process.yaml"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, Processes.export(scope.workspace))
    else
      _refused ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, gettext("not found"))
    end
  end

  # The pipeline's `fetch_path_scope/2` has resolved the path's organisation and
  # workspace.
  defp scope(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{}, organisation: %{}, workspace: %{}} = scope -> {:ok, scope}
      _none -> :error
    end
  end
end
