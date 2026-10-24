defmodule ApiaryWeb.Contract.AppValuesController do
  @moduledoc false

  # `POST /v1/adapter/secrets`, an adapter storing in Qory Apiary the secrets it keeps
  # there (the integration contract's `adapter-secrets.schema.json`), sealed to the
  # instance's signing key. Reached only through `ApiaryWeb.Contract.AdapterRequest`, which
  # verifies the request under the adapter's access key, refuses what comes before the
  # body, and signs the answer. The body is read raw, up to 1 MiB
  # (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Adapters.Wire.secrets_upload/1`); a `time` more than 300 seconds from the
  # clock, either way, or a request whose signature was accepted before, is `401`,
  # unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`); a key that may not store the
  # adapter's secrets (`adapter.app_values_set`) is `403` `forbidden`, and `404`
  # `not_found` where its adapter is not found to it; an envelope sealed to a key the
  # instance does not hold, one that does not open, a plaintext the contract refuses, and
  # a secret whose name the source role of the adapter's latest description does not list
  # (`secrets`, `Apiary.Nodes.Node`'s `secret_names`) are `400` `invalid_request`
  # (`Apiary.Secrets.AdapterSealing.open_upload/4`); an adapter installed with Qory Apiary
  # that `QORY_INSTALLED_ADAPTERS` no longer lists is `404` `not_found`; else the secrets
  # replace every secret the adapter stored before (`Apiary.Adapters.store_app_values/3`),
  # with an entry of `adapter.app_values_set` in the same transaction, and the answer is `204`,
  # signed, with no body. When they cannot be stored, the answer is `503` `unavailable`.
  #
  # The `info` and the associated data are built from the adapter and the access key the
  # request verified under, never from the body. Nothing here logs the body, a value, a
  # header, a key or a signature: a failure is logged by the exception's module alone.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters
  alias Apiary.Adapters.Wire
  alias Apiary.Secrets.AdapterSealing
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    raw = conn.assigns.raw_body
    conn = assign(conn, :raw_body, nil)

    with {:ok, upload} <- Wire.secrets_upload(raw),
         {:ok, conn} <- AdapterRequest.accept(conn, upload.time),
         key = conn.assigns.access_key,
         scope = Scope.for_access_key(key),
         {:ok, adapter} <- Adapters.for_key(scope, :"adapter.app_values_set"),
         {:ok, values} <- AdapterSealing.open_upload(upload.sealed, adapter.public_id, key.key_id),
         {:ok, _stored} <- Adapters.store_app_values(scope, adapter, values) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :not_found} -> refuse(conn, 404, "not_found")
      {:error, :unavailable} -> refuse(conn, 503, "unavailable")
      {:error, _refusal} -> refuse(conn, 400, "invalid_request")
    end
  rescue
    exception ->
      Logger.error("an adapter's secrets could not be stored: " <> inspect(exception.__struct__))

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
