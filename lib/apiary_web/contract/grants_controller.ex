defmodule ApiaryWeb.Contract.GrantsController do
  @moduledoc false

  # The grants of the adapter's connections (the integration contract's
  # `grant.schema.json` and `grants.schema.json`, `Apiary.Adapters.Grants`). Reached only
  # through `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the
  # adapter's access key, refuses what comes before the body, and signs the answer.
  #
  # `POST /v1/grants`, the adapter's report of one grant, its body read raw, up to 1 MiB
  # (`ApiaryWeb.Contract.RawBody`). In order: a body the contract refuses is `400`
  # `invalid_request` (`Apiary.Adapters.Wire.grant_report/1`); a `time` more than 300
  # seconds from the clock, either way, or a request whose signature was accepted before,
  # is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then
  # `Apiary.Adapters.Grants.report/2`: `403` `forbidden` for a key that may not report a
  # grant (`adapter.report_grant`); `403` `connection_unknown`; `409`
  # `connection_ended`; `409` `connection_suspended`; `409` `pass_unknown`; then `409`
  # `grant_taken` when the adapter has a grant with the same ref that has not ended under
  # any other connection of the adapter, of any organisation, a connection made but with
  # no accepted listing yet included; else `204`, signed, with no body.
  #
  # `GET /v1/grants`, the adapter's read of Qory Apiary's copy: `403` `forbidden` for a
  # key that may not read it (`adapter.read_grants`); else `200`, signed:
  # `{version: 1, revision, grants}`, each grant `{connection_id, grant_ref}`, of the
  # adapter's connections that have not ended, `revision` the request's
  # (`X-Qory-Contract-Version`).
  #
  # When the change cannot be stored or the copy read, the answer is `503`
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
         {:ok, report} <- Wire.grant_report(body),
         {:ok, conn} <- AdapterRequest.accept(conn, report.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, _grant} <- Grants.report(scope, report) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :unknown} -> refuse(conn, 403, "connection_unknown")
      {:error, :ended} -> refuse(conn, 409, "connection_ended")
      {:error, :suspended} -> refuse(conn, 409, "connection_suspended")
      {:error, :pass_unknown} -> refuse(conn, 409, "pass_unknown")
      {:error, :grant_taken} -> refuse(conn, 409, "grant_taken")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's report of a grant could not be stored: " <> inspect(exception.__struct__)
      )

      refuse(conn, 503, "unavailable")
  end

  @doc false
  def index(conn, _params) do
    scope = Scope.for_access_key(conn.assigns.access_key)

    case Grants.list_for_adapter(scope) do
      {:ok, grants} ->
        body =
          Jason.encode!(
            Jason.OrderedObject.new([
              {"version", 1},
              {"revision", conn.assigns.contract_version},
              {"grants",
               for {connection_id, grant_ref} <- grants do
                 Jason.OrderedObject.new([
                   {"connection_id", connection_id},
                   {"grant_ref", grant_ref}
                 ])
               end}
            ])
          )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :forbidden} ->
        refuse(conn, 403, "forbidden")
    end
  rescue
    exception ->
      Logger.error("an adapter's grants could not be read: #{inspect(exception.__struct__)}")
      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
