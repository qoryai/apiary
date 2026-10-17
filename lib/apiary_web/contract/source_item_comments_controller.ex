defmodule ApiaryWeb.Contract.SourceItemCommentsController do
  @moduledoc false

  # `POST /v1/source-items/comments`, an adapter's comments of one item: 1 to 100 of them,
  # or, with `complete`, 0 to 100, and the item's other comments updated before its
  # `since` marked deleted (the integration contract's
  # `source-item-comments.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the adapter's
  # access key, refuses what comes before the body, and signs the answer. The body is read
  # raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Sources.Wire.comments/1`); a `time` more than 300 seconds from the clock,
  # either way, or a request whose signature was accepted before, is `401`, unsigned
  # (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then `Apiary.Sources.post_comments/2`,
  # by the body's `item_ref`: `400` `invalid_request` for a comment the table would not
  # hold; `403` `forbidden` for a key that may not post (`source_item.post`), before any
  # item is looked up; then, of the collection that answers for the `item_ref` (the
  # collection of the item that holds it, or, when none does, the one that ended last of
  # those with an item with that ref), `409` `connection_ended` for a collection that
  # ended with its connection, `409` `connection_suspended` for a live collection whose
  # organisation is out of use, and `409` `collection_not_linked` for a collection that
  # ended otherwise or a live one linked to no workspace; an `item_ref` the adapter has no
  # item for is `409` `collection_not_linked` too; else `204`, signed, with no body. Never
  # `connection_unknown`: the body names no connection. When the comments cannot be
  # stored, the answer is `503` `unavailable`. Nothing here logs the body, a header or a
  # signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Sources
  alias Apiary.Sources.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, comments} <- Wire.comments(conn.assigns.raw_body),
         {:ok, conn} <- AdapterRequest.accept(conn, comments.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, :accepted} <- Sources.post_comments(scope, comments) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :ended} -> refuse(conn, 409, "connection_ended")
      {:error, :suspended} -> refuse(conn, 409, "connection_suspended")
      {:error, :not_linked} -> refuse(conn, 409, "collection_not_linked")
      {:error, :invalid} -> refuse(conn, 400, "invalid_request")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's comments of an item could not be stored: " <>
          inspect(exception.__struct__)
      )

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
