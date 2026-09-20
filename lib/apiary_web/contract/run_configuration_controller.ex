defmodule ApiaryWeb.Contract.RunConfigurationController do
  @moduledoc """
  The run configuration endpoint of the server contract: a signed
  `GET /v1/run-configuration?forge=<label>&repository=<label>`, reached only through
  `ApiaryWeb.Contract.SignedRequest`, as discovery is.

  The answer is `200`, `application/json`, the bytes as they were stored when the policy
  was rendered (never rendered again for a request, so the digest is of what is sent),
  with `X-Qory-Run-Configuration: sha256=<hex>`, the same string quoted as the `ETag`,
  and `X-Qory-Configuration`. It is the configuration of the key's hive for the labelled
  repository; a repository the hive does not know, one without rules of its own and a
  request that names none get the hive's baseline.

  Never a `304`: to a runner anything but `200` is no run, so `If-None-Match` is not
  read. A parameter sent as anything but a string, or longer than a label may be, names
  no repository and gets the baseline (of one sent twice the last is read); nothing of the query is logged or
  repeated. When the configuration cannot be read the answer is `503`, which is no run:
  the runner fails closed, as the contract has it.
  """
  use ApiaryWeb, :controller

  alias Apiary.Policy.Serving
  alias ApiaryWeb.Contract.Configuration

  def show(conn, params) do
    case Serving.fetch(conn.assigns.access_key, params["forge"], params["repository"]) do
      {:ok, configuration} ->
        conn
        |> put_resp_header("x-qory-run-configuration", configuration.digest)
        |> put_resp_header("etag", ~s("#{configuration.digest}"))
        |> put_resp_header("x-qory-configuration", Configuration.digest())
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(200, configuration.document)

      {:error, _reason} ->
        conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  rescue
    _exception -> conn |> put_status(503) |> json(%{error: "unavailable"})
  end
end
