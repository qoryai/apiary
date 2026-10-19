defmodule ApiaryWeb.Contract.DispatchController do
  @moduledoc false

  # `POST /v1/dispatches/<dispatch_id>/dispatched`, with which a node pool's starter says
  # it started the job for a dispatch (the provisioner contract's
  # `dispatched.schema.json`), `POST /v1/dispatches/<dispatch_id>/release`, with which
  # it gives the dispatch's run back (`release.schema.json`), and
  # `POST /v1/dispatches/<dispatch_id>/prebuilt`, with which it reports the image the job
  # for a prebuild built (`prebuilt.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the request
  # under the pool's access key, refuses what comes before the body, and signs the
  # answer. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Dispatches.Wire.dispatched/1`, `Apiary.Dispatches.Wire.release/1`,
  # `Apiary.Dispatches.Wire.prebuilt/1`); a `time`
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
  # the body's `reason` and `retry`, with the refusals in the contract's order: the key
  # read again and refused, `401`, unsigned; an unknown dispatch, another pool's, or the
  # action refused, `403` `forbidden`, one answer, after which nothing is written; a
  # dispatch that ended, of a run that ended, or of a run whose outcome or exit came after
  # its handover, `410` `gone`; one not handed over whose lease lapsed, `409`
  # `lease_expired`, never one handed over; anything Qory could not do, `503`
  # `unavailable`, after which nothing was written. Else `204`, signed, with no body:
  # before the handover the run waits again or ends, and after it the run ends, and an
  # explore run with retry queues the next run of its take in.
  #
  # A prebuilt accepted records the image (`Apiary.Dispatches.prebuilt/3`), with the
  # body's `run_id`, `image`, `size`, `environment_ref` and `commit`, with the refusals in
  # the contract's order: the key read again and refused, `401`, unsigned; an unknown
  # dispatch, another pool's, or the action refused, `403` `forbidden`, one answer, after
  # which nothing is written; a dispatch that ended, a second prebuilt among them, or of a run whose outcome or exit
  # came after its handover, `410` `gone`; one not handed over whose lease lapsed, `409`
  # `lease_expired`; a dispatch whose step is not prebuild, `409` `not_prebuild`; one not
  # handed over yet, `409` `not_handed_over`; a `run_id` that is not the dispatch's run,
  # `409` `run_mismatch`; anything Qory could not do, `503` `unavailable`, after which
  # nothing was written. Else `204`, signed, with no body: the image is recorded for the
  # pool and the run ends.

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
      meta = %{reason: release.reason, retry: release.retry}

      case release(conn.assigns.access_key, dispatch_id, meta) do
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
  def prebuilt(conn, %{"dispatch_id" => dispatch_id}) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, prebuilt} <- Wire.prebuilt(body),
         {:ok, conn} <- AdapterRequest.accept(conn, prebuilt.time) do
      meta = Map.delete(prebuilt, :time)

      case prebuilt(conn.assigns.access_key, dispatch_id, meta) do
        :ok -> send_resp(conn, 204, "")
        {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
        {:error, :forbidden} -> refuse(conn, 403, "forbidden")
        {:error, :gone} -> refuse(conn, 410, "gone")
        {:error, :lease_expired} -> refuse(conn, 409, "lease_expired")
        {:error, :not_prebuild} -> refuse(conn, 409, "not_prebuild")
        {:error, :not_handed_over} -> refuse(conn, 409, "not_handed_over")
        {:error, :run_mismatch} -> refuse(conn, 409, "run_mismatch")
        {:error, :unavailable} -> refuse(conn, 503, "unavailable")
      end
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  # The release and the prebuilt alone answer `503` for an exception: once it has answered, the run may
  # be given back, or the image recorded, so nothing after it is answered so.
  defp release(access_key, dispatch_id, meta) do
    Dispatches.release(access_key, dispatch_id, meta)
  rescue
    exception ->
      Logger.error("a release could not be answered: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp prebuilt(access_key, dispatch_id, meta) do
    Dispatches.prebuilt(access_key, dispatch_id, meta)
  rescue
    exception ->
      Logger.error("a prebuilt could not be answered: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
