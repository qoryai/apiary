defmodule ApiaryWeb.Contract.Configuration do
  @moduledoc """
  The configuration document of the server contract, version 1, revision 1, and
  its digest: the one place both come from, so the discovery answer and the
  answer to every batch name the same digest.

  The document says where the events go. The `run` section, where the run
  configuration is, is added when the run configuration exists: a runner refuses
  to run when a section the document names does not answer, and it runs under
  its machine's own policy when the section is absent.
  """

  @version 1
  @events_path "/v1/events"

  @doc "The path of the events endpoint, as the document names it under the public URL."
  def events_path, do: @events_path

  @doc "The document as sent: the JSON body and its digest."
  def document do
    body =
      Jason.encode!(%{
        version: @version,
        events: %{url: ApiaryWeb.Endpoint.url() <> @events_path, types: ["*"]}
      })

    {body, digest(body)}
  end

  @doc "The digest in force: what `X-Qory-Configuration` carries on every answer."
  def digest, do: document() |> elem(1)

  @doc "The digest of a document as the contract states it: `sha256=` and lowercase hex."
  def digest(body) when is_binary(body) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
