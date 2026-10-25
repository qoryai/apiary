defmodule ApiaryWeb.Contract.SecretsController do
  @moduledoc false

  # With the `factory` and `secrets` features, or the `registry` feature, which the
  # documentation leaves out: the secrets request, a signed `POST /v1/secrets` of a
  # gateway for the values of credentials of a run's run configuration
  # (`Apiary.Runs.SecretsRequest`), under the gateway's access key. Reached only through
  # `ApiaryWeb.Contract.SignedRequest`, as the run endpoint is, under the run endpoint's
  # bucket of the key's rate limit, which verifies the request and signs the answer. The
  # body is read raw, up to 32 KiB (`ApiaryWeb.Contract.RawBody`). Without `registry`, a
  # request that verifies is given a signed `404` where `factory` or `secrets` is off, as
  # a path the instance does not serve: the route's gate is `factory` or `registry`
  # (`ApiaryWeb.Features.Routes`), and the rest is checked here.
  #
  # The answer is `200`, `application/json`, the sealed envelope
  # (`secrets-answer.schema.json`). The refusals: `400` `invalid_request`; `401`,
  # unsigned, for a `timestamp` outside the window; `409` `secrets_not_allowed`; `404`;
  # `410` `workspace_not_served`; `410` with no body for a run that is not live; `409`
  # `credential_unavailable`; `410` `run_configuration_superseded`; `409`
  # `credentials_differ`; `503`. Errors are short JSON and never repeat anything sent; the
  # body, the answer, the signature and the headers are never logged.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, any: [:factory, :registry]

  require Logger

  alias Apiary.Features
  alias Apiary.Runs.SecretsRequest
  alias ApiaryWeb.Contract.{Configuration, SignedRequest}

  @conflicts [:secrets_not_allowed, :credential_unavailable, :credentials_differ]

  def create(conn, _params) do
    if Features.on?(:registry) or (Features.on?(:factory) and Features.on?(:secrets)),
      do: answer(conn),
      else: conn |> put_status(404) |> json(%{error: "not_found"})
  end

  defp answer(conn) do
    access_key = conn.assigns.access_key

    case SecretsRequest.answer(
           access_key,
           conn.assigns.raw_body,
           conn.assigns.instance_id,
           SignedRequest.now()
         ) do
      {:ok, body} ->
        conn
        |> put_resp_header("x-qory-configuration", Configuration.digest(access_key))
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :invalid_request} ->
        conn |> put_status(400) |> json(%{error: "invalid_request"})

      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, code} when code in @conflicts ->
        conn |> put_status(409) |> json(%{error: Atom.to_string(code)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, code} when code in [:workspace_not_served, :run_configuration_superseded] ->
        conn |> put_status(410) |> json(%{error: Atom.to_string(code)})

      {:error, :gone} ->
        send_resp(conn, 410, "")

      {:error, _reason} ->
        unavailable(conn)
    end
  rescue
    exception ->
      Logger.error("a secrets request could not be answered: #{inspect(exception.__struct__)}")
      unavailable(conn)
  end

  defp unavailable(conn), do: conn |> put_status(503) |> json(%{error: "unavailable"})
end
