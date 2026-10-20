defmodule ApiaryWeb.Contract.Configuration do
  @moduledoc """
  The configuration document of the server contract, version 1, revision 1, and
  its digest: the one place both come from, so the discovery answer and the
  answer to every batch name the same digest.

  The document names the access key's node, node pool or gateway (`node_id`, its public
  id). A node's or a node pool's lists the one workspace it belongs to (`workspaces`, by
  its public id). A gateway's, whether it lives at a workspace or at an organisation,
  lists no workspaces: which workspaces a gateway serves follows from the nodes that use
  it, and Qory Apiary decides at each registration and attach whether it may serve the
  run's workspace (`Apiary.Gateways.may_serve?/2`). The document says where the events
  go, where a run registers and is reloaded (the `run` section,
  `ApiaryWeb.Contract.RegistrationController`), and lists the instance's signing key
  (`apiary_public_key`, `Apiary.SigningKey.apiary_public_key/0`), for information. So the
  document, and its digest, differ by node, and for a node or a node pool by its
  workspace, alone: a gateway's changes only when those members change.
  The `run` section is in every document: a workspace nobody has given a policy answers a
  registration with the document of no policy.

  The members are written in the contract's order: `version`, `node_id`, `workspaces`
  (for a node or a node pool), `events`, `run`, `apiary_public_key`. The run endpoint's
  URL has no trailing slash, query or fragment: a reload appends a slash and the run's id
  to it.
  """

  # With the `factory` and `secrets` features both on, which the documentation leaves
  # out: the document of an access key allowed stored secrets (`allow_secrets`) has
  # `secrets`, `{url}`, the secrets endpoint (`ApiaryWeb.Contract.SecretsController`),
  # after `run`; a key not allowed them, or either feature off, gets none.

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Features
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.SigningKey

  @version 1
  @events_path "/v1/events"
  @run_path "/v1/runs"
  @secrets_path "/v1/secrets"

  @doc "The path of the events endpoint, as the document names it under the public URL."
  def events_path, do: @events_path

  @doc "The path of the run endpoint, as the document names it under the public URL."
  def run_path, do: @run_path

  # The path of the secrets endpoint, as the document lists it under the public URL.
  @doc false
  def secrets_path, do: @secrets_path

  @doc """
  document/1 is the document as sent to `access_key`, the JSON body and its digest. The
  key's node and workspace are loaded with it, as
  `Apiary.AccessKeys.fetch_for_verification/1` loads them; a gateway's key may have no
  workspace.
  """
  @spec document(AccessKey.t()) :: {binary, String.t()}
  def document(%AccessKey{node: %Node{kind: :gateway, public_id: node_id}} = key),
    do: build(%{node_id: node_id}, key)

  def document(
        %AccessKey{
          node: %Node{public_id: node_id},
          workspace: %Workspace{public_id: workspace_id}
        } = key
      ),
      do: build(%{node_id: node_id, workspaces: [workspace_id]}, key)

  defp build(members, key) do
    body =
      members
      |> Map.merge(%{
        url: ApiaryWeb.Endpoint.url(),
        apiary_public_key: SigningKey.apiary_public_key()
      })
      |> Map.merge(if secrets?(key), do: %{secrets: true}, else: %{})
      |> encode()

    {body, digest(body)}
  end

  # Whether the key's document lists the secrets endpoint: both features on, and the key
  # allowed stored secrets.
  defp secrets?(%AccessKey{allow_secrets: true}),
    do: Features.on?(:factory) and Features.on?(:secrets)

  defp secrets?(_key), do: false

  @doc """
  encode/1 is the document's bytes for `node_id`, the `workspaces` it lists, in their
  order, the public `url` the endpoints are under, and the `apiary_public_key` list.
  Without `workspaces`, as for a gateway, the document has no such member.
  """
  @spec encode(%{
          required(:node_id) => String.t(),
          optional(:workspaces) => [String.t(), ...],
          required(:url) => String.t(),
          required(:apiary_public_key) => [map, ...],
          optional(:secrets) => boolean
        }) :: binary
  def encode(%{node_id: node_id, url: url, apiary_public_key: keys} = members) do
    workspaces =
      case members do
        %{workspaces: [_ | _] = workspaces} -> [workspaces: workspaces]
        %{} when not is_map_key(members, :workspaces) -> []
      end

    Jason.encode!(
      Jason.OrderedObject.new(
        [version: @version, node_id: node_id] ++
          workspaces ++
          [
            events: Jason.OrderedObject.new(url: url <> @events_path, types: ["*"]),
            run: Jason.OrderedObject.new(url: url <> @run_path)
          ] ++
          if(members[:secrets],
            do: [secrets: Jason.OrderedObject.new(url: url <> @secrets_path)],
            else: []
          ) ++
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
  With an access key, the digest in force for it: what `X-Qory-Configuration` carries on
  every answer to it. With a document's bytes, their digest.
  """
  @spec digest(AccessKey.t() | binary) :: String.t()
  def digest(%AccessKey{} = access_key), do: access_key |> document() |> elem(1)

  # As the contract states it: `sha256=` and lowercase hex.
  def digest(body) when is_binary(body) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
