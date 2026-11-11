defmodule ApiaryWeb.Contract.ModelKeysController do
  @moduledoc """
  A gateway's report of the states of a run's model keys: a signed
  `POST /v1/runs/<run_id>/model-keys` whose body is the report (`Apiary.ModelKeys.Report`),
  under a key of the gateway that attached the run. Reached only through
  `ApiaryWeb.Contract.SignedRequest`, as the outcome is, under the run endpoint's bucket of
  the key's rate limit, which verifies the request, refuses what the contract refuses
  before the endpoint does, and signs the answer. The body is read raw, up to 32 KiB
  (`ApiaryWeb.Contract.RawBody`); a longer one is `413`.

  Then, in order: a body the contract refuses is `400` `invalid_request`, with the member
  that refused it in `names`; a `time` more than 300 seconds from the server's clock is
  `401`, unsigned, as an outcome's is; where model keys do not apply (the `factory` and
  `secrets` features), and for a run the key's gateway does not hold, `404`; for a run
  that has ended, `410` with no body, as the secrets request answers a run that is not
  live.

  The answer is `200`, `application/json`, `{"version":1,"keys":[…]}`: the newest state of
  each key of the run and window, from every gateway, under the run's credential names,
  with `X-Qory-Configuration`. When the report cannot be stored, the answer is `503`.
  Errors are short JSON and never repeat anything sent; the body, the signature and the
  headers are never logged.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.ModelKeys.Report
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  def create(conn, %{"run_id" => run_id}) do
    now = DateTime.from_unix!(SignedRequest.now())

    with {:ok, report} <- Report.parse(conn.assigns.raw_body, run_id, now),
         :ok <- fresh(report, now),
         {:ok, body} <-
           Report.answer(
             conn.assigns.access_key,
             run_id,
             report,
             conn.assigns.instance_id,
             DateTime.utc_now()
           ) do
      conn
      |> put_resp_header("x-qory-configuration", Configuration.digest(conn.assigns.access_key))
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      {:error, :invalid_request, name} ->
        conn |> put_status(400) |> json(%{error: "invalid_request", names: [name]})

      :unauthorized ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :gone} ->
        send_resp(conn, 410, "")

      {:error, _reason} ->
        unavailable(conn)
    end
  rescue
    exception ->
      Logger.error("a model keys report could not be taken: #{inspect(exception.__struct__)}")
      unavailable(conn)
  end

  defp unavailable(conn), do: conn |> put_status(503) |> json(%{error: "unavailable"})

  # The report's `time`, held to the window an outcome's is held to, by the same clock.
  defp fresh(report, now), do: if(Report.fresh?(report, now), do: :ok, else: :unauthorized)
end
