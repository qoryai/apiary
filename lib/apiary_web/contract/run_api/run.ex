defmodule ApiaryWeb.Contract.RunApi.Run do
  @moduledoc false

  # The run a request of the run API is made for, as the gateway's access key and the
  # path's run id find it, with the checks a reload and a secrets request make
  # (`Apiary.Runs.SecretsRequest`): a run through the key's gateway
  # (`Apiary.Runs.Sender.run_query/3`), whose run key lists the key, that the key and
  # the request's instance may reload (`Apiary.Runs.Registration.reload_allowed?/3`),
  # of a workspace the gateway may still serve, and a run of a workspace's queue for a
  # work item. Every other case is `{:error, :not_found}`, the same answer whatever the
  # cause.
  #
  # `live?/1` is whether the run may still write: pending or running, and its sending
  # not ended (`Apiary.Runs.Sender.sending_ended?/1`).

  alias Apiary.Repo
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.{Batch, Registration, Run, RunKey, Sender}
  alias Apiary.WorkItems.WorkItem

  @type t :: %{run: Run.t(), dispatch_run: DispatchRun.t(), work_item: WorkItem.t()}

  @spec fetch(AccessKey.t(), term, String.t() | nil) :: {:ok, t} | {:error, :not_found}
  def fetch(%AccessKey{} = access_key, run_id, instance_id) do
    access_key = Repo.preload(access_key, [:node])

    with true <- Batch.uuid?(run_id) || {:error, :not_found},
         %Run{} = run <- Repo.one(Sender.run_query(access_key, run_id)) || {:error, :not_found},
         true <- held?(access_key, run, instance_id) || {:error, :not_found},
         %DispatchRun{work_item_id: work_item_id} = dispatch_run when is_binary(work_item_id) <-
           Repo.get(DispatchRun, run.dispatch_run_id) || {:error, :not_found},
         %WorkItem{} = work_item <- work_item(dispatch_run) || {:error, :not_found} do
      {:ok, %{run: run, dispatch_run: dispatch_run, work_item: work_item}}
    else
      _other -> {:error, :not_found}
    end
  end

  defp held?(access_key, run, instance_id) do
    Run.through_gateway?(run) and is_binary(run.dispatch_run_id) and
      RunKey.lists_key?(run.run_key_payload, access_key.public_key) and
      Registration.reload_allowed?(access_key, run, instance_id) and
      Sender.serves?(run, access_key)
  end

  # The work item of the run of the queue, of the run's workspace, with its workspace.
  defp work_item(%DispatchRun{work_item_id: id, workspace_id: workspace_id}) do
    case Repo.get(WorkItem, id) do
      %WorkItem{workspace_id: ^workspace_id} = work_item -> Repo.preload(work_item, :workspace)
      _other -> nil
    end
  end

  @spec live?(t) :: boolean
  def live?(%{run: %Run{} = run, dispatch_run: %DispatchRun{state: state}}) do
    state != :ended and run.state in Run.alive_states() and not Sender.sending_ended?(run)
  end
end
