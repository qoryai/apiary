defmodule ApiaryWeb.Contract.SourceCollectionsController do
  @moduledoc false

  # `POST /v1/source-collections`, one part of an adapter's listing of the collections it
  # reaches through one connection (the integration contract's
  # `source-collections.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the adapter's
  # access key, refuses what comes before the body, and signs the answer. The body is read
  # raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Adapters.Wire.decode/1`, `Apiary.Adapters.Wire.listing/1`); a `time` more
  # than 300 seconds from the clock, either way, or a request whose signature was accepted
  # before, is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then
  # `Apiary.Adapters.Collections.post_listing/2`: `403` `forbidden` for a key that may not
  # post (`source_item.post`), `403` `connection_unknown` for a connection the instance does
  # not hold for the adapter, or one pending, `409` `connection_ended`, `409`
  # `connection_suspended`, and `400` `invalid_request` for a part with a
  # `grant_ref` the connection has no live grant with, then for a part that disagrees with
  # the listing's parts before it; else `204`, signed, with no body. When the part cannot be
  # taken, the answer is `503` `unavailable`. Nothing here logs the body, a header or a
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
         {:ok, listing} <- Wire.listing(body),
         {:ok, conn} <- AdapterRequest.accept(conn, listing.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, :accepted} <- Collections.post_listing(scope, listing) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :unknown} -> refuse(conn, 403, "connection_unknown")
      {:error, :ended} -> refuse(conn, 409, "connection_ended")
      {:error, :suspended} -> refuse(conn, 409, "connection_suspended")
      {:error, :invalid} -> refuse(conn, 400, "invalid_request")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's listing of collections could not be taken: " <>
          inspect(exception.__struct__)
      )

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
