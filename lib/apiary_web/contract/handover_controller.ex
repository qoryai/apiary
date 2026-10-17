defmodule ApiaryWeb.Contract.HandoverController do
  @moduledoc false

  # `POST /v1/dispatches/<dispatch_id>/handover`, with which a node pool's starter asks
  # for the run key and the input of the job it started for a dispatch (the provisioner
  # contract's `handover.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the request
  # under the pool's access key, refuses what comes before the body, and signs the
  # answer. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses, labels among what it refuses, is `400`
  # `invalid_request` (`Apiary.Dispatches.Wire.handover/1`); a `time` more than 300
  # seconds from the clock, either way, or a request whose signature was accepted before,
  # is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`). The handover itself
  # is not served yet: an accepted request is answered as a route the instance does not
  # serve, `404` `not_found`, signed.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.Dispatches.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, handover} <- Wire.handover(body),
         {:ok, conn} <- AdapterRequest.accept(conn, handover.time) do
      refuse(conn, 404, "not_found")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
