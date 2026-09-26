defmodule ApiaryWeb.Contract.RunConfigurationController do
  @moduledoc """
  The run configuration endpoint of the server contract: a signed
  `GET /v1/run-configuration?<label>=<value>&…`, reached only through
  `ApiaryWeb.Contract.SignedRequest`, as discovery is. Every query parameter is one of the
  run's labels, and the runner sends every label of the run. The hive's body
  (`Apiary.Body`) says which of them name the target.

  The answer is `200`, `application/json`, the bytes as they were stored when the policy
  was rendered (never rendered again for a request, so the digest is of what is sent),
  with `X-Qory-Run-Configuration: sha256=<hex>`, the same string quoted as the `ETag`,
  and `X-Qory-Configuration`. It is the configuration of the key's hive for the target the
  labels name; a target the hive does not know, one without rules of its own and a
  request that names none get the hive's baseline.

  A hive nobody has given a policy (`Apiary.Policy.managed?/1`) serves none: `404`
  `{"error":"not_found"}`, and nothing is rendered. Discovery names no `run` section for
  such a hive, so a runner does not ask. A key is limited here as on the events endpoint,
  from the same bucket: `429` with `Retry-After`.

  Never a `304`: to a runner anything but `200` is no run, so `If-None-Match` is not
  read. A parameter sent as anything but a string, or longer than a label may be, names
  no target and gets the baseline (of one sent twice the last is read); nothing of the query is logged or
  repeated. When the configuration cannot be read the answer is `503`, which is no run:
  the runner fails closed, as the contract has it.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :security

  alias Apiary.Policy.Serving
  alias Apiary.Runs.RateLimit
  alias ApiaryWeb.Contract.Configuration

  def show(conn, _params) do
    case RateLimit.check(conn.assigns.access_key.id) do
      :ok ->
        serve(conn)

      {:error, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(429)
        |> json(%{error: "rate_limited"})
    end
  end

  defp serve(conn) do
    case Serving.fetch(conn.assigns.access_key, conn.query_params) do
      {:ok, configuration} ->
        conn
        |> put_resp_header("x-qory-run-configuration", configuration.digest)
        |> put_resp_header("etag", ~s("#{configuration.digest}"))
        |> put_resp_header("x-qory-configuration", Configuration.digest(true))
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(200, configuration.document)

      {:error, :unmanaged} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, _reason} ->
        conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  rescue
    _exception -> conn |> put_status(503) |> json(%{error: "unavailable"})
  end
end
