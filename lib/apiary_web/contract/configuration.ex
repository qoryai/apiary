defmodule ApiaryWeb.Contract.Configuration do
  @moduledoc """
  The configuration document of the server contract, version 1, revision 1, and
  its digest: the one place both come from, so the discovery answer and the
  answer to every batch name the same digest.

  The document names the access key's node or node pool (`node_id`, its public id), says
  where the events go, where a run registers and is reloaded (the `run` section,
  `ApiaryWeb.Contract.RegistrationController`), and lists the instance's signing key
  (`apiary_public_key`, `Apiary.SigningKey.apiary_public_key/0`), for information. So the
  document, and its digest, differ by node alone. The `run` section is in every document:
  a workspace nobody has given a policy answers a registration with the document of no
  policy.

  The members are written in the contract's order: `version`, `node_id`, `events`, `run`,
  `apiary_public_key`. The run endpoint's URL has no trailing slash, query or fragment: a
  reload appends a slash and the run's id to it.
  """

  alias Apiary.Nodes.Node
  alias Apiary.SigningKey

  @version 1
  @events_path "/v1/events"
  @run_path "/v1/runs"

  @doc "The path of the events endpoint, as the document names it under the public URL."
  def events_path, do: @events_path

  @doc "The path of the run endpoint, as the document names it under the public URL."
  def run_path, do: @run_path

  @doc """
  document/1 is the document as sent to a key of `node`, the JSON body and its digest.
  """
  @spec document(Node.t()) :: {binary, String.t()}
  def document(%Node{public_id: node_id}) do
    body =
      encode(%{
        node_id: node_id,
        url: ApiaryWeb.Endpoint.url(),
        apiary_public_key: SigningKey.apiary_public_key()
      })

    {body, digest(body)}
  end

  @doc """
  encode/1 is the document's bytes for `node_id`, the public `url` the endpoints are
  under, and the `apiary_public_key` list.
  """
  @spec encode(%{node_id: String.t(), url: String.t(), apiary_public_key: [map, ...]}) ::
          binary
  def encode(%{node_id: node_id, url: url, apiary_public_key: keys}) do
    Jason.encode!(
      Jason.OrderedObject.new(
        version: @version,
        node_id: node_id,
        events: Jason.OrderedObject.new(url: url <> @events_path, types: ["*"]),
        run: Jason.OrderedObject.new(url: url <> @run_path),
        apiary_public_key:
          Enum.map(keys, &Jason.OrderedObject.new(alg: &1["alg"], public_key: &1["public_key"]))
      )
    )
  end

  @doc """
  With a node, the digest in force for a key of the node: what `X-Qory-Configuration`
  carries on every answer. With a document's bytes, their digest.
  """
  @spec digest(Node.t() | binary) :: String.t()
  def digest(%Node{} = node), do: node |> document() |> elem(1)

  # As the contract states it: `sha256=` and lowercase hex.
  def digest(body) when is_binary(body) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
