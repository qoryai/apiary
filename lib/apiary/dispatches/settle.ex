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
  # Three writers, each through `settle_locked/1`, which writes the column only while the
  # row holds none, and never `updated_at` (`Apiary.WorkItems.Explore` reads it as when a
  # run ended). Once stored, what a run gave stays: a member who answers the questions
  # after the run ended changes the newest questions, and a later writer would read them
  # as what the run gave.
  #
  # - the end of the run (`Apiary.Dispatches.RunEnd.finish/5`), in its transaction: once
  #   the run ended, it pushes no artifact (`ApiaryWeb.Contract.RunApi.Run.live?/1`, and
  #   `Apiary.Artifacts.push/5`, which reads the run of the queue again under the work
  #   item's lock that the end holds first), so what it gave is decided;
  # - a projection that folded an exit (`settle/1`, from `Apiary.Runs.Projector`), in a
  #   separate transaction once its passes committed;
  # - the sweep (`sweep/2`, from `Apiary.Runs.Liveness`): a run ended `run_ended` with no
  #   outcome stored, such as one that ended before outcomes were read from artifacts; at
  #   most `@batch` a tick, read through the partial index `dispatch_runs_unsettled_index`
  #   in the order of their ids, each tick after the last id the tick before read, and
  #   from the first id again once a tick reads fewer than `@batch`. So runs that stay
  #   unsettled at every tick do not keep the runs after them from the sweep.
  #
  # A projection whose settle fails clears what the row holds (`clear/1`), so the sweep
  # stores it again. A run whose newest questions, or whose newest verdict, cannot be read
  # at its end is left with no outcome (`Outcome.at_end/1` is nil), with a warning in the
  # log that has the run's id, so the sweep reads it again; a run that paused at its
  # model keys' limit is left with none and no warning. With the workflow model on,
  # the stage runner raises for the end of the newest run of a running stage
  # (`Apiary.Stages`), so the end's transaction rolls back and the lost-run check ends the
  # run again at a later tick (`Apiary.Dispatches.RunEnd.lose/3`). Any other run ended
  # `lost` is then not settled, since the sweep reads `run_ended` runs alone.
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
  def settle_locked(%DispatchRun{state: :ended, result_outcome: outcome})
      when not is_nil(outcome) do
    in_transaction!()
    []
  end

  def settle_locked(%DispatchRun{state: :ended, end_cause: :run_ended, step: step} = dispatch_run)
      when step != @prebuild do
    in_transaction!()

    case Outcome.at_end(dispatch_run) do
      nil -> if paused?(dispatch_run), do: [], else: unread(dispatch_run)
      outcome -> write(dispatch_run, outcome)
    end
  end

  def settle_locked(%DispatchRun{state: :ended, end_cause: :lost, step: step} = dispatch_run)
      when step != @prebuild do
    in_transaction!()

    case Outcome.at_end(dispatch_run) do
      :questions -> write(dispatch_run, :questions)
      # A lost end, from the lost-run check (`Apiary.Dispatches.RunEnd.lose/3`) or from a
      # machine that stopped (`Apiary.Dispatches.RunEnd.machine_stopped/1`), logs this
      # read. With the workflow model on, the stage runner then reads the questions of the
      # newest run of a running stage again and raises, and the end's caller logs that
      # read in a line of its own.
      nil -> unread(dispatch_run)
      _other -> []
    end
  end

  def settle_locked(%DispatchRun{}), do: []

  # A run that paused at its model keys' limit (`Apiary.Runs.Run.paused?/1`) gave no
  # outcome by design: its continuation gives one, so no warning is written for it.
  defp paused?(%DispatchRun{id: id}) do
    Repo.exists?(
      from r in Apiary.Runs.Run, where: r.dispatch_run_id == ^id and r.state == "paused"
    )
  end

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

  # sweep/1 is `sweep/2` from the first id, its work items alone.
  @doc false
  @spec sweep(DateTime.t()) :: [told]
  def sweep(%DateTime{} = now), do: now |> sweep(nil) |> elem(0)

  # sweep/2 settles the runs of the queue ended `run_ended` with no outcome yet whose id
  # comes after `after`, or from the first for nil: at most `limit`, `@batch` by default,
  # in the order of their ids, in a transaction for each (`settle/1`). One that raises is
  # logged by its id and the exception's module, and the rest are still settled.
  # `{told, next}`: the work items to tell once each committed, and the `after` of the
  # next sweep, the last id read when it read `limit`, nil when it read fewer. `now` is
  # not read: it is kept for the callers that give it.
  @doc false
  @spec sweep(DateTime.t(), Ecto.UUID.t() | nil, pos_integer) :: {[told], Ecto.UUID.t() | nil}
  def sweep(%DateTime{} = now, after_id, limit \\ @batch) do
    ids =
      from(d in DispatchRun,
        # The partial index's predicate, written as it is, so the planner reads through it.
        where: fragment("? = 'run_ended'", d.end_cause),
        where: is_nil(d.result_outcome),
        where: fragment("? <> 'prebuild'", d.step),
        order_by: d.id,
        limit: ^limit,
        select: d.id
      )
      |> after_id(after_id)
      |> Repo.all()

    next = if length(ids) == limit, do: List.last(ids)
    {Enum.flat_map(ids, &settle_guarded(&1, now)), next}
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: from(d in query, where: d.id > ^id)

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

  # A run whose newest questions, or whose newest verdict, cannot be read
  # (`Outcome.at_end/1` is nil): no outcome stored, and a warning with its id, its work
  # item's public id (`wi_…`) and the public id (`av_…`) of the questions version or of
  # the verdict version, so the instance admin finds the file the store cannot read. The
  # warning shows the verdict where the questions can be read and the verdict cannot,
  # read again when the warning is written; the questions otherwise. At most once an hour
  # for each run (`Apiary.Runs.StuckLog`).
  defp unread(%DispatchRun{id: id, work_item_id: work_item_id} = dispatch_run) do
    Apiary.Runs.StuckLog.log(:warning, {:settle, id}, nil, fn ->
      work_item = Repo.get(WorkItem, work_item_id)
      ids = "dispatch_run=#{id} work_item=#{work_item && work_item.public_id}"

      if verdict_unread?(work_item, dispatch_run) do
        version = Apiary.Stages.Artifacts.newest_of_run(dispatch_run, "verdict", "main")

        "run outcome not stored, newest verdict unreadable #{ids} " <>
          "verdict_version=#{version && version.public_id}"
      else
        version = work_item && Apiary.Artifacts.newest(work_item, "questions")

        "run outcome not stored, newest questions unreadable #{ids} " <>
          "questions_version=#{version && version.public_id}"
      end
    end)

    []
  end

  # Whether the newest questions of `work_item` can be read and the verdict of
  # `dispatch_run` cannot (`Apiary.Stages.reported_verdict/1`).
  defp verdict_unread?(%WorkItem{} = work_item, dispatch_run) do
    match?({:ok, _questions}, Apiary.Explore.Questions.current(work_item)) and
      Apiary.Stages.reported_verdict(dispatch_run) == {:error, :store_unavailable}
  end

  defp verdict_unread?(nil, _dispatch_run), do: false

  # The column, and nothing else, on a row that holds none (`settle_locked/1`).
  defp write(%DispatchRun{id: id, work_item_id: work_item_id}, outcome) do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^id),
        set: [result_outcome: outcome]
      )

    Apiary.Runs.StuckLog.clear({:settle, id})
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
