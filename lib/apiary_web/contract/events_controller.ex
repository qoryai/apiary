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
  revision served is `400`. Here, in order: a body the contract refuses (not a batch, or a ping whose `interval_seconds` is
  absent or outside 1 to 300, `Apiary.Runs.Batch`) is `400` `invalid_request`; a key
  `Apiary.Access` does not let post (`run.post_events`) is `404`, as a path that does not
  exist; then `Apiary.Runs.Ingest`: a delivery already recorded is `202` again, a run the
  workspace has closed is `410`, and the ping of a new run from an instance beyond its
  node's limit is `409` `instance_limit` (`Apiary.Nodes.admit/4`), with nothing stored;
  anything else is stored and answered `202`, with nothing projected yet.

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
      |> put_configuration(access_key.node, result[:managed])
      |> put_run_configuration(result[:run_configuration_digest])
      |> send_resp(status, "")
    else
      :invalid_request ->
        conn |> put_status(400) |> json(%{error: "invalid_request"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :instance_limit} ->
        conn |> put_status(409) |> json(%{error: "instance_limit"})

      {:error, _reason} ->
        conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  end

  # The discovery document is one of two for the key's node, by whether the workspace's
  # policy is managed; when that could not be read, neither digest is claimed.
  defp put_configuration(conn, node, managed?) when is_boolean(managed?),
    do: put_resp_header(conn, "x-qory-configuration", Configuration.digest(node, managed?))

  defp put_configuration(conn, _node, _unknown), do: conn

  # Absent for a workspace that is not managed, and when it could not be read: a header
  # absent means nothing to a runner.
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
