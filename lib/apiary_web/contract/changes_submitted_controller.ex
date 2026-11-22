defmodule ApiaryWeb.Contract.ChangesSubmittedController do
  @moduledoc false

  # `POST /v1/work-items/changes/submitted`, an adapter's reply for a `change_request` entry
  # of its change feed: what it did at the target (the integration contract's
  # `changes-submitted.schema.json`, `Apiary.Adapters.ChangeReport.submitted/1`). Reached only
  # through `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the
  # adapter's access key, refuses what comes before the body, and signs the answer. The body
  # is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses, a member twice among them, is `400`
  # `invalid_request`; a `time` more than 300 seconds from the clock, either way, or a request
  # whose signature was accepted before, is `401`, unsigned
  # (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then `403` `forbidden` for a key that may
  # not report on a change request (`change_request.report`), before any version is looked up;
  # else `204`, signed, with no body. The `204` stores the reply with the version
  # (`Apiary.Artifacts.Delivery.delivered/2`), only while its delivery is `sent` and its target
  # is a target of the key's adapter with the body's collection. For an id of no such version,
  # another adapter's version, a version not sent, or one with a result already, the `204`
  # changes nothing: the first result is kept. The body has no connection and no collection
  # ref, so no other refusal applies. When the reply cannot be stored, the answer is `503`
  # `unavailable`. Nothing here logs the body, a header or a signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{ChangeReport, Connections, Wire}
  alias Apiary.Artifacts.Delivery
  alias ApiaryWeb.Contract.AdapterRequest

  @action :"change_request.report"

  @doc false
  def create(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, report} <- ChangeReport.submitted(body),
         {:ok, conn} <- AdapterRequest.accept(conn, report.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, adapter_id} <- Connections.key_rights(scope, @action),
         {:ok, _stored} <- Delivery.delivered(adapter_id, report) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's reply for a change request could not be stored: " <>
          inspect(exception.__struct__)
      )

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
