defmodule ApiaryWeb.Contract.RunListController do
  @moduledoc """
  The run list for a diagnostics key: a signed `GET /v1/runs`, the runs of every workspace
  of the instance, one page at a time, for `qory apiary`. The request is reached only
  through `ApiaryWeb.Contract.SignedRequest` with `kinds: [:diagnostics]`, as
  `GET /v1/runs/<run id>/diagnostics` is (`ApiaryWeb.Contract.DiagnosticsController`), so
  it is verified, refused and signed as that request is: `401` for a key the instance
  does not hold, has revoked or that is of another kind, a bad signature or a stale
  timestamp; `400` for a signing header sent twice, an instance id outside its form or a
  contract version not served. The query is read only after that check.

  The key reads every run of the instance (`run.list_instance`, `Apiary.Access`); a key
  that may not is `401`. The answer is `200`, `application/json`, the contract's run list
  (`Apiary.Runs.list_instance_runs/2`); a query parameter that breaks its rule is `400`
  `{"error":"invalid_request","parameter":<name>}`; a page that cannot be read is `503`
  `unavailable`. Nothing of the runs, the key or the query is logged, and no read of a run
  is recorded.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.{Access, Runs}
  alias Apiary.Accounts.Scope
  alias Apiary.Runs.Run

  def index(conn, _params) do
    scope = Scope.for_access_key(conn.assigns.access_key)

    with {:access, :ok} <- {:access, Access.check(scope, :"run.list_instance", %Run{})},
         {:ok, document} <- Runs.list_instance_runs(conn.query_string) do
      json(conn, document)
    else
      {:error, parameter} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_request", parameter: parameter})

      {:access, {:error, _refused}} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  rescue
    exception ->
      # The class alone: the message can contain the runs' data or the query.
      Logger.error("run list not built: #{inspect(exception.__struct__)}")
      conn |> put_status(503) |> json(%{error: "unavailable"})
  end
end
