defmodule ApiaryWeb.Contract.DiagnosticsController do
  @moduledoc """
  A run's diagnostics for a diagnostics key: a signed `GET /v1/runs/<run id>/diagnostics`,
  where the run id is the `rn_` id on the Details of the run's page. A run's number is
  unique only in its workspace, and the key reads every workspace, so a number finds no
  run. The request is reached only
  through `ApiaryWeb.Contract.SignedRequest` with `kinds: [:diagnostics]`, which verifies
  it under a diagnostics key alone, refuses it as any signed GET is refused (`401` for a
  key the instance does not hold, has revoked or that is of another kind, a bad
  signature or a stale timestamp; `400` for an instance id outside its form or a contract
  version not served), records the key's use, and signs the answer.

  The key reads every run of the instance (`run.read_diagnostics`, `Apiary.Access`). The
  answer is `200`, `application/json`, the run's diagnostics document
  (`Apiary.Runs.Diagnostics`), with its log and its machine logs; a run id outside the
  `rn_` form, a run's number among them, or of no run is `404` `not_found`, and a document
  that cannot be built is
  `503` `unavailable`. Nothing of the run, the key or the document is logged.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.{Access, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Runs.{Diagnostics, Run}

  def show(conn, %{"run_id" => run_id}) do
    scope = Scope.for_access_key(conn.assigns.access_key)

    with true <- Run.public_id?(run_id),
         %Run{} = run <- Repo.get_by(Run, public_id: run_id),
         :ok <- Access.check(scope, :"run.read_diagnostics", run) do
      body = Diagnostics.encode(run, scope)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      _none -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  rescue
    exception ->
      # The class alone: the message can carry the run's data.
      Logger.error("run diagnostics not built: #{inspect(exception.__struct__)}")
      conn |> put_status(503) |> json(%{error: "unavailable"})
  end
end
