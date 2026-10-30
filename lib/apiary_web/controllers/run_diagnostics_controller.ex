defmodule ApiaryWeb.RunDiagnosticsController do
  @moduledoc """
  A run's diagnostics document (`Apiary.Runs.Diagnostics`), as the run page's Copy
  diagnostics copies it. Not a page.

      GET /:org/:workspace/runs/:run_id/diagnostics

  Scoped like the page: the pipeline resolves the organisation and workspace of the path
  for a member and answers `404` for anybody else, the run is looked up in that
  workspace, and a run of another workspace is `404`, like one that does not exist. The
  reader is anyone who reads the run (`run.read`); the document is built for them: the
  log only for a reader who may read it (`run.read_log`), the machine logs only for an
  instance admin. The answer is `application/json`, never cached and never sniffed.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  alias Apiary.Access
  alias Apiary.Runs.{Diagnostics, Record}

  def show(conn, %{"run_id" => run_id}) do
    with %{user: %{}, organisation: %{}, workspace: %{}} = scope <-
           conn.assigns[:current_scope] || :error,
         {:ok, run} <- Record.fetch_run(scope, run_id),
         true <- Access.can?(scope, :"run.read", run) || :error do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, Diagnostics.encode(run, scope))
    else
      _not_found ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, gettext("not found"))
    end
  end
end
