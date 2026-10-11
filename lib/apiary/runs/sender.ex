defmodule Apiary.Runs.Sender do
  @moduledoc """
  Who may send for a run, and under whose place what is sent for it is read.

  **Batches, heartbeats and reloads** (`may_send?/2`: `Apiary.Runs.Ingest`,
  `Apiary.Runs.Registration.fetch/2`) are taken from the active keys of one node alone, so
  a key replaced while the run is live keeps it going:

    * a run that goes through a gateway (`Apiary.Runs.Run.through_gateway?/1`): the
      gateway that attached it, `runs.gateway_id` once `attached_at` is set, under any of
      its keys. Before the attach nobody sends for it, the node or node pool that
      registered it included, and after it no key but the gateway's, theirs included;
    * any other run: the node or node pool it is bound to, `runs.node_id`, the node whose
      key registered it or whose key's batch opened it, fixed from then on.

  A key of any other node may not, whatever its workspace. The node that sends is the one
  whose keys must still verify: a direct run whose node is deleted takes nothing, since no
  key of a deleted node verifies, and nor does a run through a gateway whose gateway is
  deleted or purged; a run through a gateway whose registering node is deleted still
  takes the batches, heartbeats and reloads of the gateway that attached it. A refused
  batch is refused with `refusal/1`'s code.

  **The repeat of a registration and the outcome** (`registered_by?/2`:
  `Apiary.Runs.Registration`, `Apiary.Runs.Outcome`) are taken from the active keys of the
  node or node pool the run is bound to, through a gateway or not: the gateway attaches
  and posts the run's events, and the run's starter, which holds the node's key, gives its
  outcome.

  **The run's place** (`place_key/2`): what is read for a run, its workspace's run
  configuration and its features, is read under the run's own workspace and
  organisation, never the gateway key's: a gateway may serve a workspace other than its
  own.

  The keys that reach here are active: a request is verified only under a key that is not
  revoked, of a node that is not deleted (`Apiary.AccessKeys.fetch_for_verification/1`).

  This is the one place these rules are kept, and every caller follows them.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Repo
  alias Apiary.Runs.Run

  @doc """
  Whether `access_key` may send batches, heartbeats and reloads for `run`: a key of the
  gateway that attached it, for a run through a gateway; a key of the run's own node,
  for any other.
  """
  @spec may_send?(Run.t(), AccessKey.t()) :: boolean
  def may_send?(%Run{run_key_payload: payload} = run, %AccessKey{node_id: node_id})
      when is_binary(payload) do
    case run do
      %Run{gateway_id: ^node_id, attached_at: %DateTime{}} when is_binary(node_id) -> true
      _run -> false
    end
  end

  def may_send?(%Run{node_id: node_id}, %AccessKey{node_id: node_id}) when is_binary(node_id),
    do: true

  def may_send?(_run, _access_key), do: false

  @doc """
  The code a batch `may_send?/2` refuses is refused with: `:wrong_gateway` for a run
  through a gateway, `:wrong_node` for any other.
  """
  @spec refusal(Run.t() | map) :: :wrong_gateway | :wrong_node
  def refusal(run), do: if(Run.through_gateway?(run), do: :wrong_gateway, else: :wrong_node)

  @doc """
  Whether `access_key` is a key of the node or node pool `run` is bound to, through a
  gateway or not: who may repeat its registration and give its outcome.
  """
  @spec registered_by?(Run.t() | map, AccessKey.t()) :: boolean
  def registered_by?(%{node_id: node_id}, %AccessKey{node_id: node_id}) when is_binary(node_id),
    do: true

  def registered_by?(_run, _access_key), do: false

  @doc """
  The query of the run `run_id` as `access_key` names it, its row locked when `lock` is
  given: a gateway's key names a run that goes through it, by the gateway and the run's
  id, wherever the run's workspace is (a run id names at most one run through a
  gateway); any other key a run of its own workspace.
  """
  @spec run_query(AccessKey.t(), Ecto.UUID.t(), keyword) :: Ecto.Query.t()
  def run_query(access_key, run_id, opts \\ [])

  def run_query(%AccessKey{node: %Node{kind: :gateway, id: id}}, run_id, opts) do
    from(r in Run, where: r.gateway_id == ^id and r.run_id == ^run_id) |> lock(opts)
  end

  def run_query(%AccessKey{workspace_id: workspace_id}, run_id, opts) do
    from(r in Run, where: r.workspace_id == ^workspace_id and r.run_id == ^run_id)
    |> lock(opts)
  end

  defp lock(query, opts),
    do: if(opts[:lock], do: Ecto.Query.lock(query, "FOR UPDATE"), else: query)

  @doc """
  The key `run`'s place is read under, for what `access_key` asks of it: `access_key`
  itself for a direct run, whose node is the key's; for a run through a gateway, a key
  that stands for the run's own workspace and organisation, which is never stored and
  signs nothing.
  """
  @spec place_key(Run.t(), AccessKey.t()) :: AccessKey.t()
  def place_key(%Run{} = run, %AccessKey{} = access_key) do
    if Run.through_gateway?(run) do
      %AccessKey{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        workspace: Repo.get!(Workspace, run.workspace_id),
        node_id: run.node_id
      }
    else
      access_key
    end
  end
end
