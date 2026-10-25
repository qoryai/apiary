defmodule ApiaryWeb.Contract.GrantEndController do
  @moduledoc false

  # `POST /v1/grants/end`, an adapter reporting that the source no longer covers one grant
  # of a connection (the integration contract's `grant-end.schema.json`,
  # `Apiary.Adapters.Grants.end_grant/2`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the adapter's
  # access key, refuses what comes before the body, and signs the answer. The body is read
  # raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Adapters.Wire.decode/1`, `Apiary.Adapters.Wire.grant_end/1`); a `time` more
  # than 300 seconds from the clock, either way, or a request whose signature was accepted
  # before, is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then
  # `Apiary.Adapters.Grants.end_grant/2`: `403` `forbidden` for a key that may not end a
  # grant (`adapter.end_grant`); `403` `connection_unknown` for an id that matches none
  # of the adapter's connections, or a pending connection; `409` `connection_ended`; `409`
  # `grant_unknown` when the connection has no live grant with that `grant_ref`; else
  # `204`, signed, with no body, which ends the grant and its collections and leaves the
  # connection. A connection whose organisation is out of use gets the `204` too: never
  # `connection_suspended`. When the change cannot be stored, the answer is `503`
  # `unavailable`. Nothing here logs the body, a header or a signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Grants, Wire}
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, grant_end} <- Wire.grant_end(body),
         {:ok, conn} <- AdapterRequest.accept(conn, grant_end.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, _grant} <- Grants.end_grant(scope, grant_end) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :unknown} -> refuse(conn, 403, "connection_unknown")
      {:error, :ended} -> refuse(conn, 409, "connection_ended")
      {:error, :grant_unknown} -> refuse(conn, 409, "grant_unknown")
    end
  rescue
    exception ->
      Logger.error("storing an adapter's grant end failed: " <> inspect(exception.__struct__))

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
