defmodule ApiaryWeb.Contract.ConfigurationController do
  @moduledoc """
  The configuration document of the server contract, version 1, revision 1:
  where the events go. The `run` section, where the run configuration is,
  is added when the run configuration exists: a runner refuses to run when a
  section the document names does not answer, and it runs under its machine's
  own policy when the section is absent. Reached only through
  `ApiaryWeb.Contract.SignedRequest`.

  The answer carries `X-Qory-Configuration`, the digest of the document as
  sent, which a runner compares with the digest in later answers and fetches
  the document again when it differs.
  """
  use ApiaryWeb, :controller

  @version 1

  def show(conn, _params) do
    base = ApiaryWeb.Endpoint.url()

    body =
      Jason.encode!(%{
        version: @version,
        events: %{url: base <> "/v1/events", types: ["*"]}
      })

    conn
    |> put_resp_header("x-qory-configuration", digest(body))
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  @doc "The digest of a document as the contract states it: `sha256=` and lowercase hex."
  def digest(body) when is_binary(body) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
