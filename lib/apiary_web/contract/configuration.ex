defmodule ApiaryWeb.Contract.Configuration do
  @moduledoc """
  The configuration document of the server contract, version 1, revision 1, and
  its digest: the one place both come from, so the discovery answer and the
  answer to every batch name the same digest.

  The document names the access key's node or node pool (`node_id`, its public id), says
  where the events go, lists the instance's signing key (`apiary_public_key`,
  `Apiary.SigningKey.apiary_public_key/0`), for information, and, for a workspace whose
  policy somebody has made (`Apiary.Policy.managed?/1`), where the run configuration is
  fetched from in its `run` section (`ApiaryWeb.Contract.RunConfigurationController`). A
  workspace nobody has given a policy is served no `run` section: its machines keep the
  policy of their own `runner.yaml`, and a run under a fetched policy never finds an
  empty one in its place. So the document, and its digest, differ by node and by whether
  the workspace's policy is managed. The first change of a workspace's policy changes
  the digest its answers carry, and a run in flight fetches the document again, finds
  the section and takes the workspace's policy from then on.

  The members are written in the contract's order: `version`, `node_id`, `events`, `run`
  when there is one, `apiary_public_key`.
  """

  alias Apiary.Nodes.Node
  alias Apiary.SigningKey

  @version 1
  @events_path "/v1/events"
  @run_path "/v1/run-configuration"

  @doc "The path of the events endpoint, as the document names it under the public URL."
  def events_path, do: @events_path

  @doc "The path of the run configuration endpoint, as the document names it under the public URL."
  def run_path, do: @run_path

  @doc """
  document/2 is the document as sent to a key of `node`, the JSON body and its digest:
  with the `run` section for a workspace whose policy is managed, without it otherwise.
  """
  @spec document(Node.t(), boolean) :: {binary, String.t()}
  def document(%Node{public_id: node_id}, managed?) when is_boolean(managed?) do
    body =
      encode(%{
        node_id: node_id,
        url: ApiaryWeb.Endpoint.url(),
        apiary_public_key: SigningKey.apiary_public_key(),
        run?: managed?
      })

    {body, digest(body)}
  end

  @doc """
  encode/1 is the document's bytes for `node_id`, the public `url` the endpoints are
  under, the `apiary_public_key` list, and `run?`, whether it has a `run` section.
  """
  @spec encode(%{
          node_id: String.t(),
          url: String.t(),
          apiary_public_key: [map, ...],
          run?: boolean
        }) :: binary
  def encode(%{node_id: node_id, url: url, apiary_public_key: keys, run?: run?}) do
    run = if run?, do: [run: Jason.OrderedObject.new(url: url <> @run_path)], else: []

    Jason.encode!(
      Jason.OrderedObject.new(
        [
          version: @version,
          node_id: node_id,
          events: Jason.OrderedObject.new(url: url <> @events_path, types: ["*"])
        ] ++
          run ++
          [
            apiary_public_key:
              Enum.map(
                keys,
                &Jason.OrderedObject.new(alg: &1["alg"], public_key: &1["public_key"])
              )
          ]
      )
    )
  end

  @doc """
  With a node and a boolean, the digest in force for a key of the node, its workspace's
  policy managed or not: what `X-Qory-Configuration` carries on every answer. With a
  document's bytes, their digest.
  """
  @spec digest(Node.t(), boolean) :: String.t()
  def digest(%Node{} = node, managed?) when is_boolean(managed?),
    do: node |> document(managed?) |> elem(1)

  # As the contract states it: `sha256=` and lowercase hex.
  @spec digest(binary) :: String.t()
  def digest(body) when is_binary(body) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
