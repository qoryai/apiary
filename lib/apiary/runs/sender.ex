defmodule Apiary.Runs.Sender do
  @moduledoc """
  Who may send for a run: its batches and heartbeats (`Apiary.Runs.Ingest`), its reload
  and the repeat of its registration (`Apiary.Runs.Registration`), and its outcome
  (`Apiary.Runs.Outcome`).

  A run is bound to one node: the node or node pool whose access key registered it, or
  whose key's batch opened it, `runs.node_id`, fixed from then on. Any active key of that
  node may send for the run, so a key replaced while the run is live keeps it going; a key
  of any other node may not, whatever its workspace. A run whose node is gone (`node_id`
  nil) takes nothing from anyone.

  The keys that reach here are active: a request is verified only under a key that is not
  revoked, of a node that is not deleted (`Apiary.AccessKeys.fetch_for_verification/1`).

  This is the one place the rule is kept, and every caller follows it.
  """

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Runs.Run

  @doc "Whether `access_key` may send for `run`: a key of the run's own node."
  @spec may_send?(Run.t() | map, AccessKey.t()) :: boolean
  def may_send?(%{node_id: node_id}, %AccessKey{node_id: node_id}) when is_binary(node_id),
    do: true

  def may_send?(_run, _access_key), do: false
end
