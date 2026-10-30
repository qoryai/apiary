defmodule Apiary.Dispatches.RunEnd do
  @moduledoc false

  # The end of a run of the queue once it was handed over (`Apiary.Dispatches.DispatchRun`,
  # `:handed_over`), with its dispatches and the slot its dispatch holds. The run registered
  # for it (`Apiary.Runs.Run`, whose `dispatch_run_id` names it) ends in one of four ways,
  # a prebuild in one of three, and the first to come decides the end cause:
  #
  # - its exit once folded, whatever its state: `run_ended`, by the projection that folded
  #   it, right after its pass (`run_ended/1`, from `Apiary.Runs.Projector`). A run that
  #   is not a prebuild, ended so, has what it gave stored on the run of the queue in the
  #   same transaction when it is decided already (`Apiary.Dispatches.Settle`), and later
  #   otherwise. No outcome is given to a run of the queue (`Apiary.Runs.Outcome` refuses
  #   one); a run that is not a prebuild and has an outcome given before that rule ends
  #   `run_ended` as by its exit;
  # - its gateway's refusal, once folded (`refused/1`, from `Apiary.Runs.Projector`):
  #   `run_refused`, for a run that is not a prebuild. The run did not start
  #   (`dev.qory.run.refused`), so no retry can help: it is not queued again, and the
  #   refusal's code is kept as `end_detail`. The registered run stays failed with that
  #   code as its reason (`Apiary.Runs.Fold`). A refusal that comes after an exit or any
  #   other end changes nothing, and a prebuild's refusal ends nothing of the queue;
  # - the lost-run check (`lose/1`, from `Apiary.Runs.Liveness`): `lost`, for a run its
  #   gateway never attached by its `attach_by`, or with no exit by its `backstop_at`,
  #   which its attach sets to the attach and `backstop_seconds/1` of its step. The check
  #   marks the registered run lost by its rules first; this ends the run of the queue. It
  #   also ends `lost` an attached run with no exit whose last heartbeat, or its attach
  #   when it has none, is more than `silence_seconds/0` (600) before `now` (**silent**):
  #   with the gateway down, no exit reaches Qory Apiary, and the end frees the slot. A
  #   silent run is lost for good: its state is set `lost` (`lost_at` kept where it has
  #   one) and its `backstop_at` moved back to the end of its silence, so no later
  #   heartbeat or start revives it (`Apiary.Runs.Liveness`), with `silenced_at` set to
  #   when it ended; a run already past its backstop keeps it. It also ends, `run_ended`,
  #   one whose exit came and whose end was not written, should a projection have stopped
  #   between its pass and its end, and, for a run that is not a prebuild, one whose exit
  #   its projection skipped unfolded (`Apiary.Runs.Projector`). A run that is not a
  #   prebuild whose refusal was folded and whose end was not written ends `run_refused`
  #   the same way;
  # - its machine's log, when it arrives before the machine redeemed the run's code
  #   (`machine_stopped/1`, from `Apiary.Dispatches.MachineLogs`): `lost`, as the lost-run
  #   check ends it at the code's expiry, at once. The registered run fails,
  #   `machine_stopped` (`runs.start_failure`), where the check would mark it lost; the
  #   check ends `lost` such a run whose end was not written.
  #
  # A prebuild the check ends `lost` records that end as its last build's failure, on the
  # environment record of its collection and of its pool, the one that claimed it
  # (`Apiary.Environments.record_end_failure/3`): `lost` when its gateway never attached
  # it by its run key's `attach_by`, its machine stopped before it redeemed the run's code
  # or it went silent, `timed_out` when nothing ended it by its backstop.
  # Its run of the queue and its dispatch end `lost` either way. A prebuild its exit ends,
  # `run_ended`, records its last build's failure there too when the exit is `failed` or
  # `lost` (`Apiary.Runs.Fold.exit_state/2`), as that state; any other exit records no
  # failure. The record keeps its last good build. The runs held for the build then go on
  # as `Apiary.Environments.build_failed/6` says: the first loss of the collection's
  # `environment_ref` (`lost`) queues one more prebuild of it for the pool; a failure
  # (`failed` or `timed_out`) or a second loss ends the runs held for it `build_failed`,
  # with the outcome `error`, unless another live pool keeps the image; a prebuild of
  # another pool keeps no run held. A prebuild whose
  # ref is older than the record's image's records no failure
  # (`Apiary.Environments.newer_build?/2`, asked under the record's lock), and ends all
  # the same; so does a prebuild whose reported image is the record's
  # (`Apiary.Environments.built_by?/2`, `Apiary.Dispatches.Built`), as its build is the
  # last good one, whether its report came before its end or comes after it.
  #
  # **An image missing.** A run that is not a prebuild, whose exit is `failed` with the
  # reason `image_missing` and that started in the image its pool's record gave it
  # (`runs.configured_image`), ends `run_ended` as any exit ends it, and then, in the same
  # transaction, the records of the pool that claimed it whose image is that image, built
  # for the run's target, have their build cleared, and a prebuild of each record's
  # collection is queued for the pool where one is due
  # (`Apiary.Environments.forget_image/3`). The next run of its take in is then queued
  # with the attempt total raised by one, so the take in loses no attempt, and waits for
  # that build (`Apiary.Dispatches.requeue_for_image/1`); a run that came from such a
  # requeue ends with no requeue. An end that finds such an exit with that image not held
  # (`hold/1` read the run before the exit was folded) ends nothing; the projection's end
  # or the next check ends it with the image held.
  #
  # The run of the queue ends once: `ended`, with its end cause. Its live dispatch, the one
  # handed over, ends with it with the same cause; a stale dispatch of it not yet ended ends
  # with it, `run_ended`; `ended_at` and `end_cause` are set together. The slot the dispatch
  # took at its claim is freed then, once (`Apiary.Dispatches.Slots.free/2`, which sets
  # `slot_freed_at` only where it is nil). An end after the first changes neither the run
  # of the queue nor its dispatches, and frees nothing again; the registered run still
  # takes what comes as before: a run lost takes its later exit, as any run does.
  #
  # The end by a refusal, as the end by an exit, is written after the projection's pass
  # has committed, in a separate transaction (`refused/1`): the pass holds the registered
  # run, and the run of the queue is locked before it.
  #
  # **Locks.** The lost-run check and a projection's end first hold what `hold/1` holds,
  # from the run of the queue read without a lock, for its columns that never change. For
  # a prebuild (`Apiary.Environments.hold_build/2`), in the order of
  # `Apiary.Dispatches.Slots`: the connections and then the collections of its target
  # that name an `environment_ref` `FOR SHARE`, by id, as a Rebuild holds them; then the
  # work items in Explore whose runs wait for its build `FOR KEY SHARE`, by id; then its
  # environment record `FOR UPDATE`, as a release holds it (`Apiary.Dispatches.Release`):
  # so each of them and a Rebuild take turns at the record, a listing's part that holds a
  # collection `FOR UPDATE` and a close that holds a work item `FOR UPDATE` take turns
  # with the end before the record, and a claim, which takes no held run and holds the
  # collections it queues a build of `FOR SHARE` as well, never waits on the end for a
  # run the end ends. For any other run, its work item
  # `FOR KEY SHARE`, which a release and a close hold `FOR UPDATE` before the run of the
  # queue: so the end and either of them take turns at the work item. A run whose folded
  # exit says its image was missing (**An image missing**) holds more, in the order of
  # `Apiary.Dispatches.Slots`: the connections of the collections whose records keep that
  # image, `FOR SHARE`, by id, then those collections `FOR SHARE`, by id
  # (`Apiary.Environments.hold_missing/3`), as a Rebuild holds them; then its work item
  # `FOR UPDATE`, as `Apiary.Dispatches.queue_next/2` holds it before it reads the take
  # in's runs, since the end inserts the next run of the take in; then those records
  # `FOR UPDATE` (`Apiary.Environments.lock_missing/3`). The prebuild it queues inserts a
  # run of the queue whose foreign key takes `FOR KEY SHARE` on its collection, which the
  # end then holds already: a listing's part or an assign, which holds its collections
  # `FOR UPDATE`, waits for the end at the connection or at the collection, and never
  # holds what the end waits for. A release, a close or a next run of the work item waits
  # for the end at the work item. For any other run, `FOR KEY SHARE` is enough on the
  # work item: the end writes no work item and inserts no run of it, it only writes the
  # run of the queue, and a release or a close still waits for it there with its
  # `FOR UPDATE`.
  # An end by an exit writes the run of the queue a second time when the result it
  # stores differs from the one the row has (`settled/4`, `Apiary.Dispatches.Settle`,
  # which skips equal values), and Postgres then checks that write's foreign key with a
  # `FOR KEY SHARE` lock on the work item. Taken there alone, after the run of the
  # queue, that lock waits on a release that holds the work item and waits on the run of
  # the queue: a deadlock (40P01). Then the run of the queue is locked `FOR UPDATE`, then
  # the registered run, then the dispatches are written. `refused/1` holds nothing
  # first: it writes the run of the queue once.
  # Every path that locks a run of the queue together with its dispatches or its
  # registered run locks the run of the queue first (`Apiary.Dispatches.Slots`), so two
  # ends of one run take turns there and the second finds it ended. A projection and an
  # attach lock the registered run and nothing of the queue, so an end that waits for one
  # of them is never waited for by it. A caller that locks anything of the run of the
  # queue before it calls here locks the run of the queue first.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Dispatches, Environments, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Settle, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Event, Run}
  alias Apiary.WorkItems.WorkItem

  @typedoc false
  @type held_missing :: {:image_missing, [Record.t()], [Apiary.Adapters.Collection.t()]}
  @typedoc false
  @type held_build ::
          {:build, Record.t() | nil, [Apiary.Adapters.Collection.t()], [Ecto.UUID.t()]}

  @prebuild DispatchRun.prebuild()
  # The reason of a run's exit whose image the registry does not have.
  @image_missing "image_missing"

  # The seconds from its attach by which a run of each step has its exit, or is lost:
  # Explore's 24 hours and 15 minutes, the longest time limit (1440 minutes,
  # `Apiary.TimeLimits`) and a margin, and a prebuild's 1 hour and 15 minutes, within the
  # 90 minutes its claim lets its machine live (`ApiaryWeb.Contract.PoolClaimController`).
  # A step not named here has Explore's.
  @backstops %{"explore" => 87_300, "prebuild" => 4500}
  @default_backstop 87_300
  # The seconds without a heartbeat after which an attached run with no exit is lost for
  # good, and its dispatch ends.
  @silence 600
  @exited "dev.qory.run.exited"
  @heartbeat "dev.qory.run.heartbeat"
  # The runs of the queue one check looks at at most; the rest wait for the next.
  @batch 100

  # backstop_seconds/1 is the seconds after its attach by which a run of `step` has its
  # exit, or is lost.
  @doc false
  @spec backstop_seconds(String.t() | nil) :: pos_integer
  def backstop_seconds(step), do: Map.get(@backstops, step, @default_backstop)

  # silence_seconds/0 is the seconds without a heartbeat after which an attached run with
  # no exit is lost for good (the moduledoc).
  @doc false
  @spec silence_seconds() :: pos_integer
  def silence_seconds, do: @silence

  # lock/1 locks the run of the queue `id` `FOR UPDATE`, inside the caller's transaction:
  # the row, or nil for none.
  @doc false
  @spec lock(Ecto.UUID.t() | nil) :: DispatchRun.t() | nil
  def lock(nil), do: nil

  def lock(id) when is_binary(id) do
    in_transaction!()
    Repo.one(from d in DispatchRun, where: d.id == ^id, lock: "FOR UPDATE")
  end

  # hold/1 locks what an end of the run of the queue `dispatch_run_id` locks before the
  # run of the queue, inside the caller's transaction, from the run of the queue read
  # without a lock, for its columns that never change. For a prebuild, what
  # `Apiary.Environments.hold_build/2` holds: the collections of its target `FOR SHARE`,
  # the work items whose runs wait for its build `FOR KEY SHARE`, then its environment
  # record `FOR UPDATE`, returned as `{:build, record, collections, work_item_ids}`. For
  # any other run, its work item `FOR KEY SHARE`, and nil returned: an end
  # that writes the run of the queue twice in its transaction makes Postgres check
  # `dispatch_runs_work_item_id_fkey` again at the second write, with that same lock on
  # the work item, which then comes after the run of the queue unless taken here. For
  # such a run whose folded exit says its image was missing (`missing/1`), the
  # collections of the records of that image `FOR SHARE` after their connections
  # (`Apiary.Environments.hold_missing/3`), then its work item `FOR UPDATE`, then
  # those records `FOR UPDATE` (`Apiary.Environments.lock_missing/3`), returned as
  # `{:image_missing, records, collections}`; both empty when the run's pool or target is
  # not found. A prebuild has no work item (`dispatch_runs_step_shape_check`). nil for no
  # run.
  @doc false
  @spec hold(Ecto.UUID.t() | nil) :: held_build | held_missing | nil
  def hold(nil), do: nil

  def hold(dispatch_run_id) when is_binary(dispatch_run_id) do
    in_transaction!()

    from(d in DispatchRun,
      where: d.id == ^dispatch_run_id,
      select: {d.step, d.pool_id, d.source_collection_id, d.work_item_id}
    )
    |> Repo.one()
    |> case do
      {@prebuild, pool_id, collection_id, nil}
      when is_binary(pool_id) and is_binary(collection_id) ->
        Environments.hold_build(pool_id, collection_id)

      {_step, _pool_id, _collection_id, work_item_id} when is_binary(work_item_id) ->
        case missing(dispatch_run_id) do
          nil ->
            :ok = share_work_item(work_item_id)
            nil

          :unknown ->
            :ok = lock_work_item(work_item_id)
            {:image_missing, [], []}

          %{pool_id: pool_id, target: target, image: image} ->
            collections = Environments.hold_missing(pool_id, target, image)
            :ok = lock_work_item(work_item_id)
            {:image_missing, Environments.lock_missing(pool_id, target, image), collections}
        end

      _other ->
        nil
    end
  end

  defp share_work_item(work_item_id) do
    _id =
      Repo.one(
        from w in WorkItem, where: w.id == ^work_item_id, select: w.id, lock: "FOR KEY SHARE"
      )

    :ok
  end

  # The work item of a run whose image was missing, `FOR UPDATE`, as
  # `Apiary.Dispatches.queue_next/2` holds it: its end may queue the next run of the take
  # in (`Apiary.Dispatches.requeue_for_image/1`).
  defp lock_work_item(work_item_id) do
    _id =
      Repo.one(from w in WorkItem, where: w.id == ^work_item_id, select: w.id, lock: "FOR UPDATE")

    :ok
  end

  # finish/5 ends `dispatch_run`, locked by `lock/1` in the caller's transaction, with
  # `cause`, when it is still handed over and `run` is its registered run, locked after it,
  # and, for a prebuild that ends `lost` or by a `failed` or `lost` exit, records its last
  # build as failed on the record of `held`, what `hold/1` held before, then queues the
  # build once more or ends the runs held for it (the moduledoc). Ended `run_ended`, what
  # the run gave is stored when it is decided already (`Apiary.Dispatches.Settle`); a run
  # whose exit says its image was missing, with `held` `{:image_missing, records,
  # collections}`, then has that image cleared, its build queued and the next run of its
  # take in queued (the moduledoc). Such a run whose image `hold/1` did not hold ends
  # nothing. The ids of the workspaces whose slots or queue changed, and the work items
  # to tell, for the caller to tell once its transaction commits
  # (`Apiary.Dispatches.broadcast/1`); none otherwise.
  @doc false
  @spec finish(
          DispatchRun.t() | nil,
          Run.t(),
          atom,
          DateTime.t(),
          held_build | held_missing | nil
        ) ::
          [Ecto.UUID.t() | Settle.told()]
  def finish(
        %DispatchRun{state: :handed_over, id: id} = dispatch_run,
        %Run{dispatch_run_id: id} = run,
        cause,
        %DateTime{} = now,
        held
      ) do
    in_transaction!()

    if missing_unheld?(dispatch_run, run, held) do
      []
    else
      changed = end_locked(dispatch_run, cause, now, detail(cause, run))
      built = build_ended(held, dispatch_run, cause, run, now)
      settled = settled(dispatch_run, run, cause, now)
      changed ++ built ++ settled ++ image_missing(held, dispatch_run, run, cause, now)
    end
  end

  def finish(_dispatch_run, %Run{}, _cause, %DateTime{}, _held), do: []

  defp settled(dispatch_run, run, :run_ended, now),
    do: Settle.settle_locked(%{dispatch_run | state: :ended, end_cause: :run_ended}, run, now)

  defp settled(%DispatchRun{work_item_id: work_item_id}, _run, :run_refused, _now),
    do: Settle.told(work_item_id)

  defp settled(_dispatch_run, _run, _cause, _now), do: []

  # A run that is not a prebuild whose locked registered run says its image was missing,
  # while `held` is not what `hold/1` holds for such a run: `hold/1` read the run before
  # its exit was folded, and neither that image's records nor their collections are
  # held.
  defp missing_unheld?(%DispatchRun{step: @prebuild}, _run, _held), do: false
  defp missing_unheld?(_dispatch_run, _run, {:image_missing, _records, _collections}), do: false

  defp missing_unheld?(_dispatch_run, %Run{} = run, _held), do: missing_exit?(run)

  defp missing_exit?(%Run{
         exit_state: "failed",
         exit_reason: @image_missing,
         configured_image: image
       }),
       do: is_binary(image)

  defp missing_exit?(%Run{}), do: false

  # A run that is not a prebuild ended by its exit, `failed` with the reason
  # `image_missing`, whose records and collections `hold/1` held: that image cleared, a
  # build queued, and the next run of its take in queued with one more attempt, unless
  # the run came from such a requeue (the moduledoc). The workspaces whose queue changed,
  # and the work item to tell.
  defp image_missing(
         {:image_missing, records, collections},
         %DispatchRun{} = dispatch_run,
         %Run{} = run,
         :run_ended,
         now
       ) do
    if missing_exit?(run) do
      queued = Enum.map(Environments.forget_image(records, collections, now), & &1.workspace_id)

      case Dispatches.requeue_for_image(dispatch_run) do
        {:ok, next} -> queued ++ [next.workspace_id | Settle.told(next.work_item_id)]
        {:error, _not_requeued} -> queued
      end
    else
      []
    end
  end

  defp image_missing(_held, _dispatch_run, _run, _cause, _now), do: []

  # For the run of the queue `dispatch_run_id`, read without a lock, when its registered
  # run's folded exit is `failed` with the reason `image_missing` and it started in the
  # image its pool's record gave it: the pool that claimed it, from its dispatch handed
  # over, the run's target, read from its registration labels by its workspace's domain
  # (`Apiary.Lingo.Domain.target/2`), and that image; `:unknown` when the pool or the
  # target is not found. nil otherwise.
  defp missing(dispatch_run_id) do
    from(r in Run,
      left_join: d in Dispatch,
      on: d.dispatch_run_id == r.dispatch_run_id and not is_nil(d.handed_over_at),
      where: r.dispatch_run_id == ^dispatch_run_id,
      where: r.exit_state == "failed" and r.exit_reason == ^@image_missing,
      where: not is_nil(r.configured_image),
      order_by: [desc_nulls_last: d.handed_over_at],
      limit: 1,
      select: {d.pool_id, r.workspace_id, r.registration_labels, r.configured_image}
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      {pool_id, workspace_id, labels, image} when is_binary(pool_id) ->
        case Domain.target(Repo.get(Workspace, workspace_id), labels) do
          {:ok, target} -> %{pool_id: pool_id, target: target, image: image}
          :none -> :unknown
        end

      _no_pool ->
        :unknown
    end
  end

  # The refusal's code, which the fold kept as the run's reason (`Apiary.Runs.Fold`); nil
  # for any other cause.
  defp detail(:run_refused, %Run{reason: reason}), do: reason
  defp detail(_cause, _run), do: nil

  # run_ended/1 ends the run of the queue of `run`, `run_ended`, once a projection folded
  # its exit, in a separate transaction: the ids of the workspaces whose slots changed,
  # and the work item whose run settled, for the caller to tell
  # (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec run_ended(Run.t()) :: [Ecto.UUID.t() | Settle.told()]
  def run_ended(%Run{id: run_id, dispatch_run_id: dispatch_run_id})
      when is_binary(dispatch_run_id) do
    {:ok, changed} =
      Repo.transact(fn ->
        held = hold(dispatch_run_id)

        with %DispatchRun{state: :handed_over} = dispatch_run <- lock(dispatch_run_id),
             %Run{} = run <- locked_run(run_id),
             true <- ends?(dispatch_run, run) do
          {:ok, finish(dispatch_run, run, :run_ended, now(), held)}
        else
          _not_ended -> {:ok, []}
        end
      end)

    changed
  end

  def run_ended(%Run{}), do: []

  # refused/1 ends the run of the queue of `run`, a run that is not a prebuild whose
  # projection folded a refusal, `run_refused`, in a separate transaction: the run of the
  # queue locked first, then the registered run. It changes nothing when the run of the
  # queue is not handed over any more, or when an exit came, stored or folded, which ends
  # it `run_ended`. The ids of the workspaces whose slots changed, and the
  # work item whose run ended, for the caller to tell (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec refused(Run.t()) :: [Ecto.UUID.t() | Settle.told()]
  def refused(%Run{id: run_id, dispatch_run_id: dispatch_run_id})
      when is_binary(dispatch_run_id) do
    {:ok, changed} =
      Repo.transact(fn ->
        with %DispatchRun{state: :handed_over, step: step} = dispatch_run when step != @prebuild <-
               lock(dispatch_run_id),
             %Run{} = run <- locked_run(run_id),
             true <- refused?(run) do
          {:ok, finish(dispatch_run, run, :run_refused, now(), nil)}
        else
          _not_ended -> {:ok, []}
        end
      end)

    changed
  end

  def refused(%Run{}), do: []

  # machine_stopped/1 ends at once, once the machine log of `dispatch` arrived
  # (`Apiary.Dispatches.MachineLogs.upload/3`), the run the dispatch was handed over for
  # whose machine never redeemed the run's code: still `pending`, never attached, its
  # code unredeemed, with no exit, refusal, outcome or release. The registered run fails,
  # `machine_stopped` (`start_failure`), with the dispatch as its `dispatch_id`, and the
  # run of the queue and the dispatch end `lost`, as the lost-run check ends them at the
  # code's expiry (`lose/1`), with what that end does for a prebuild's build. In a
  # separate transaction, the run of the queue locked first, then the registered run.
  # Nothing changes for a dispatch not handed over, of a run of the queue not handed over
  # any more, or of a run that redeemed its code. The ids of the workspaces whose slots
  # changed, for the caller to tell (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec machine_stopped(Dispatch.t()) :: [Ecto.UUID.t() | Settle.told()]
  def machine_stopped(%Dispatch{
        id: dispatch_id,
        dispatch_run_id: id,
        handed_over_at: %DateTime{}
      }) do
    {:ok, {changed, failed}} =
      Repo.transact(fn ->
        held = hold(id)
        now = now()

        with %DispatchRun{state: :handed_over} = dispatch_run <- lock(id),
             %Run{} = run <-
               Repo.one(from r in Run, where: r.dispatch_run_id == ^id, lock: "FOR UPDATE"),
             true <- unstarted?(run) do
          failed =
            run
            |> Ecto.Changeset.change(
              state: "failed",
              reason: "machine_stopped",
              lost_at: nil,
              start_failure: "machine_stopped",
              start_failed_at: now,
              dispatch_id: dispatch_id,
              updated_at: now
            )
            |> Repo.update!()

          {:ok, {finish(dispatch_run, failed, :lost, now, held), failed}}
        else
          _started_or_ended -> {:ok, {[], nil}}
        end
      end)

    if failed, do: Apiary.Runs.broadcast_changed(failed)
    changed
  end

  def machine_stopped(%Dispatch{}), do: []

  # A registered run through a gateway whose code was never redeemed, that never
  # attached, and that has no exit, refusal, outcome, release or start failure.
  defp unstarted?(%Run{} = run) do
    run.state == "pending" and is_nil(run.attached_at) and not is_nil(run.run_code_sha256) and
      is_nil(run.run_code_public_key) and is_nil(run.start_failure) and
      is_nil(run.released_at) and not outcome_or_exit?(run) and is_nil(run.refused_at)
  end

  # lose/1 ends, at `now`, the runs of the queue handed over whose registered run its
  # gateway never attached by its `attach_by`, or that has no exit by its `backstop_at`,
  # or that is silent (`lost`), or whose exit came and whose end was not written
  # (`run_ended`), or whose refusal was folded and whose end was not written
  # (`run_refused`): at most `@batch`, each in a separate transaction. One that
  # raises is logged by its id and the exception's module, and the rest are still ended.
  # The ids of the workspaces whose slots changed, and the work items whose run settled,
  # for the caller to tell (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec lose(DateTime.t()) :: [Ecto.UUID.t() | Settle.told()]
  def lose(%DateTime{} = now) do
    from(d in DispatchRun,
      join: r in Run,
      on: r.dispatch_run_id == d.id,
      where: fragment("? = 'handed_over'", d.state),
      where:
        (d.step != ^@prebuild and
           (not is_nil(r.outcome_state) or not is_nil(r.exited_at) or not is_nil(r.exit_state) or
              not is_nil(r.refused_at))) or
          (d.step == ^@prebuild and (not is_nil(r.exited_at) or not is_nil(r.exit_state))) or
          not is_nil(r.released_at) or not is_nil(r.start_failure) or
          (is_nil(r.attached_at) and r.attach_by < ^now) or
          r.backstop_at < ^now or
          (not is_nil(r.attached_at) and is_nil(r.exited_at) and is_nil(r.exit_state) and
             fragment(
               "GREATEST(?, ?) + make_interval(secs => ?) < ?",
               r.last_heartbeat_at,
               r.attached_at,
               @silence,
               ^now
             )),
      order_by: d.id,
      limit: @batch,
      select: d.id
    )
    |> Repo.all()
    |> Enum.flat_map(&lose_guarded(&1, now))
    |> Enum.uniq()
  end

  # A silent run lost for good is broadcast as changed once its end commits.
  defp lose_guarded(id, now) do
    {:ok, {changed, silenced}} = Repo.transact(fn -> {:ok, lose_one(id, now)} end)
    if silenced, do: Apiary.Runs.broadcast_changed(silenced)
    changed
  rescue
    error ->
      Logger.error("run end failed dispatch_run=#{id} error=#{inspect(error.__struct__)}")
      []
  end

  # The rules again, under the locks: an exit that came meanwhile ends it as its run's
  # end, and an attach that came meanwhile leaves it to its backstop. A
  # prebuild's record is held first, and a prebuild lost records its build as failed.
  # A silent run is lost for good first (`silenced/2`), and returned beside the ids.
  defp lose_one(id, now) do
    held = hold(id)

    with %DispatchRun{state: :handed_over} = dispatch_run <- lock(id),
         %Run{} = run <-
           Repo.one(from r in Run, where: r.dispatch_run_id == ^id, lock: "FOR UPDATE"),
         cause when not is_nil(cause) <- cause(dispatch_run, run, now) do
      silenced = if cause == :lost and silent?(run, now), do: silenced(run, now)
      {finish(dispatch_run, run, cause, now, held), silenced}
    else
      _nothing -> {[], nil}
    end
  end

  # An attached run with no exit whose last heartbeat, or its attach when it has none, is
  # more than `@silence` seconds before `now`, counting the heartbeats stored and not yet
  # folded (`heard/1`): a heartbeat that arrived in time keeps the run, though its
  # projection has not run yet.
  defp silent?(
         %Run{attached_at: %DateTime{} = attached_at, exited_at: nil, exit_state: nil} = run,
         now
       ),
       do:
         past?(DateTime.add(last_heard(run, attached_at), @silence, :second), now) and
           past?(DateTime.add(heard(run), @silence, :second), now)

  defp silent?(%Run{}, _now), do: false

  defp last_heard(%Run{last_heartbeat_at: %DateTime{} = beat}, attached_at),
    do: later(beat, attached_at)

  defp last_heard(%Run{}, attached_at), do: attached_at

  # When the run was last heard, its heartbeats not yet folded counted by their arrival:
  # the latest of its folded last heartbeat, its attach and the arrival of a heartbeat
  # stored and not yet projected. Such a heartbeat counts whichever instance sent it; its
  # projection, within seconds, folds it or leaves it out (`Apiary.Runs.Fold`), and the
  # next check reads the folded heartbeat.
  defp heard(%Run{id: id, attached_at: attached_at} = run) do
    folded = last_heard(run, attached_at)

    case Repo.one(
           from e in Event,
             where: e.run_id == ^id and is_nil(e.projected_at) and e.type == @heartbeat,
             select: max(e.received_at)
         ) do
      %DateTime{} = arrived -> later(arrived, folded)
      nil -> folded
    end
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  # The silent run lost for good: `lost`, with the `lost_at` it has or `now`, and its
  # `backstop_at` moved back to the end of its silence, which no later heartbeat or start
  # passes (`Apiary.Runs.Liveness.past_backstop?/2`). `silenced_at` is set to `now` only
  # when the silence ended before that deadline, which then moves: a run past the
  # deadline its attach set ended there.
  defp silenced(%Run{} = run, now) do
    silence_end = DateTime.add(heard(run), @silence, :second)

    moved =
      if past?(run.backstop_at, silence_end),
        do: [],
        else: [backstop_at: silence_end, silenced_at: now]

    changes =
      if run.state in ["pending", "running"],
        do: [state: "lost", lost_at: now],
        else: []

    run
    |> Ecto.Changeset.change([updated_at: now] ++ moved ++ changes)
    |> Repo.update!()
  end

  # A prebuild lost: its build failed, `lost` at its run key's `attach_by`, never
  # attached, once its machine stopped before it redeemed the run's code, or once silent,
  # else `timed_out` at its backstop. A prebuild its exit
  # ended: its build failed, `failed` or `lost` as its exit, when the exit is one of those
  # two; any other exit records nothing. The last good build kept either way; the runs
  # held for the build go on as `Apiary.Environments.build_failed/6` says. A prebuild
  # whose ref is older than the record's image's, or whose reported image is the
  # record's, records nothing.
  defp build_ended(
         {:build, %Record{} = record, collections, work_item_ids},
         %DispatchRun{step: @prebuild} = dispatch_run,
         cause,
         %Run{} = run,
         now
       )
       when cause in [:lost, :run_ended] do
    case failure(cause, run, now) do
      nil ->
        []

      failure ->
        if Environments.newer_build?(record, dispatch_run) or
             Environments.built_by?(record, dispatch_run) do
          []
        else
          :ok = Environments.record_end_failure(record, failure, now)
          held = %{record | failure_cause: failure}

          Environments.build_failed(held, dispatch_run, failure, collections, work_item_ids, now)
        end
    end
  end

  defp build_ended(_held, _dispatch_run, _cause, %Run{}, _now), do: []

  defp failure(:run_ended, %Run{exit_state: "failed"}, _now), do: :failed
  defp failure(:run_ended, %Run{exit_state: "lost"}, _now), do: :lost
  defp failure(:run_ended, _run, _now), do: nil

  defp failure(:lost, run, now),
    do:
      if(stopped?(run) or unattached_past?(run, now) or silent?(run, now),
        do: :lost,
        else: :timed_out
      )

  # A prebuild ends by its exit, whatever its state, a release recorded on its registered
  # run (`released_at`, which only a release before a release after the handover was
  # refused wrote), or its attach_by, its backstop, or its silence before an exit.
  defp cause(%DispatchRun{step: @prebuild}, run, now) do
    cond do
      exited?(run) -> :run_ended
      not is_nil(run.released_at) -> :released
      stopped?(run) -> :lost
      unattached_past?(run, now) or past?(run.backstop_at, now) or silent?(run, now) -> :lost
      true -> nil
    end
  end

  defp cause(%DispatchRun{}, run, now) do
    cond do
      outcome_or_exit?(run) -> :run_ended
      not is_nil(run.released_at) -> :released
      refused?(run) -> :run_refused
      stopped?(run) -> :lost
      true -> by_exit(exit_stored(run), run, now)
    end
  end

  # What ends the run of the queue as its registered run's end once a projection folded an
  # exit: its exit, or, for a run that is not a prebuild, an outcome given before a run of
  # the queue was refused one.
  defp ends?(%DispatchRun{step: @prebuild}, %Run{} = run), do: exited?(run)

  defp ends?(%DispatchRun{}, %Run{} = run), do: outcome_or_exit?(run)

  # A refusal folded, and no exit, stored or folded, when the run of the queue is locked:
  # the refusal ends the run of the queue. An exit that comes after the fold and before
  # that end decides over the refusal, and the run ends
  # `run_ended`; an exit stored and not yet projected ends it when its projection folds it.
  defp refused?(%Run{} = run),
    do: not is_nil(run.refused_at) and not outcome_or_exit?(run) and is_nil(exit_stored(run))

  # An exit stored and not yet projected: its projection ends the run as its exit. One
  # projected that its fold did not take, skipped by its projection (`Apiary.Runs.Projector`):
  # it came first, so it ends the run of the queue as its exit, and no projection will.
  defp by_exit(:unprojected, _run, _now), do: nil
  defp by_exit(:projected, _run, _now), do: :run_ended

  defp by_exit(nil, run, now),
    do:
      if(unattached_past?(run, now) or past?(run.backstop_at, now) or silent?(run, now),
        do: :lost
      )

  # An exit folded onto the run, whatever its state.
  defp exited?(%Run{} = run), do: not is_nil(run.exited_at) or not is_nil(run.exit_state)

  # An exit, or an outcome given before a run of the queue was refused one.
  defp outcome_or_exit?(%Run{} = run),
    do: not is_nil(run.outcome_state) or not is_nil(run.exited_at) or not is_nil(run.exit_state)

  # :unprojected for an exit stored and not yet projected, :projected for one projected
  # only, nil for none.
  defp exit_stored(%Run{id: id}) do
    from(e in Event,
      where: e.run_id == ^id and e.type == @exited,
      select: is_nil(e.projected_at)
    )
    |> Repo.all()
    |> case do
      [] -> nil
      unprojected -> if true in unprojected, do: :unprojected, else: :projected
    end
  end

  # Its machine stopped before it redeemed the run's code (`machine_stopped/1`).
  defp stopped?(%Run{start_failure: "machine_stopped"}), do: true
  defp stopped?(%Run{}), do: false

  defp unattached_past?(%Run{attached_at: nil, attach_by: attach_by}, now),
    do: past?(attach_by, now)

  defp unattached_past?(%Run{}, _now), do: false

  # At or before `now` is not past: as the lost-run check and the attach window have it.
  defp past?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :lt
  defp past?(nil, _now), do: false

  defp locked_run(id), do: Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")

  # The run of the queue ended with `cause`, and `detail` kept on it, its live dispatch
  # with the cause, a stale one not yet ended `run_ended`, and the slot freed once.
  defp end_locked(%DispatchRun{id: id}, cause, now, detail) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id),
        set: [state: :ended, end_cause: cause, end_detail: detail, updated_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^id,
          where: is_nil(d.ended_at) and is_nil(d.stale_at) and not is_nil(d.handed_over_at)
        ),
        set: [ended_at: now, end_cause: cause, updated_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^id,
          where: is_nil(d.ended_at) and not is_nil(d.stale_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    Slots.free({:runs, [id]}, now)
  end

  defp now, do: Apiary.Dispatches.now()

  defp in_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "a run of the queue ends inside the caller's transaction")
  end
end
