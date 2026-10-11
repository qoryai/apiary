defmodule Apiary.Runs.Sender do
  @moduledoc """
  Who may send for a run, and under whose place what is sent for it is read.

  **Batches, heartbeats and reloads** (`batch_sender/3`: `Apiary.Runs.Ingest`;
  `may_send?/3`: `Apiary.Runs.Registration.fetch/3`) are taken from the active keys of one
  node alone, so a key replaced while the run is live keeps it going:

    * a run that goes through a gateway (`Apiary.Runs.Run.through_gateway?/1`): the
      gateway that attached it, `runs.gateway_id` once `attached_at` is set, under any of
      its keys, and from the instance that attached it, `runs.attach_instance_id`, the
      instance id its signed requests carry. Before the attach nobody sends for it, the
      node or node pool that registered it included, and after it no key but the
      gateway's, theirs included, and no other instance of the gateway. A gateway that
      restarts keeps its instance id, and so its run. Once the run's sending has ended
      (`sending_ended?/1`: its `dev.qory.run.exited` arrived, it was lost after its
      attach, or its events were pruned), a batch or heartbeat from any instance of the
      gateway, under any of its keys, is answered as the attaching instance's would be,
      a resend deduplicated; its reloads stay the attaching instance's. After a loss,
      only the attaching instance's heartbeat makes the run live again
      (`Apiary.Runs.Fold.liveness_instance/1`);
    * any other run: the node or node pool it is bound to, `runs.node_id`, the node whose
      key registered it or whose key's batch opened it, fixed from then on.

  A key of any other node may not, whatever its workspace. The node that sends is the one
  whose keys must still verify: a direct run whose node is deleted takes nothing, since no
  key of a deleted node verifies, and nor does a run through a gateway whose gateway is
  deleted or purged; a run through a gateway whose registering node is deleted still
  takes the batches, heartbeats and reloads of the gateway that attached it. A refused
  batch is refused with `refusal/1`'s code.

  **The attaching instance** (`take_instance/2`). A run attached before its instance id
  was kept has none: until one is known, any instance of the gateway sends for it, and
  the next attach, batch or heartbeat the gateway sends for it gives the run its instance
  id, which holds from then on; a reload reads, and gives it none, and so does a batch
  once the run's sending has ended. The id is written under the run's row lock, and only
  while the run has none, so of two instances whose first requests meet, one is the
  attaching instance and the other is refused.

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
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Organisations.Workspace
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}

  @exited "dev.qory.run.exited"

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
  Whether `access_key`, from the instance `instance_id`, may reload `run`: `may_send?/2`,
  and for a run through a gateway the instance that attached it too
  (`attaching_instance?/2`), whether or not the run's sending has ended. Batches and
  heartbeats are `batch_sender/3`'s.
  """
  @spec may_send?(Run.t(), AccessKey.t(), String.t() | nil) :: boolean
  def may_send?(%Run{} = run, %AccessKey{} = access_key, instance_id),
    do: may_send?(run, access_key) and attaching_instance?(run, instance_id)

  @doc """
  Whether `instance_id` is the instance that attached `run`: true for a run through a
  gateway whose attaching instance is not known yet, and for a direct run, which no
  instance holds.
  """
  @spec attaching_instance?(Run.t(), String.t() | nil) :: boolean
  def attaching_instance?(%Run{run_key_payload: payload, attach_instance_id: stored}, instance_id)
      when is_binary(payload),
      do: is_nil(stored) or stored === instance_id

  def attaching_instance?(%Run{}, _instance_id), do: true

  @doc """
  Gives `run`, attached through a gateway, the instance id `instance_id` as its attaching
  instance when it has none yet: called under the run's row lock, by the attach and by
  `batch_sender/3`. The write is conditional on the run having none,
  so of two first requests from different instances one is the attaching instance, and
  the other is `{:error, :other_instance}`. `{:ok, run}` with the run as it is then; a
  run that has its instance, a direct run, and a request with no instance id that can be
  kept are given back as they are.
  """
  @spec take_instance(Run.t(), String.t() | nil) :: {:ok, Run.t()} | {:error, :other_instance}
  def take_instance(
        %Run{attach_instance_id: nil, attached_at: %DateTime{}, run_key_payload: payload} = run,
        instance_id
      )
      when is_binary(payload) do
    if Instance.instance_id?(instance_id) do
      query =
        from r in Run,
          where: r.id == ^run.id and is_nil(r.attach_instance_id) and not is_nil(r.attached_at)

      case Repo.update_all(query, set: [attach_instance_id: instance_id]) do
        {1, _rows} -> {:ok, %{run | attach_instance_id: instance_id}}
        {0, _rows} -> taken(run, instance_id)
      end
    else
      {:ok, run}
    end
  end

  def take_instance(%Run{} = run, _instance_id), do: {:ok, run}

  @doc """
  Who may send `run` a batch or a heartbeat, for `access_key` from the instance
  `instance_id`, read under the run's row lock: `{:ok, run}`, with the run's attaching
  instance taken (`take_instance/2`) when it had none and its sending has not ended, or
  `:refused`, to be answered with `refusal/1`'s code.

  A key `may_send?/2` refuses is refused. For a run through a gateway, the attaching
  instance is taken, and another instance of the gateway is refused while the run's
  sending has not ended (`sending_ended?/1`); once it has, every instance of the gateway
  is taken, and none of them gives the run its instance.
  """
  @spec batch_sender(Run.t(), AccessKey.t(), String.t() | nil) :: {:ok, Run.t()} | :refused
  def batch_sender(%Run{} = run, %AccessKey{} = access_key, instance_id) do
    cond do
      not may_send?(run, access_key) -> :refused
      not Run.through_gateway?(run) -> {:ok, run}
      is_binary(run.attach_instance_id) and run.attach_instance_id === instance_id -> {:ok, run}
      sending_ended?(run) -> {:ok, run}
      is_nil(run.attach_instance_id) -> taken_instance(run, instance_id)
      true -> :refused
    end
  end

  defp taken_instance(run, instance_id) do
    case take_instance(run, instance_id) do
      {:ok, run} -> {:ok, run}
      {:error, :other_instance} -> :refused
    end
  end

  @doc """
  Whether the sending of `run`, through a gateway, has ended: its `dev.qory.run.exited`
  arrived, stored or folded (`exited_at` or `exit_state`); it was lost after its attach;
  or retention pruned its events. What is sent for it after that is a resend, which any
  instance of the gateway that attached it may make. A run whose starter gave its outcome
  has not ended here: its gateway still sends its last events and its exit.
  """
  @spec sending_ended?(Run.t()) :: boolean
  def sending_ended?(%Run{} = run) do
    not is_nil(run.exited_at) or not is_nil(run.exit_state) or
      not is_nil(run.events_pruned_at) or
      (run.state == "lost" and not is_nil(run.attached_at)) or
      Repo.exists?(from e in Event, where: e.run_id == ^run.id and e.type == @exited)
  end

  # Another request wrote the run's instance first: it holds the run, unless it was this
  # same instance's.
  defp taken(run, instance_id) do
    case Repo.one(from r in Run, where: r.id == ^run.id, select: r.attach_instance_id) do
      ^instance_id -> {:ok, %{run | attach_instance_id: instance_id}}
      _other -> {:error, :other_instance}
    end
  end

  @doc """
  The code a batch `batch_sender/3` refuses is refused with: `:wrong_gateway` for a run
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
