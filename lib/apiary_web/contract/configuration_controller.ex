defmodule ApiaryWeb.Contract.ConfigurationController do
  @moduledoc """
  Discovery: the configuration document of the server contract
  (`ApiaryWeb.Contract.Configuration`), reached only through
  `ApiaryWeb.Contract.SignedRequest`, which verifies the request, refuses what the
  contract refuses before the document (a contract revision not served, a stale
  timestamp) and signs the answer. The events URL it names is served by
  `ApiaryWeb.Contract.EventsController`, and the run endpoint's by
  `ApiaryWeb.Contract.RegistrationController`.

  The document names the key's node or node pool, where the events go and where a run
  registers, and lists the instance's signing key; see `ApiaryWeb.Contract.Configuration`.

  The answer carries `X-Qory-Configuration`, the digest of the document as
  sent, which the gateway compares with the digest in later answers and fetches
  the document again when it differs.
  """
  use ApiaryWeb, :controller

  alias ApiaryWeb.Contract.Configuration

  def show(conn, _params) do
    access_key = conn.assigns.access_key
    {body, digest} = Configuration.document(access_key.node)

    conn
    |> put_resp_header("x-qory-configuration", digest)
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  @doc "The digest of a document as the contract states it: `sha256=` and lowercase hex."
  defdelegate digest(body), to: Configuration
end
