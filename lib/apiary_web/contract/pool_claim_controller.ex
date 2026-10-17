defmodule ApiaryWeb.Contract.PoolClaimController do
  @moduledoc false

  # `POST /v1/pools/claim`, with which a node pool's starter claims a run waiting for its
  # pool (the provisioner contract's `claim.schema.json`). Reached only through
  # `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the request
  # under the pool's access key, refuses what comes before the body, and signs the
  # answer. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Dispatches.Wire.claim/1`); a `time` more than 300 seconds from the clock,
  # either way, or a request whose signature was accepted before, is `401`, unsigned
  # (`ApiaryWeb.Contract.AdapterRequest.accept/2`). The claim itself is not served yet:
  # an accepted request is answered as a route the instance does not serve, `404`
  # `not_found`, signed.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.Dispatches.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, claim} <- Wire.claim(body),
         {:ok, conn} <- AdapterRequest.accept(conn, claim.time) do
      refuse(conn, 404, "not_found")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
