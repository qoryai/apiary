defmodule ApiaryWeb.Contract.AttachController do
  @moduledoc """
  A run's attach, as the gateway its run key names gives it: a signed
  `POST /v1/runs/<run_id>/attach` whose body is the attach (`Apiary.Runs.Attach`), under
  the gateway's access key. Reached only through `ApiaryWeb.Contract.SignedRequest`,
  as the run endpoint is, under the run endpoint's bucket of the key's rate limit,
  which verifies the request, refuses what the contract refuses before the endpoint does
  (a content type other than `application/json`, a header sent twice, a request that does
  not verify, the key's rate, an instance id, a contract revision not served) and signs
  the answer. A key whose organisation is out of use verifies under no key, and is
  refused there. The body is read raw, up to 64 KiB (`ApiaryWeb.Contract.RawBody`).

  Then, in order: a body the contract refuses is `400` `invalid_request`, with the member
  that refused it in `names`; a `time` more than 300 seconds from the server's clock is
  `401`, unsigned, as a registration's is; then `Apiary.Runs.Attach.attach/4`: a key that
  is not a gateway's is `409` `not_a_gateway`; a run key that does not verify, or whose
  run id is not the path's, is `400` `run_key_invalid`; a run whose workspace or
  organisation is out of use is `401`, unsigned, as a key of it would be; a workspace
  `Apiary.Access` does not let post (`run.post_events`) is `404`; the same gateway node
  and the same instance id (`X-Qory-Instance-Id`), under any of the node's active keys,
  attaching the same live run again is given the same answer; a run that has ended is
  `410`, with no body; then `409` `run_key_expired`, `wrong_gateway`,
  `workspace_not_served` and `run_attached`, which another gateway node, or another
  instance of this one, is given for a live run it did not attach; else the run is
  attached, and its instance id kept with it.

  The answer is `200`, `application/json`, the run configuration's bytes with the
  registration's `labels` and `about` after them, with `X-Qory-Run-Configuration:
  sha256=<hex>`, the configuration's digest, the same string quoted as the `ETag`, and
  `X-Qory-Configuration`. When the run cannot be attached or its configuration cannot be
  read, the answer is `503`. Errors are short JSON and never repeat anything sent; the
  body, the signature and the headers are never logged.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.Runs.Attach
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  # The attach's signed 409s, each its own code, in the contract's order.
  @conflicts [
    :not_a_gateway,
    :run_key_expired,
    :wrong_gateway,
    :workspace_not_served,
    :run_attached
  ]

  def create(conn, %{"run_id" => run_id}) do
    access_key = conn.assigns.access_key

    with {:ok, attach} <- parse(conn.assigns.raw_body),
         :ok <- fresh(attach),
         {:ok, answer} <- Attach.attach(access_key, run_id, attach, meta(conn)) do
      conn
      |> put_resp_header("x-qory-run-configuration", answer.digest)
      |> put_resp_header("etag", answer.etag)
      |> put_resp_header("x-qory-configuration", Configuration.digest(access_key))
      |> put_resp_content_type("application/json")
      |> send_resp(200, answer.settings)
    else
      {:error, :invalid_request, name} ->
        conn |> put_status(400) |> json(%{error: "invalid_request", names: [name]})

      {:error, :run_key_invalid} ->
        conn |> put_status(400) |> json(%{error: "run_key_invalid"})

      {:error, code} when code in @conflicts ->
        conn |> put_status(409) |> json(%{error: Atom.to_string(code)})

      unauthorized when unauthorized in [:unauthorized, {:error, :unauthorized}] ->
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
      Logger.error("an attach could not be stored: #{inspect(exception.__struct__)}")
      unavailable(conn)
  end

  defp unavailable(conn), do: conn |> put_status(503) |> json(%{error: "unavailable"})

  defp parse(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, body} -> Attach.parse(body)
      {:error, _reason} -> {:error, :invalid_request, "body"}
    end
  end

  # The attach's `time`, held to the window a registration's is held to, by the same clock.
  defp fresh(attach) do
    now = DateTime.from_unix!(SignedRequest.now())
    if Attach.fresh?(attach, now), do: :ok, else: :unauthorized
  end

  defp meta(conn),
    do: %{
      forager_version: SignedRequest.forager_version(conn),
      instance_id: conn.assigns.instance_id
    }
end
