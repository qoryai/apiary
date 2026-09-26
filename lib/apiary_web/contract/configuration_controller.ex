defmodule ApiaryWeb.Contract.ConfigurationController do
  @moduledoc """
  Discovery: the configuration document of the server contract
  (`ApiaryWeb.Contract.Configuration`), reached only through
  `ApiaryWeb.Contract.SignedRequest`. The events URL it names is served by
  `ApiaryWeb.Contract.EventsController`.

  The document names the `run` section only for a workspace whose policy somebody has made
  (`Apiary.Policy.managed?/1`); see `ApiaryWeb.Contract.Configuration`.

  The answer carries `X-Qory-Configuration`, the digest of the document as
  sent, which a runner compares with the digest in later answers and fetches
  the document again when it differs.

  A request that verifies but whose `X-Qory-Contract-Version` names no revision served is
  `400` (`ApiaryWeb.Contract.ContractVersion`), and no document is sent.
  """
  use ApiaryWeb, :controller

  alias Apiary.Policy.Serving
  alias ApiaryWeb.Contract.{Configuration, ContractVersion}

  def show(conn, _params) do
    case ContractVersion.fetch(conn) do
      {:ok, _version} ->
        {body, digest} = Configuration.document(Serving.managed?(conn.assigns.access_key))

        conn
        |> put_resp_header("x-qory-configuration", digest)
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      :error ->
        ContractVersion.refuse(conn)
    end
  end

  @doc "The digest of a document as the contract states it: `sha256=` and lowercase hex."
  defdelegate digest(body), to: Configuration
end
