defmodule ApiaryWeb.Contract.ConfigurationController do
  @moduledoc """
  Discovery: the configuration document of the server contract
  (`ApiaryWeb.Contract.Configuration`), reached only through
  `ApiaryWeb.Contract.SignedRequest`. The events URL it names is served by
  `ApiaryWeb.Contract.EventsController`.

  The answer carries `X-Qory-Configuration`, the digest of the document as
  sent, which a runner compares with the digest in later answers and fetches
  the document again when it differs.
  """
  use ApiaryWeb, :controller

  alias ApiaryWeb.Contract.Configuration

  def show(conn, _params) do
    {body, digest} = Configuration.document()

    conn
    |> put_resp_header("x-qory-configuration", digest)
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  @doc "The digest of a document as the contract states it: `sha256=` and lowercase hex."
  defdelegate digest(body), to: Configuration
end
