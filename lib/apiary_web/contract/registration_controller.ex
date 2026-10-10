defmodule ApiaryWeb.Contract.RegistrationController do
  @moduledoc """
  The run endpoint of the server contract: a run's registration, a signed `POST /v1/runs`
  whose body is the registration (`Apiary.Runs.Registration`), and its reload, a signed
  `GET /v1/runs/<run_id>`. Both are reached only through
  `ApiaryWeb.Contract.SignedRequest`, as discovery is, which verifies the request, refuses
  what the contract refuses before the run endpoint's own (a content type other than
  `application/json` for a registration, the key's rate limit, an instance id, a contract
  revision not served, a GET's stale timestamp) and signs the answer. The key's rate limit
  here is a bucket of its own, apart from the events endpoint's: 50 requests a second and
  100 at once (`config :apiary, ApiaryWeb.Contract.RegistrationController`), so a gateway
  flushing a backlog of events still starts a new run. A registration's body is read raw,
  up to 64 KiB (`ApiaryWeb.Contract.RawBody`).

  **A registration**, in the contract's order: a body the contract refuses is `400`
  `invalid_request`, with the member that refused it in `names`; a `time` more than 300
  seconds from the server's clock is `401`, unsigned, as a GET's stale timestamp is; then
  `Apiary.Runs.Registration.register/3`: a key `Apiary.Access` does not let post
  (`run.post_events`) is `404`, as a path that does not exist; the same bytes again under
  the same key are given the same answer; a run whose events retention has pruned is
  `410`, with no body; an instance beyond its node's limit is `409` `instance_limit`; a
  run id the workspace already holds otherwise is `409` `run_id_used`; else the run is
  stored and answered `200`.

  **A reload** is answered only for a run the same access key registered
  (`Apiary.Runs.Registration.fetch/2`); anything else is `404`, a run its batches created
  among them, and so is a workspace that
  serves no run configuration: a policy removed mid-run never loosens a run already
  started.

  The answer is `200`, `application/json`, the run configuration's bytes, with
  `X-Qory-Run-Configuration: sha256=<hex>`, the same string quoted as the `ETag`, and
  `X-Qory-Configuration`. For a workspace nobody has given a policy, a registration is
  answered the document of no policy, `{"version":1}`, under its digest. Never a `304`:
  `If-None-Match` is not read. When the run cannot be stored or its configuration cannot
  be read, the answer is `503`, which the gateway asks again within the tries it makes as
  a run opens and which, to the last of them, is no run: the gateway fails closed.
  Errors are short JSON and never repeat anything sent; the body, the signature and the
  headers are never logged.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.Runs.Registration
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  def create(conn, _params) do
    access_key = conn.assigns.access_key

    with {:ok, registration} <- parse(conn.assigns.raw_body),
         :ok <- fresh(registration),
         {:ok, answer} <- Registration.register(access_key, registration, meta(conn)) do
      answer(conn, answer)
    else
      {:error, :invalid_request, name} ->
        conn |> put_status(400) |> json(%{error: "invalid_request", names: [name]})

      :unauthorized ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :gone} ->
        send_resp(conn, 410, "")

      {:error, :instance_limit} ->
        conn |> put_status(409) |> json(%{error: "instance_limit"})

      {:error, :run_id_used} ->
        conn |> put_status(409) |> json(%{error: "run_id_used"})

      {:error, :unavailable} ->
        unavailable(conn)
    end
  rescue
    exception ->
      Logger.error("a registration could not be stored: #{inspect(exception.__struct__)}")
      unavailable(conn)
  end

  def show(conn, %{"run_id" => run_id}) do
    case Registration.fetch(conn.assigns.access_key, run_id) do
      {:ok, answer} -> answer(conn, answer)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, _reason} -> unavailable(conn)
    end
  rescue
    _exception -> unavailable(conn)
  end

  defp answer(conn, %{settings: settings, digest: digest, etag: etag}) do
    conn
    |> put_resp_header("x-qory-run-configuration", digest)
    |> put_resp_header("etag", etag)
    |> put_resp_header("x-qory-configuration", Configuration.digest(conn.assigns.access_key.node))
    |> put_resp_content_type("application/json")
    |> send_resp(200, settings)
  end

  defp unavailable(conn), do: conn |> put_status(503) |> json(%{error: "unavailable"})

  defp parse(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, body} -> Registration.parse(body)
      {:error, _reason} -> {:error, :invalid_request, "body"}
    end
  end

  # The registration's `time`, held to the window a GET's timestamp is held to, by the
  # same clock.
  defp fresh(registration) do
    now = DateTime.from_unix!(SignedRequest.now())
    if Registration.fresh?(registration, now), do: :ok, else: :unauthorized
  end

  defp meta(conn) do
    %{
      body: conn.assigns.raw_body,
      contract_version: conn.assigns.contract_version,
      instance_id: conn.assigns.instance_id,
      forager_version: SignedRequest.forager_version(conn)
    }
  end
end
