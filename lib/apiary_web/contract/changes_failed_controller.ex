defmodule ApiaryWeb.Contract.ChangesFailedController do
  @moduledoc false

  # `POST /v1/work-items/changes/failed`, an adapter reporting that it stopped trying to
  # post the comment of a `comment` entry of its change feed (the integration contract's
  # `changes-failed.schema.json`, `Apiary.Sources.comment_failed/2`), or to apply a
  # `change_request` entry: a body with `change_request_id` is that report, and any other is
  # the report of a comment. Reached only
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
  #
  # A report of a change request (`Apiary.Adapters.ChangeReport.failed/1`) goes the same
  # way, with `403` `forbidden` for a key that may not report on a change request
  # (`change_request.report`). Its `204` stores the failure with the version
  # (`Apiary.Artifacts.Delivery.failed/2`), only while the version's delivery is `sent` and
  # its target is a target of the key's adapter with the body's collection; for any other
  # version, or one with a result already, it changes nothing.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{ChangeReport, Connections}
  alias Apiary.Adapters.Wire, as: AdapterWire
  alias Apiary.Artifacts.Delivery
  alias Apiary.Sources
  alias Apiary.Sources.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @change_action :"change_request.report"

  @doc false
  def create(conn, _params) do
    with {:ok, kind, report} <- read(conn.assigns.raw_body),
         {:ok, conn} <- AdapterRequest.accept(conn, report.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, :accepted} <- store(kind, scope, report) do
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

  # The report of a change request when the body has `change_request_id`, else of a comment.
  defp read(raw) do
    case AdapterWire.decode(raw) do
      {:ok, %{"change_request_id" => _id} = body} ->
        with {:ok, report} <- ChangeReport.failed(body), do: {:ok, :change_request, report}

      _other ->
        with {:ok, report} <- Wire.failed(raw), do: {:ok, :comment, report}
    end
  end

  defp store(:comment, scope, report), do: Sources.comment_failed(scope, report)

  defp store(:change_request, scope, report) do
    with {:ok, adapter_id} <- Connections.key_rights(scope, @change_action),
         {:ok, _stored} <- Delivery.failed(adapter_id, report),
         do: {:ok, :accepted}
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
