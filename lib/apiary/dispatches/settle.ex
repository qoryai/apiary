defmodule Apiary.Dispatches.Settle do
  @moduledoc false

  # What a run of the queue gave, kept on its row (`Apiary.Dispatches.DispatchRun`,
  # `result_outcome` and `result`) once Qory reads it as decided, so a list reads where
  # Explore stands without reading the runs' events (`Apiary.WorkItems.Explore`).
  #
  # Only a run that is not a prebuild and ended `run_ended` is settled here. What it gave
  # is `Apiary.Explore.Result.given/3`, from the run registered for it and its result
  # event with the highest sequence: a proposal or questions as soon as its result says
  # so, with the result; `none`, `error` or `refused` once the run is settled
  # (`Apiary.Explore.Result.settled?/2`); nothing while it is not. So the row holds what
  # Explore reads from the event: a run not settled whose latest result event gives no
  # verdict, after one that did, has what was stored cleared again, and reads as running
  # until it settles, when the sweep stores what that event gave. A run whose claim
  # could not form it ends `error` in the same write as its end
  # (`Apiary.Dispatches.Handover`), and no other run has an outcome.
  #
  # Three writers, each through `settle_locked/3`, which writes the two columns only when
  # they differ from what the row holds, and never `updated_at` (`Apiary.WorkItems.Explore`
  # reads it as when a run ended):
  #
  # - the end of the run, `run_ended` (`Apiary.Dispatches.RunEnd.finish/5`), in its
  #   transaction: a run whose exit or result came first;
  # - a projection that folded an exit or a result event (`settle/1`, from
  #   `Apiary.Runs.Projector`), in a separate transaction once its passes committed: a run
  #   whose outcome came first, and a result that comes after the run was settled, which
  #   replaces what was stored;
  # - the sweep (`sweep/1`, from `Apiary.Runs.Liveness`): a run with no outcome stored
  #   that has no registered run, or whose registered run has no outcome, or is settled
  #   since by its exit, by the 10 minutes after its outcome, by its loss or by the
  #   pruning of its events; at most `@batch` a tick, read through the partial index
  #   `dispatch_runs_unsettled_index`, the rest at the ticks after.
  #
  # A projection whose settle fails clears what the row holds (`clear/1`), so the sweep
  # stores it again once the run is settled.
  #
  # **Locks.** `settle/1` and the sweep lock the run of the queue `FOR UPDATE`, its place
  # in the order every path keeps (`Apiary.Dispatches.RunEnd`), then read the registered
  # run and its result event with no lock. Nothing else is locked: no work item, counter,
  # environment record or feed counter.
  #
  # **What is told.** Each write is told once its transaction commits, on the topic of
  # the work items of the work item's workspace (`Apiary.WorkItems.topic/1`),
  # `{:work_items_changed, [public_id]}`, through `Apiary.Dispatches.broadcast/1`, which
  # takes the `{:work_item, workspace_id, public_id}` the writers give back.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Dispatches.{DispatchRun, RunEnd}
  alias Apiary.Explore.Result
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}
  alias Apiary.WorkItems.WorkItem

  @prebuild DispatchRun.prebuild()
  # The runs of the queue one sweep settles at most; the rest wait for the next.
  @batch 100

  @typedoc "A work item to tell once the transaction commits."
  @type told :: {:work_item, Ecto.UUID.t(), String.t()}

  # settle_locked/3 stores what `dispatch_run`, ended `run_ended` and locked by the caller
  # in its transaction, gave, from `run`, its registered run or nil, at `now` (the
  # moduledoc): the work item to tell once the transaction commits when it wrote, none
  # otherwise.
  @doc false
  @spec settle_locked(DispatchRun.t(), Run.t() | nil, DateTime.t()) :: [told]
  def settle_locked(
        %DispatchRun{state: :ended, end_cause: :run_ended, step: step} = dispatch_run,
        run,
        %DateTime{} = now
      )
      when step != @prebuild do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "a run of the queue settles inside the caller's transaction")

    case Result.given(run, run && latest_event(run.id), now) do
      :unsettled -> write(dispatch_run, nil, nil)
      {outcome, result} -> write(dispatch_run, outcome, result)
      outcome -> write(dispatch_run, outcome, nil)
    end
  end

  def settle_locked(%DispatchRun{}, _run, %DateTime{}), do: []

  # settle/1 stores what the run of the queue `dispatch_run_id` gave, in a separate
  # transaction: the run of the queue locked `FOR UPDATE`, then its registered run and its
  # result event read with no lock. The work item to tell once it committed, when it
  # wrote; none otherwise.
  @doc false
  @spec settle(Ecto.UUID.t(), DateTime.t()) :: [told]
  def settle(dispatch_run_id, now \\ Apiary.Dispatches.now()) when is_binary(dispatch_run_id) do
    {:ok, told} =
      Repo.transact(fn ->
        case RunEnd.lock(dispatch_run_id) do
          %DispatchRun{state: :ended, end_cause: :run_ended} = dispatch_run ->
            {:ok, settle_locked(dispatch_run, registered(dispatch_run.id), now)}

          _other ->
            {:ok, []}
        end
      end)

    told
  end

  # sweep/1 settles, at `now`, the runs of the queue ended `run_ended` with no outcome yet
  # whose registered run is settled, or that have none: at most `@batch`, in a
  # transaction for each (`settle/1`). One that raises is logged by its id and the
  # exception's module, and the rest are still settled. The work items to tell once each
  # committed.
  @doc false
  @spec sweep(DateTime.t()) :: [told]
  def sweep(%DateTime{} = now) do
    since = DateTime.add(now, -Result.settle_seconds(), :second)

    from(d in DispatchRun,
      left_join: r in Run,
      on: r.dispatch_run_id == d.id,
      # The partial index's predicate, written as it is, so the planner reads through it.
      where: fragment("? = 'run_ended'", d.end_cause),
      where: is_nil(d.result_outcome),
      where: fragment("? <> 'prebuild'", d.step),
      where:
        is_nil(r.id) or not is_nil(r.exit_state) or not is_nil(r.lost_at) or
          r.state == "lost" or not is_nil(r.events_pruned_at) or
          is_nil(r.outcome_received_at) or r.outcome_received_at <= ^since,
      order_by: d.id,
      limit: @batch,
      select: d.id
    )
    |> Repo.all()
    |> Enum.flat_map(&settle_guarded(&1, now))
  end

  # clear/1 clears what the run of the queue `dispatch_run_id`, ended `run_ended` and not
  # a prebuild, holds, both columns, in one statement that locks its row alone: for a
  # settle that failed, so the sweep reads it again. The work item to tell when it
  # cleared something; none otherwise.
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

  defp registered(dispatch_run_id),
    do: Repo.one(from r in Run, where: r.dispatch_run_id == ^dispatch_run_id)

  defp latest_event(run_id) do
    Repo.one(
      from e in Event,
        where: e.run_id == ^run_id and e.type == ^Result.event_type(),
        order_by: [desc: e.sequence],
        limit: 1
    )
  end

  # The two columns, and nothing else, when they differ from what the row holds.
  defp write(%DispatchRun{result_outcome: outcome, result: result}, outcome, result), do: []

  defp write(%DispatchRun{id: id, work_item_id: work_item_id}, outcome, result) do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^id),
        set: [result_outcome: outcome, result: result]
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
