defmodule ApiaryWeb.Contract.EventsController do
  @moduledoc """
  The events endpoint of the server contract: `POST /v1/events`, one signed
  batch of one run's events.

  The refusals come in the order of the contract's reference receiver, and the
  first two happen before this controller: a body over 2 MiB is `413`
  (`ApiaryWeb.Contract.RawBody`), a request that does not verify is `401`
  (`ApiaryWeb.Contract.SignedRequest`, over the raw bytes, before anything is
  parsed). Then: a content type other than `application/cloudevents-batch+json`
  is `415`; a key over its rate is `429` with `Retry-After`; a
  `X-Qory-Contract-Version` that is not a revision of v1 (an integer from 1 up) is
  `400` and says which revisions are known (absent is accepted: a plain client of the
  contract; a later revision than the ones known is accepted too, since a revision
  only adds and the server serves what it knows); a body that is
  not a batch is `400`; a run the hive has closed is `410`; anything else is
  stored and answered `202`, with nothing projected yet.

  Every `202` and `410` carries the digests in force: `X-Qory-Configuration`, the
  digest the hive's discovery answer carries, and, for a hive whose policy somebody has
  made, `X-Qory-Run-Configuration`, the digest of the run configuration for the run's
  target (`Apiary.Policy.Serving.digest_for/4`: read, never rendered here), which
  is how a run learns that its policy changed. A hive nobody has given a policy names
  no run configuration anywhere, and its machines keep their own. The
  digest the request reported is stored on the delivery and on the run. Errors are
  short JSON and never repeat anything sent. The body, the signature and the headers
  are never logged.
  """
  use ApiaryWeb, :controller

  alias Apiary.Runs.{Batch, Ingest, RateLimit}
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  @content_type "application/cloudevents-batch+json"
  # The revisions of contract v1 this server knows. A later one is accepted.
  @known [1]

  def create(conn, _params) do
    access_key = conn.assigns.access_key

    with :ok <- content_type(conn),
         :ok <- rate(access_key),
         :ok <- contract_version(conn),
         {:ok, batch} <- batch(conn.assigns.raw_body),
         {:ok, %{status: status} = result} <- Ingest.ingest(access_key, batch, meta(conn)) do
      conn
      |> put_configuration(result[:managed])
      |> put_run_configuration(result[:run_configuration_digest])
      |> send_resp(status, "")
    else
      {:refuse, status, body, headers} ->
        headers
        |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
        |> put_status(status)
        |> json(body)

      {:error, _reason} ->
        conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  end

  # The discovery document is one of two, by whether the hive's policy is managed; when
  # that could not be read, neither digest is claimed.
  defp put_configuration(conn, managed?) when is_boolean(managed?),
    do: put_resp_header(conn, "x-qory-configuration", Configuration.digest(managed?))

  defp put_configuration(conn, _unknown), do: conn

  # Absent for a hive that is not managed, and when it could not be read: a header absent means nothing to a runner.
  defp put_run_configuration(conn, digest) when is_binary(digest),
    do: put_resp_header(conn, "x-qory-run-configuration", digest)

  defp put_run_configuration(conn, _digest), do: conn

  # As the reference receiver reads it: the media type, whatever its case and
  # whatever parameters follow.
  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        if String.starts_with?(String.downcase(value), @content_type),
          do: :ok,
          else: unsupported_media_type()

      _ ->
        unsupported_media_type()
    end
  end

  defp unsupported_media_type, do: {:refuse, 415, %{error: "unsupported_media_type"}, []}

  defp rate(access_key) do
    case RateLimit.check(access_key.id) do
      :ok ->
        :ok

      {:error, seconds} ->
        {:refuse, 429, %{error: "rate_limited"}, [{"retry-after", Integer.to_string(seconds)}]}
    end
  end

  defp contract_version(conn) do
    case get_req_header(conn, "x-qory-contract-version") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {version, ""} when version >= 1 -> :ok
          _ -> unsupported_contract_version()
        end

      _ ->
        unsupported_contract_version()
    end
  end

  defp unsupported_contract_version do
    {:refuse, 400, %{error: "unsupported_contract_version", supported: @known}, []}
  end

  defp batch(raw_body) do
    case Batch.parse(raw_body) do
      {:ok, batch} -> {:ok, batch}
      :error -> {:refuse, 400, %{error: "invalid_batch"}, []}
    end
  end

  defp meta(conn) do
    %{
      delivery_id: single(conn, "x-qory-delivery"),
      run_configuration: single(conn, "x-qory-run-configuration"),
      runner_version: SignedRequest.runner_version(conn),
      contract_version: SignedRequest.contract_version(conn)
    }
  end

  defp single(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end
end
