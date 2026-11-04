defmodule Apiary.Dispatches.Settle do
  @moduledoc false

  # What a run of the queue gave, kept on its row (`Apiary.Dispatches.DispatchRun`,
  # `result_outcome`) once it ended, so a list reads where Explore stands without reading
  # the run's artifacts (`Apiary.WorkItems.Explore`). What it gave is
  # `Apiary.Explore.Outcome.at_end/1`, read from the artifacts the run pushed during the
  # run: `questions`, `proposal` or `none`. No event of the run is read, and `result` is
  # never written.
  #
  # A run that is not a prebuild and ended `run_ended` is settled here; so is one that
  # ended `lost` and left questions that wait for an answer, which then reads as
  # questions: open questions come before a run that stopped. A run whose claim could not
  # form it ends `error` in the same write as its end (`Apiary.Dispatches.Handover`).
  #
  # Three writers, each through `settle_locked/1`, which writes the column only when it
  # differs from what the row holds, and never `updated_at` (`Apiary.WorkItems.Explore`
  # reads it as when a run ended):
  #
  # - the end of the run (`Apiary.Dispatches.RunEnd.finish/5`), in its transaction: once
  #   the run ended, it pushes no artifact (`ApiaryWeb.Contract.RunApi.Run.live?/1`, and
  #   `Apiary.Artifacts.push/5`, which reads the run of the queue again under the work
  #   item's lock that the end holds first), so what it gave is decided;
  # - a projection that folded an exit (`settle/1`, from `Apiary.Runs.Projector`), in a
  #   separate transaction once its passes committed;
  # - the sweep (`sweep/1`, from `Apiary.Runs.Liveness`): a run ended `run_ended` with no
  #   outcome stored, such as one that ended before outcomes were read from artifacts; at
  #   most `@batch` a tick, read through the partial index `dispatch_runs_unsettled_index`,
  #   the rest at the ticks after.
  #
  # A projection whose settle fails clears what the row holds (`clear/1`), so the sweep
  # stores it again.
  #
  # **Locks.** `settle/1` and the sweep lock the run of the queue `FOR UPDATE`, its place
  # in the order every path keeps (`Apiary.Dispatches.RunEnd`), then read the work item's
  # artifacts with no lock. With the workflow model on, the work item is locked
  # `FOR UPDATE` before the run of the queue, since the stage runner writes it
  # (`Apiary.Stages.hold_work_item/1`, `run_ended/2`).
  #
  # **What is told.** Each write is told once its transaction commits, on the topic of
  # the work items of the work item's workspace (`Apiary.WorkItems.topic/1`),
  # `{:work_items_changed, [public_id]}`, through `Apiary.Dispatches.broadcast/1`, which
  # takes the `{:work_item, workspace_id, public_id}` the writers give back.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Dispatches.{DispatchRun, RunEnd}
  alias Apiary.Explore.Outcome
  alias Apiary.Repo
  alias Apiary.WorkItems.WorkItem

  @prebuild DispatchRun.prebuild()
  # The runs of the queue one sweep settles at most; the rest wait for the next.
  @batch 100

  @typedoc "A work item to tell once the transaction commits."
  @type told :: {:work_item, Ecto.UUID.t(), String.t()}

  # settle_locked/1 stores what `dispatch_run`, ended and locked by the caller in its
  # transaction, gave (the moduledoc): the work item to tell once the transaction commits
  # when it wrote, none otherwise.
  @doc false
  @spec settle_locked(DispatchRun.t()) :: [told]
  def settle_locked(%DispatchRun{state: :ended, end_cause: :run_ended, step: step} = dispatch_run)
      when step != @prebuild do
    in_transaction!()
    write(dispatch_run, Outcome.at_end(dispatch_run))
  end

  def settle_locked(%DispatchRun{state: :ended, end_cause: :lost, step: step} = dispatch_run)
      when step != @prebuild do
    in_transaction!()

    case Outcome.at_end(dispatch_run) do
      :questions -> write(dispatch_run, :questions)
      _other -> []
    end
  end

  def settle_locked(%DispatchRun{}), do: []

  defp in_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "a run of the queue settles inside the caller's transaction")
  end

  # settle/1 stores what the run of the queue `dispatch_run_id` gave, in a separate
  # transaction: the run of the queue locked `FOR UPDATE`, then its work item's artifacts
  # read with no lock. The work item to tell once it committed, when it wrote; none
  # otherwise. `now` is not read: it is kept for the callers that give it.
  @doc false
  @spec settle(Ecto.UUID.t(), DateTime.t()) :: [told]
  def settle(dispatch_run_id, _now \\ Apiary.Dispatches.now()) when is_binary(dispatch_run_id) do
    {:ok, told} =
      Repo.transact(fn ->
        # Hand-over: with the workflow model, the stage runner acts on what the run gave
        # (`Apiary.Stages.run_ended/1`), in this transaction. It writes the run's work
        # item, which is locked first, before the run, in the order every path keeps.
        stages? = Apiary.Stages.on?()
        if stages?, do: Apiary.Stages.hold_work_item(dispatch_run_id)

        case RunEnd.lock(dispatch_run_id) do
          %DispatchRun{state: :ended, end_cause: :run_ended} = dispatch_run ->
            told = settle_locked(dispatch_run)
            staged = if stages?, do: Apiary.Stages.run_ended(dispatch_run.id), else: []
            {:ok, told ++ Enum.reject(staged, &(&1 in told))}

          _other ->
            {:ok, []}
        end
      end)

    told
  end

  # sweep/1 settles the runs of the queue ended `run_ended` with no outcome yet: at most
  # `@batch`, in a transaction for each (`settle/1`). One that raises is logged by its id
  # and the exception's module, and the rest are still settled. The work items to tell
  # once each committed. `now` is not read: it is kept for the callers that give it.
  @doc false
  @spec sweep(DateTime.t()) :: [told]
  def sweep(%DateTime{} = now) do
    from(d in DispatchRun,
      # The partial index's predicate, written as it is, so the planner reads through it.
      where: fragment("? = 'run_ended'", d.end_cause),
      where: is_nil(d.result_outcome),
      where: fragment("? <> 'prebuild'", d.step),
      order_by: d.id,
      limit: @batch,
      select: d.id
    )
    |> Repo.all()
    |> Enum.flat_map(&settle_guarded(&1, now))
  end

  # clear/1 clears what the run of the queue `dispatch_run_id`, ended `run_ended` and not
  # a prebuild, holds, in one statement that locks its row alone: for a settle that
  # failed, so the sweep reads it again. The work item to tell when it cleared something;
  # none otherwise.
  @doc false
  @spec clear(Ecto.UUID.t()) :: [told]
  def clear(dispatch_run_id) when is_binary(dispatch_run_id) do
    from(d in DispatchRun,
      where: d.id == ^dispatch_run_id and not is_nil(d.result_outcome),
      where: fragment("? = 'run_ended'", d.end_cause),
      where: fragment("? <> 'prebuild'", d.step),
      select: d.work_item_id
    )
    |> Repo.update_all(set: [result_outcome: nil, result: nil])
    |> case do
      {1, [work_item_id]} -> told(work_item_id)
      {0, []} -> []
    end
  end

  defp settle_guarded(id, now) do
    settle(id, now)
  rescue
    error ->
      Logger.error("run settle failed dispatch_run=#{id} error=#{inspect(error.__struct__)}")
      []
  end

  # The column, and nothing else, when it differs from what the row holds.
  defp write(%DispatchRun{result_outcome: outcome}, outcome), do: []

  defp write(%DispatchRun{id: id, work_item_id: work_item_id}, outcome) do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^id),
        set: [result_outcome: outcome]
      )

    told(work_item_id)
  end

  # told/1 is the work item `work_item_id` to tell once a transaction commits: its
  # workspace and public id as they are now, read with no lock; none for no work item.
  @doc false
  @spec told(Ecto.UUID.t() | nil) :: [told]
  def told(nil), do: []

  def told(work_item_id) do
    case Repo.one(
           from w in WorkItem,
             where: w.id == ^work_item_id,
             select: {w.workspace_id, w.public_id}
         ) do
      {workspace_id, public_id} -> [{:work_item, workspace_id, public_id}]
      nil -> []
    end
  end
end
