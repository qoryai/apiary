defmodule ApiaryWeb.Contract.EventsController do
  @moduledoc """
  The events endpoint of the server contract: `POST /v1/events`, one signed
  batch of one run's events.

  The refusals come in the contract's order, and the first ones happen before this
  controller: a body over 2 MiB is `413` (`ApiaryWeb.Contract.RawBody`); then, in
  `ApiaryWeb.Contract.SignedRequest`, a content type other than
  `application/cloudevents-batch+json` is `415`, a header the signature depends on sent
  twice is `400`, a request that does not verify is `401` (over the raw bytes, before
  anything is parsed), a key over its rate is `429` with `Retry-After`, an instance id
  absent or malformed is `400`, and a request whose `X-Qory-Contract-Version` names no
  revision served is `400`. Here, in order: a body the contract refuses (not a batch, or
  one that holds a `dev.qory.ping` or a `dev.qory.run.registered`, `Apiary.Runs.Batch`)
  is `400` `invalid_request`; a key `Apiary.Access` does not let post
  (`run.post_events`) is `404`, as a path that does not exist; then
  `Apiary.Runs.Ingest`: a run whose events retention has pruned is `410`, even for a
  delivery already recorded; any other delivery already recorded is `202` again; anything
  else is stored and answered `202`, with nothing projected yet. A run starts by its
  registration (`ApiaryWeb.Contract.RegistrationController`), which the instance limit
  admits; a batch is held to no limit.

  Every answer is signed (`ApiaryWeb.Contract.SignedAnswer`). Every `202` and `410`
  carries the digests in force: `X-Qory-Configuration`, the digest the key's discovery
  answer carries, and, for a workspace whose policy somebody has made,
  `X-Qory-Run-Configuration`, the digest of the run configuration for the run's target
  (`Apiary.Policy.Serving.digest_for/4`: read, never rendered here), which is how a run
  learns that its policy changed. A workspace nobody has given a policy names no run
  configuration anywhere, and its machines keep their own. The digest the request
  reported is stored on the delivery and on the run. Errors are short JSON and never
  repeat anything sent. The body, the signature and the headers are never logged.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  alias Apiary.Runs.{Batch, Ingest}
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  def create(conn, _params) do
    access_key = conn.assigns.access_key

    with {:ok, batch} <- batch(conn.assigns.raw_body),
         {:ok, %{status: status} = result} <- Ingest.ingest(access_key, batch, meta(conn)) do
      conn
      |> put_resp_header("x-qory-configuration", Configuration.digest(access_key.node))
      |> put_run_configuration(result[:run_configuration_digest])
      |> send_resp(status, "")
    else
      :invalid_request ->
        conn |> put_status(400) |> json(%{error: "invalid_request"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, _reason} ->
        conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  end

  # Absent for a workspace that is not managed, and when it could not be read: a header
  # absent means nothing to the gateway.
  defp put_run_configuration(conn, digest) when is_binary(digest),
    do: put_resp_header(conn, "x-qory-run-configuration", digest)

  defp put_run_configuration(conn, _digest), do: conn

  defp batch(raw_body) do
    case Batch.parse(raw_body) do
      {:ok, batch} -> {:ok, batch}
      :error -> :invalid_request
    end
  end

  defp meta(conn) do
    %{
      delivery_id: single(conn, "x-qory-delivery"),
      run_configuration: single(conn, "x-qory-run-configuration"),
      forager_version: SignedRequest.forager_version(conn),
      contract_version: conn.assigns.contract_version,
      instance_id: conn.assigns.instance_id
    }
  end

  defp single(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end
end
