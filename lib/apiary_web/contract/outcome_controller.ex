defmodule ApiaryWeb.Contract.OutcomeController do
  @moduledoc """
  A run's outcome, as its starter gives it: a signed `POST /v1/runs/<run_id>/outcome`
  whose body is the outcome (`Apiary.Runs.Outcome`), under any active key of the node or
  node pool the run is bound to. Reached only through `ApiaryWeb.Contract.SignedRequest`,
  as the run endpoint is, under the run endpoint's bucket of the key's rate limit,
  which verifies the request, refuses what the contract refuses before the endpoint does
  (a content type other than `application/json`, a header sent twice, a request that does
  not verify, the key's rate, an instance id, a contract revision not served) and signs
  the answer. A key whose organisation is suspended verifies under no key, and is refused
  there. The body is read raw, up to 4 KiB (`ApiaryWeb.Contract.RawBody`).

  Then, in order: a body the contract refuses is `400` `invalid_request`, with the member
  that refused it in `names`; a `time` more than 300 seconds from the server's clock is
  `401`, unsigned, as a registration's is; then `Apiary.Runs.Outcome.give/4`: a key
  `Apiary.Access` does not let post (`run.post_events`) is `404`; the same outcome again,
  the same state and reason whatever its bytes, under any active key of the run's node is
  given the same answer; a run the key's workspace does not hold, a run of another node,
  and a run whose events retention has pruned are `404`; a run that was given another
  outcome, another state or reason, is `409` `outcome_given`; else the outcome is stored,
  and the run's state is the outcome's.

  The answer is `200`, `application/json`, `{"version":1}`, with `X-Qory-Configuration`.
  When the outcome cannot be stored, the answer is `503`. Errors are short JSON and never
  repeat anything sent; the body, the signature and the headers are never logged.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.Runs.Outcome
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  @answer ~s({"version":1})

  def create(conn, %{"run_id" => run_id}) do
    with {:ok, outcome} <- parse(conn.assigns.raw_body),
         :ok <- fresh(outcome),
         {:ok, _given} <-
           Outcome.give(conn.assigns.access_key, run_id, outcome, conn.assigns.raw_body) do
      conn
      |> put_resp_header("x-qory-configuration", Configuration.digest(conn.assigns.access_key))
      |> put_resp_content_type("application/json")
      |> send_resp(200, @answer)
    else
      {:error, :invalid_request, name} ->
        conn |> put_status(400) |> json(%{error: "invalid_request", names: [name]})

      :unauthorized ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :outcome_given} ->
        conn |> put_status(409) |> json(%{error: "outcome_given"})

      {:error, _reason} ->
        unavailable(conn)
    end
  rescue
    exception ->
      Logger.error("an outcome could not be stored: #{inspect(exception.__struct__)}")
      unavailable(conn)
  end

  defp unavailable(conn), do: conn |> put_status(503) |> json(%{error: "unavailable"})

  defp parse(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, body} -> Outcome.parse(body)
      {:error, _reason} -> {:error, :invalid_request, "body"}
    end
  end

  # The outcome's `time`, held to the window a registration's is held to, by the same
  # clock.
  defp fresh(outcome) do
    now = DateTime.from_unix!(SignedRequest.now())
    if Outcome.fresh?(outcome, now), do: :ok, else: :unauthorized
  end
end
