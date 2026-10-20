defmodule ApiaryWeb.Contract.AdapterController do
  @moduledoc false

  # `POST /v1/adapter`, which an adapter sends each time it starts (the integration
  # contract's `adapter.schema.json`): where a person is sent to connect the source, how
  # often the adapter pulls changes from it, and the description its program prints.
  # Reached only through `ApiaryWeb.Contract.AdapterRequest`, which verifies the request
  # under the adapter's access key, refuses what comes before the body, and signs the
  # answer. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order: a body the contract refuses is `400` `invalid_request`
  # (`Apiary.Adapters.Wire.declaration/1`), one without a `description` or with one the
  # contract refuses included (`Apiary.Integrations.Description.parse/1`); a `time` more
  # than 300 seconds from the clock, either way, or a request whose signature was accepted
  # before, is `401`, unsigned (`ApiaryWeb.Contract.AdapterRequest.accept/2`); then
  # `Apiary.Adapters.declare/2`: a key `Apiary.Access` does not let declare
  # (`adapter.declare`) is `403` `forbidden`, or `404` `not_found` where its adapter is
  # not found to it; else the declaration is stored, with what the description's source
  # role says of its items and its collections, and the answer is `204`, signed, with no
  # body. When it cannot be stored, the answer is `503` `unavailable`. Nothing here logs
  # the body, a header or a signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters
  alias Apiary.Adapters.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @doc false
  def create(conn, _params) do
    with {:ok, declaration} <- Wire.declaration(conn.assigns.raw_body),
         {:ok, conn} <- AdapterRequest.accept(conn, declaration.time),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, _adapter} <- Adapters.declare(scope, declaration) do
      send_resp(conn, 204, "")
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
      {:error, %Ecto.Changeset{}} -> refuse(conn, 400, "invalid_request")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :not_found} -> refuse(conn, 404, "not_found")
    end
  rescue
    exception ->
      Logger.error(
        "an adapter's declaration could not be stored: #{inspect(exception.__struct__)}"
      )

      refuse(conn, 503, "unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
