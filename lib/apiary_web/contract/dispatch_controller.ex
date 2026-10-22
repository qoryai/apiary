defmodule ApiaryWeb.Contract.DispatchController do
  @moduledoc false

  # `POST /v1/dispatches/<dispatch_id>/dispatched`, with which a node pool's starter says
  # it started the job for a dispatch (the provisioner contract's
  # `dispatched.schema.json`), `POST /v1/dispatches/<dispatch_id>/release`, with which
  # it gives the dispatch's run back (`release.schema.json`), and
  # `POST /v1/dispatches/<dispatch_id>/machine-log`, with which it uploads the log of the
  # machine it created for the dispatch (`machine-log.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the request
  # under the pool's access key, refuses what comes before the body, and signs the
  # answer. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Dispatches.Wire.dispatched/1`, `Apiary.Dispatches.Wire.release/1`,
  # `Apiary.Dispatches.Wire.machine_log/1`); a `time`
  # more than 300 seconds from the clock, either way, or a request whose signature was
  # accepted before, is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`).
  #
  # A `dispatched` accepted is recorded (`Apiary.Dispatches.dispatched/3`): the key read
  # again and refused, `401`, unsigned; an unknown dispatch, another pool's, or the action
  # refused, `403` `forbidden`, one answer; a dispatch that ended, `410` `gone`; one whose
  # lease lapsed before its handover, `409` `lease_expired`; anything Qory could not do,
  # `503` `unavailable`. Else `204`, signed, with no body: the first `dispatched` of a
  # dispatch records when and the job it names, a later one nothing.
  #
  # A release accepted gives the dispatch's run back (`Apiary.Dispatches.release/3`), with
  # the body's `reason`, with the refusals in the contract's order: the key
  # read again and refused, `401`, unsigned; an unknown dispatch, another pool's, or the
  # action refused, `403` `forbidden`, one answer, after which nothing is written; a
  # dispatch that ended, or of a run that ended, `410` `gone`; one handed over, by its
  # `dispatched` or by the redemption of its run code, `409` `machine_exists`; one whose
  # lease lapsed, `409` `lease_expired`; anything Qory could not do, `503` `unavailable`,
  # after which nothing was written. Else `204`, signed, with no body, and the run waits
  # again.
  #
  # A machine log accepted is stored (`Apiary.Dispatches.upload_machine_log/3`), with the
  # body's `log` and `truncated`, with the refusals in the contract's order: the key read
  # again and refused, `401`, unsigned; an unknown dispatch, another pool's, or the action
  # refused, `403` `forbidden`, one answer; a dispatch with a machine log already, `409`
  # `machine_log_exists`; a file that cannot be written, no folder set among the causes,
  # or anything else Qory could not do, `503` `unavailable`. Nothing is written on a
  # refusal. A dispatch that ended or whose lease lapsed is never refused for it. Else
  # `204`, signed, with no body.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Dispatches
  alias Apiary.Dispatches.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def dispatched(conn, %{"dispatch_id" => dispatch_id}) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, dispatched} <- Wire.dispatched(body),
         {:ok, conn} <- AdapterRequest.accept(conn, dispatched.time) do
      meta = %{external: dispatched.external}

      case Dispatches.dispatched(conn.assigns.access_key, dispatch_id, meta) do
        :ok -> send_resp(conn, 204, "")
        {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
        {:error, :forbidden} -> refuse(conn, 403, "forbidden")
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
  def release(conn, %{"dispatch_id" => dispatch_id}) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, release} <- Wire.release(body),
         {:ok, conn} <- AdapterRequest.accept(conn, release.time) do
      meta = %{reason: release.reason}

      case release(conn.assigns.access_key, dispatch_id, meta) do
        :ok -> send_resp(conn, 204, "")
        {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
        {:error, :forbidden} -> refuse(conn, 403, "forbidden")
        {:error, :gone} -> refuse(conn, 410, "gone")
        {:error, :machine_exists} -> refuse(conn, 409, "machine_exists")
        {:error, :lease_expired} -> refuse(conn, 409, "lease_expired")
        {:error, :unavailable} -> refuse(conn, 503, "unavailable")
      end
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  @doc false
  def machine_log(conn, %{"dispatch_id" => dispatch_id}) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, machine_log} <- Wire.machine_log(body),
         {:ok, conn} <- AdapterRequest.accept(conn, machine_log.time) do
      meta = Map.delete(machine_log, :time)

      case Dispatches.upload_machine_log(conn.assigns.access_key, dispatch_id, meta) do
        :ok -> send_resp(conn, 204, "")
        {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
        {:error, :forbidden} -> refuse(conn, 403, "forbidden")
        {:error, :machine_log_exists} -> refuse(conn, 409, "machine_log_exists")
        {:error, :unavailable} -> refuse(conn, 503, "unavailable")
      end
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  # The release alone answers `503` for an exception: once it has answered, the run may be
  # given back, so nothing after it is answered so.
  defp release(access_key, dispatch_id, meta) do
    Dispatches.release(access_key, dispatch_id, meta)
  rescue
    exception ->
      Logger.error("a release could not be answered: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
