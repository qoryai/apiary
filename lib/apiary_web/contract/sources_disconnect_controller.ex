defmodule ApiaryWeb.Contract.SourcesDisconnectController do
  @moduledoc false

  # `POST /v1/sources/disconnect`, an adapter saying it no longer reaches one collection
  # (the integration contract's `sources-disconnect.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the adapter's
  # access key, refuses what comes before the body, and signs the answer. The body is read
  # raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Adapters.Wire.decode/1`, `Apiary.Adapters.Wire.source_disconnect/1`); a
  # `time` more than 300 seconds from the clock, either way, or a request whose signature
  # was accepted before, is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`);
  # then `Apiary.Adapters.Collections.disconnect/2`: `403` `forbidden` for a key that may
  # not disconnect (`adapter.disconnect`), before any collection is looked up; `409`
  # `connection_suspended` for a live collection whose organisation is out of use; else
  # `204`, signed, with no body, also for a ref with no live collection, which changes
  # nothing. Never `connection_unknown` or `connection_ended`. When it cannot be stored,
  # the answer is `503` `unavailable`. Nothing here logs the body, a header or a
  # signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collections, Wire}
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, disconnect} <- Wire.source_disconnect(body),
         {:ok, conn} <- AdapterRequest.accept(conn, disconnect.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, _outcome} <- Collections.disconnect(scope, disconnect) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :suspended} -> refuse(conn, 409, "connection_suspended")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's disconnect of a collection could not be stored: " <>
          inspect(exception.__struct__)
      )

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
