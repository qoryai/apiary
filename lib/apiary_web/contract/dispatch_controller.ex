defmodule ApiaryWeb.Contract.DispatchController do
  @moduledoc false

  # `POST /v1/dispatches/<dispatch_id>/dispatched`, with which a node pool's starter says
  # it started the job for a dispatch (the provisioner contract's
  # `dispatched.schema.json`), and `POST /v1/dispatches/<dispatch_id>/release`, with which
  # it gives the dispatch's run back (`release.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the request
  # under the pool's access key, refuses what comes before the body, and signs the
  # answer. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Dispatches.Wire.dispatched/1`, `Apiary.Dispatches.Wire.release/1`); a `time`
  # more than 300 seconds from the clock, either way, or a request whose signature was
  # accepted before, is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`).
  #
  # A `dispatched` accepted is recorded (`Apiary.Dispatches.dispatched/3`), for the
  # revision the request named: the key read again and refused, `401`, unsigned; an
  # unknown dispatch, another pool's, or the action refused, `403` `forbidden`, one answer;
  # a prebuild's dispatch at revision 1, `404` `not_found`; a dispatch that ended, `410`
  # `gone`; one whose lease lapsed before its handover, `409` `lease_expired`; anything Qory
  # could not do, `503` `unavailable`. Else `204`, signed, with no body: the first
  # `dispatched` of a dispatch records when and the job it names, a later one nothing.
  #
  # A release is not served yet: an accepted one is answered as a route the instance does
  # not serve, `404` `not_found`, signed.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.Dispatches
  alias Apiary.Dispatches.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def dispatched(conn, %{"dispatch_id" => dispatch_id}) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, dispatched} <- Wire.dispatched(body),
         {:ok, conn} <- AdapterRequest.accept(conn, dispatched.time) do
      meta = %{revision: conn.assigns.contract_version, external: dispatched.external}

      case Dispatches.dispatched(conn.assigns.access_key, dispatch_id, meta) do
        :ok -> send_resp(conn, 204, "")
        {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
        {:error, :forbidden} -> refuse(conn, 403, "forbidden")
        {:error, :not_found} -> refuse(conn, 404, "not_found")
        {:error, :gone} -> refuse(conn, 410, "gone")
        {:error, :lease_expired} -> refuse(conn, 409, "lease_expired")
        {:error, :unavailable} -> refuse(conn, 503, "unavailable")
      end
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  @doc false
  def release(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, %{time: time}} <- Wire.release(body),
         {:ok, conn} <- AdapterRequest.accept(conn, time) do
      refuse(conn, 404, "not_found")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
