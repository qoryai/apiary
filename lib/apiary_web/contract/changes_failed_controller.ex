defmodule ApiaryWeb.Contract.ChangesFailedController do
  @moduledoc false

  # `POST /v1/work-items/changes/failed`, an adapter reporting that it stopped trying to
  # post the comment of a `comment` entry of its change feed (the integration contract's
  # `changes-failed.schema.json`, `Apiary.Sources.comment_failed/2`). Reached only
  # through `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the
  # adapter's access key, refuses what comes before the body, and signs the answer. The
  # body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Sources.Wire.failed/1`); a `time` more than 300 seconds from the clock,
  # either way, or a request whose signature was accepted before, is `401`, unsigned
  # (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then `403` `forbidden` for a key that
  # may not post comments (`source_item.post`), before any comment is looked up; else
  # `204`, signed, with no body. The `204` marks the comment not posted, with the report's
  # reason, only while its post is under way (`:posting`); a `comment_id` of no comment
  # entry of the adapter's feed, or of a comment already posted or already marked, gets
  # the `204` and changes nothing. The body has no connection and no collection, so no
  # other refusal applies. When the report cannot be stored, the answer is `503`
  # `unavailable`. Nothing here logs the body, a header or a signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Sources
  alias Apiary.Sources.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, report} <- Wire.failed(conn.assigns.raw_body),
         {:ok, conn} <- AdapterRequest.accept(conn, report.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, :accepted} <- Sources.comment_failed(scope, report) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's report of a comment not posted could not be stored: " <>
          inspect(exception.__struct__)
      )

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
