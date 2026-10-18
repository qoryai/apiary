defmodule ApiaryWeb.Contract.HandoverController do
  @moduledoc false

  # `POST /v1/dispatches/<dispatch_id>/handover`, with which a node pool's starter asks
  # for the run key and the input of the job it started for a dispatch (the provisioner
  # contract's `handover.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the request
  # under the pool's access key, refuses what comes before the body, and signs the
  # answer but a `401`, with `Cache-Control: no-store, no-transform`. The body is read
  # raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses, labels among what it refuses, is `400`
  # `invalid_request` (`Apiary.Dispatches.Wire.handover/1`); a `time` more than 300
  # seconds from the clock, either way, or a request whose signature was accepted before,
  # is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`), before anything is
  # looked up. Then the handover (`Apiary.Dispatches.handover/3`), for the revision the
  # request named, with the refusals in the contract's order: the key read again and
  # refused, `401`, unsigned; an unknown dispatch, another pool's, or the action refused,
  # `403` `forbidden`, one answer; a prebuild's dispatch at revision 1, `404` `not_found`;
  # a dispatch that ended, or that the handover ended as it could not form the run, `410`
  # `gone`; `409` `handed_over`, `lease_expired`, `not_dispatched` and `no_gateway`; and
  # last, a run key or anything else Qory could not make, `503` `unavailable`, after which
  # nothing was written.
  #
  # A run handed over is `200`: `handover-answer.schema.json`, its members in the
  # schema's order, its `revision` the request's, its `work_item` an explore run's alone,
  # and its `inputs` as Qory wrote them (`Apiary.Dispatches.Inputs`). The run key is given
  # once, in this answer; nothing here logs it, the body or the input.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Dispatches
  alias Apiary.Dispatches.Wire
  alias ApiaryWeb.Contract.{AdapterRequest, DispatchAnswer}

  @conflicts [:handed_over, :lease_expired, :not_dispatched, :no_gateway]

  @doc false
  def create(conn, %{"dispatch_id" => dispatch_id}) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, handover} <- Wire.handover(body),
         {:ok, conn} <- AdapterRequest.accept(conn, handover.time) do
      accepted(conn, dispatch_id)
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  # The handover of a request accepted: `conn` is the one `accept/2` marked.
  defp accepted(conn, dispatch_id) do
    meta = %{revision: conn.assigns.contract_version, body: conn.assigns.raw_body}

    case handover(conn.assigns.access_key, dispatch_id, meta) do
      {:ok, handed_over} -> answer(conn, handed_over)
      {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :not_found} -> refuse(conn, 404, "not_found")
      {:error, :gone} -> refuse(conn, 410, "gone")
      {:error, reason} when reason in @conflicts -> refuse(conn, 409, Atom.to_string(reason))
      {:error, :unavailable} -> refuse(conn, 503, "unavailable")
    end
  end

  # The handover alone answers `503` for an exception: once it has answered, the run may
  # be handed over, so nothing after it is answered so.
  defp handover(access_key, dispatch_id, meta) do
    Dispatches.handover(access_key, dispatch_id, meta)
  rescue
    exception ->
      Logger.error("a handover could not be answered: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp answer(conn, %{run: run, run_key: run_key, dispatch_run: dispatch_run} = handed_over) do
    work_item =
      if handed_over.work_item,
        do: [{"work_item", DispatchAnswer.work_item(handed_over.work_item)}],
        else: []

    body =
      Jason.encode!(
        Jason.OrderedObject.new(
          [
            {"version", 1},
            {"revision", conn.assigns.contract_version},
            {"run_id", run.node_run_id},
            {"run_key", run_key},
            {"step", dispatch_run.step},
            {"access", DispatchAnswer.access(dispatch_run.step)},
            {"target", DispatchAnswer.target(handed_over.target.system, handed_over.target.path)}
          ] ++ work_item ++ [{"inputs", handed_over.inputs}]
        )
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
