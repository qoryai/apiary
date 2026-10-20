defmodule Apiary.Dispatches.RunEnd do
  @moduledoc false

  # The end of a run of the queue once it was handed over (`Apiary.Dispatches.DispatchRun`,
  # `:handed_over`), with its dispatches and the slot its dispatch holds. The run registered
  # for it (`Apiary.Runs.Run`, whose `dispatch_run_id` names it) ends in one of four ways,
  # a prebuild in one of four, and the first to come decides the end cause:
  #
  # - its starter's outcome, or its exit once folded: `run_ended`. The outcome's write ends
  #   it in its transaction (`hold/1`, `lock/1`, then `finish/5`, from
  #   `Apiary.Runs.Outcome`), and a projection that folded the exit right after it
  #   (`run_ended/1`, from `Apiary.Runs.Projector`). A prebuild's exit ends nothing of the
  #   queue: its one session may be the fetch, whose exit comes before the build
  #   runs, so the exit folds onto the registered run as any exit does, and its outcome
  #   alone ends it so. A run that is not a prebuild, ended so, has what it gave stored
  #   on the run of the queue in the same transaction when it is decided already
  #   (`Apiary.Dispatches.Settle`), and later otherwise;
  # - its starter's release after the handover (`released/2`, from
  #   `Apiary.Dispatches.Release`): `released`. The registered
  #   run reads as cancelled with the reason `released` (`runs.released_at`, which the fold
  #   applies until an outcome decides, `Apiary.Runs.Fold`), and no outcome is recorded, so
  #   no `end` is sent for it: an end follows only the starter's outcome
  #   (`Apiary.Runs.Ingest`). Its gateway's attach is refused `410` from then on, as for any
  #   run that ended (`Apiary.Runs.Attach`). A release that finds the registered run's
  #   outcome or exit folded and its end not yet written, or its exit projected and not
  #   folded, is too late: it changes nothing, and that end is written `run_ended`. A
  #   release that finds the run's refusal folded and its end not yet written is too late
  #   too, and that end is written `run_refused`;
  # - its gateway's refusal, once folded (`refused/1`, from `Apiary.Runs.Projector`):
  #   `run_refused`, for a run that is not a prebuild. The run did not start
  #   (`dev.qory.run.refused`), so no retry can help: it is not queued again, whatever its
  #   starter's release says, and the refusal's code is kept as `end_detail`. The
  #   registered run stays failed with that code as its reason (`Apiary.Runs.Fold`). A
  #   refusal that comes after an outcome, an exit or any other end changes nothing, and a
  #   prebuild's refusal ends nothing of the queue;
  # - for a prebuild, its starter's `prebuilt` (`prebuilt/2`, from
  #   `Apiary.Dispatches.Prebuilt`): `prebuilt`. The run of the queue and its dispatch end
  #   and the slot is freed, but the registered run is left as it is: nothing is set on it,
  #   and its starter's outcome decides its state as any outcome does, with no end of the
  #   queue written again. A gateway that
  #   never attached it is refused `410` from then on (`Apiary.Runs.Attach`); one that
  #   attached it keeps it. The lost-run check passes it by, as it ended, so it records no
  #   failure for it either, and a registered run with neither an outcome nor an exit is
  #   lost by the liveness rules alone. A prebuilt that finds the outcome given is too
  #   late, as a release is; one after the exit is not;
  # - the lost-run check (`lose/1`, from `Apiary.Runs.Liveness`): `lost`, for a run its
  #   gateway never attached by its `attach_by`, or with neither an outcome nor an exit by
  #   its `backstop_at`, which its attach sets to the attach and `backstop_seconds/1` of its
  #   step; for a prebuild, with neither its prebuilt, a release nor an outcome by then,
  #   whatever its exit. The check marks the registered run lost by its rules first; this
  #   ends the run of the queue. It also ends, `run_ended`, one whose outcome or exit came
  #   and whose end was not written, should a projection have stopped between its pass and
  #   its end, and one whose exit its projection skipped unfolded
  #   (`Apiary.Runs.Projector`); for a prebuild, one whose outcome came alone. A run that
  #   is not a prebuild whose refusal was folded and whose end was not written ends
  #   `run_refused` the same way.
  #
  # A prebuild the check ends `lost` records that end as its last build's failure, on the
  # environment record of its collection and of its pool, the one that claimed it
  # (`Apiary.Environments.record_end_failure/3`): `lost` when its gateway never attached
  # it by its run key's `attach_by`, `timed_out` when nothing ended it by its backstop.
  # Its run of the queue and its dispatch end `lost` either way. A prebuild its starter's
  # outcome ends, `run_ended`, neither its prebuilt nor a release having come first,
  # records its last build's failure there too, `lost`. The record keeps its last good
  # build, and nothing is queued. A prebuild whose ref is older than the record's image's
  # records no failure (`Apiary.Environments.newer_build?/2`, asked under the record's
  # lock), and ends all the same. A prebuild that ends any other way writes nothing here:
  # its starter's release records its failure itself (`Apiary.Dispatches.Release`), and
  # its prebuilt its build.
  #
  # The run of the queue ends once: `ended`, with its end cause. Its live dispatch, the one
  # handed over, ends with it with the same cause; a stale dispatch of it not yet ended ends
  # with it, `run_ended`; `ended_at` and `end_cause` are set together. The slot the dispatch
  # took at its claim is freed then, once (`Apiary.Dispatches.Slots.free/2`, which sets
  # `slot_freed_at` only where it is nil). An end after the first changes neither the run
  # of the queue nor its dispatches, and frees nothing again; the registered run still
  # takes what comes as before: a run lost or released takes its starter's later outcome,
  # which may set it failed and is never refused as given (`Apiary.Runs.Outcome`).
  #
  # The end by a refusal, as the end by an exit, is written after the projection's pass
  # has committed, in a separate transaction (`refused/1`): the pass holds the registered
  # run, and the run of the queue is locked before it.
  #
  # **Locks.** For a prebuild, the lost-run check, an outcome and a projection's end first
  # hold its environment record `FOR UPDATE` (`hold/1`, `Apiary.Environments.lock_record/2`),
  # from the run of the queue read without a lock, for its columns that never change, as a
  # release and a prebuilt hold it (`Apiary.Dispatches.Release`, `Apiary.Dispatches.Prebuilt`):
  # so each of them and a trigger of its collection take turns at the record, and none
  # waits for another at the run. Then the run of the
  # queue is locked `FOR UPDATE`, then the registered run (its row, and for a release its
  # projection lock too, `Apiary.Runs.Projector.lock/1`), then the dispatches are written.
  # Every path that locks a run of the queue together with its dispatches or its
  # registered run locks the run of the queue first (`Apiary.Dispatches.Slots`), so two
  # ends of one run take turns there and the second finds it ended. A projection and an
  # attach lock the registered run and nothing of the queue, so an end that waits for one
  # of them is never waited for by it. A caller that locks anything of the run of the
  # queue before it calls here locks the run of the queue first.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Environments, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Settle, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Runs.{Event, Fold, Projector, Run}

  @prebuild DispatchRun.prebuild()

  # The seconds from its attach by which a run of each step has its outcome or its exit,
  # or is lost: Explore's 20 minutes, and a prebuild's 35, the prebuild workflow's 30
  # minutes and a margin. A step not named here has Explore's.
  @backstops %{"explore" => 1200, "prebuild" => 2100}
  @default_backstop 1200
  @exited "dev.qory.run.exited"
  # The runs of the queue one check looks at at most; the rest wait for the next.
  @batch 100

  # backstop_seconds/1 is the seconds after its attach by which a run of `step` has its
  # outcome or its exit, or is lost.
  @doc false
  @spec backstop_seconds(String.t() | nil) :: pos_integer
  def backstop_seconds(step), do: Map.get(@backstops, step, @default_backstop)

  # lock/1 locks the run of the queue `id` `FOR UPDATE`, inside the caller's transaction:
  # the row, or nil for none.
  @doc false
  @spec lock(Ecto.UUID.t() | nil) :: DispatchRun.t() | nil
  def lock(nil), do: nil

  def lock(id) when is_binary(id) do
    in_transaction!()
    Repo.one(from d in DispatchRun, where: d.id == ^id, lock: "FOR UPDATE")
  end

  # hold/1 holds what an end of the run of the queue `dispatch_run_id` writes besides it,
  # before the run of the queue is locked, inside the caller's transaction: for a prebuild,
  # its environment record of its collection and pool, `FOR UPDATE`
  # (`Apiary.Environments.lock_record/2`), read from the run of the queue without a lock,
  # for its columns that never change; nil for any other run, or none.
  @doc false
  @spec hold(Ecto.UUID.t() | nil) :: Record.t() | nil
  def hold(nil), do: nil

  def hold(dispatch_run_id) when is_binary(dispatch_run_id) do
    in_transaction!()

    from(d in DispatchRun,
      where: d.id == ^dispatch_run_id,
      select: {d.step, d.pool_id, d.source_collection_id}
    )
    |> Repo.one()
    |> case do
      {@prebuild, pool_id, collection_id} when is_binary(pool_id) and is_binary(collection_id) ->
        Environments.lock_record(pool_id, collection_id)

      _other ->
        nil
    end
  end

  # finish/5 ends `dispatch_run`, locked by `lock/1` in the caller's transaction, with
  # `cause`, when it is still handed over and `run` is its registered run, locked after it,
  # and, for a prebuild its starter's outcome ends, records its last build as failed on
  # `held`, the record `hold/1` held before (the moduledoc). Ended `run_ended`, what the
  # run gave is stored when it is decided already (`Apiary.Dispatches.Settle`). The ids of
  # the workspaces whose slots changed, and the work item whose run settled, for the
  # caller to tell once its transaction commits (`Apiary.Dispatches.broadcast/1`); none
  # otherwise.
  @doc false
  @spec finish(DispatchRun.t() | nil, Run.t(), atom, DateTime.t(), Record.t() | nil) ::
          [Ecto.UUID.t() | Settle.told()]
  def finish(
        %DispatchRun{state: :handed_over, id: id} = dispatch_run,
        %Run{dispatch_run_id: id} = run,
        cause,
        %DateTime{} = now,
        held
      ) do
    in_transaction!()
    changed = end_locked(dispatch_run, cause, now, detail(cause, run))
    :ok = build_ended(held, dispatch_run, cause, run, now)
    changed ++ settled(dispatch_run, run, cause, now)
  end

  def finish(_dispatch_run, %Run{}, _cause, %DateTime{}, _held), do: []

  defp settled(dispatch_run, run, :run_ended, now),
    do: Settle.settle_locked(%{dispatch_run | state: :ended, end_cause: :run_ended}, run, now)

  defp settled(%DispatchRun{work_item_id: work_item_id}, _run, :run_refused, _now),
    do: Settle.told(work_item_id)

  defp settled(_dispatch_run, _run, _cause, _now), do: []

  # The refusal's code, which the fold kept as the run's reason (`Apiary.Runs.Fold`); nil
  # for any other cause.
  defp detail(:run_refused, %Run{reason: reason}), do: reason
  defp detail(_cause, _run), do: nil

  # prebuilt/2 ends the run of the queue `dispatch_run_id`, a prebuild whose starter
  # reported the image it built after its handover, `prebuilt`, at `now`, inside the
  # caller's transaction (the moduledoc): answered as `released/2` answers, but the
  # registered run, locked as for a release, is left as it is.
  @doc false
  @spec prebuilt(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, %{run: Run.t() | nil, changed: [Ecto.UUID.t()]}}
          | {:error, :ended | :not_handed_over | :not_found}
  def prebuilt(dispatch_run_id, %DateTime{} = now) when is_binary(dispatch_run_id) do
    in_transaction!()

    case lock(dispatch_run_id) do
      nil ->
        {:error, :not_found}

      %DispatchRun{state: :handed_over} = dispatch_run ->
        run = registered(dispatch_run.id)

        if too_late?(dispatch_run, run),
          do: {:error, :ended},
          else: {:ok, %{run: run, changed: end_locked(dispatch_run, :prebuilt, now)}}

      %DispatchRun{state: :ended} ->
        {:error, :ended}

      %DispatchRun{} ->
        {:error, :not_handed_over}
    end
  end

  # released/2 ends the run of the queue `dispatch_run_id` released by its starter after
  # its handover, at `now`, inside the caller's transaction (the moduledoc): `{:ok, %{run:
  # run, changed: workspace_ids}}`, the registered run as it is now (nil should there be
  # none) for the caller to broadcast, and the workspaces whose slots changed, for the
  # caller to tell, both once its transaction commits; `{:error, :ended}` for one that
  # ended already, whatever its cause, or whose registered run has its outcome or its exit
  # folded and its end not yet written, or its exit projected and not folded, or its
  # refusal folded and its end not yet written: the first to come decides, and the
  # projection that folded the exit or the refusal, or the lost-run check, writes that end
  # (`run_ended/1`, `refused/1`, `lose/1`);
  # `{:error, :not_handed_over}` for one waiting or claimed; `{:error, :not_found}` for
  # none. Nothing is written but on `:ok`.
  @doc false
  @spec released(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, %{run: Run.t() | nil, changed: [Ecto.UUID.t()]}}
          | {:error, :ended | :not_handed_over | :not_found}
  def released(dispatch_run_id, %DateTime{} = now) when is_binary(dispatch_run_id) do
    in_transaction!()

    case lock(dispatch_run_id) do
      nil ->
        {:error, :not_found}

      %DispatchRun{state: :handed_over} = dispatch_run ->
        release_handed_over(dispatch_run, registered(dispatch_run.id), now)

      %DispatchRun{state: :ended} ->
        {:error, :ended}

      %DispatchRun{} ->
        {:error, :not_handed_over}
    end
  end

  # The registered run of the run of the queue `dispatch_run_id`, locked after it as an
  # outcome locks it: its projection lock, then its row.
  defp registered(dispatch_run_id) do
    case Repo.one(from r in Run, where: r.dispatch_run_id == ^dispatch_run_id, select: r.id) do
      nil ->
        nil

      id ->
        Projector.lock(id)

        Repo.one(
          from r in Run,
            where: r.id == ^id and r.dispatch_run_id == ^dispatch_run_id,
            lock: "FOR UPDATE"
        )
    end
  end

  # A registered run whose outcome or exit came first, an exit its projection skipped
  # unfolded among them: the release finds it ended, and leaves its end to the one that
  # came, as the lost-run check takes it (the moduledoc, `cause/2`).
  defp release_handed_over(%DispatchRun{} = dispatch_run, run, now) do
    if too_late?(dispatch_run, run),
      do: {:error, :ended},
      else:
        {:ok,
         %{
           run: run && release(run, now),
           changed: end_locked(dispatch_run, :released, now)
         }}
  end

  # A registered run whose outcome or exit came first, an exit its projection skipped
  # unfolded among them, or whose refusal was folded first; for a prebuild, whose exit and
  # refusal end nothing of the queue, its outcome alone.
  defp too_late?(_dispatch_run, nil), do: false
  defp too_late?(%DispatchRun{step: @prebuild}, %Run{} = run), do: not is_nil(run.outcome_state)

  defp too_late?(%DispatchRun{}, %Run{} = run),
    do: outcome_or_exit?(run) or exit_stored(run) == :projected or refused?(run)

  # Cancelled, with the reason `released`, and no outcome: the fold applies it after every
  # pass until an outcome decides (`Apiary.Runs.Fold.settle/1`).
  defp release(%Run{} = run, now) do
    applied = Fold.settle(%{run | released_at: now})

    run
    |> Ecto.Changeset.change(
      released_at: now,
      state: applied.state,
      reason: applied.reason,
      lost_at: applied.lost_at,
      updated_at: now
    )
    |> Repo.update!()
  end

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
  # queue is not handed over any more, or when an outcome or an exit came, stored or
  # folded, which end it as theirs. The ids of the workspaces whose slots changed, and the
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

  # lose/1 ends, at `now`, the runs of the queue handed over whose registered run its
  # gateway never attached by its `attach_by`, or that has neither an outcome nor an exit
  # by its `backstop_at` (`lost`), or whose outcome or exit came and whose end was not
  # written (`run_ended`), or whose refusal was folded and whose end was not written
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
        not is_nil(r.outcome_state) or
          (d.step != ^@prebuild and
             (not is_nil(r.exited_at) or not is_nil(r.exit_state) or not is_nil(r.refused_at))) or
          not is_nil(r.released_at) or (is_nil(r.attached_at) and r.attach_by < ^now) or
          r.backstop_at < ^now,
      order_by: d.id,
      limit: @batch,
      select: d.id
    )
    |> Repo.all()
    |> Enum.flat_map(&lose_guarded(&1, now))
    |> Enum.uniq()
  end

  defp lose_guarded(id, now) do
    {:ok, changed} = Repo.transact(fn -> {:ok, lose_one(id, now)} end)
    changed
  rescue
    error ->
      Logger.error("run end failed dispatch_run=#{id} error=#{inspect(error.__struct__)}")
      []
  end

  # The rules again, under the locks: an outcome or an exit that came meanwhile ends it as
  # its run's end, and an attach that came meanwhile leaves it to its backstop. A
  # prebuild's record is held first, and a prebuild lost records its build as failed.
  defp lose_one(id, now) do
    held = hold(id)

    with %DispatchRun{state: :handed_over} = dispatch_run <- lock(id),
         %Run{} = run <-
           Repo.one(from r in Run, where: r.dispatch_run_id == ^id, lock: "FOR UPDATE"),
         cause when not is_nil(cause) <- cause(dispatch_run, run, now) do
      finish(dispatch_run, run, cause, now, held)
    else
      _nothing -> []
    end
  end

  # A prebuild lost: its build failed, `lost` at its run key's `attach_by`, never
  # attached, else `timed_out` at its backstop. A prebuild its starter's outcome ended,
  # neither its prebuilt nor a release having come first: its build failed, `lost`. The
  # last good build kept either way. A prebuild whose ref is older than the record's
  # image's records nothing.
  defp build_ended(
         %Record{} = record,
         %DispatchRun{step: @prebuild} = dispatch_run,
         cause,
         %Run{} = run,
         now
       )
       when cause in [:lost, :run_ended] do
    if Environments.newer_build?(record, dispatch_run) do
      :ok
    else
      Environments.record_end_failure(record, failure(cause, run, now), now)
    end
  end

  defp build_ended(_held, _dispatch_run, _cause, %Run{}, _now), do: :ok

  defp failure(:run_ended, _run, _now), do: :lost
  defp failure(:lost, run, now), do: if(unattached_past?(run, now), do: :lost, else: :timed_out)

  # A prebuild's exit ends nothing of the queue: its outcome, a release, or its attach_by
  # or backstop does.
  defp cause(%DispatchRun{step: @prebuild}, run, now) do
    cond do
      not is_nil(run.outcome_state) -> :run_ended
      not is_nil(run.released_at) -> :released
      unattached_past?(run, now) or past?(run.backstop_at, now) -> :lost
      true -> nil
    end
  end

  defp cause(%DispatchRun{}, run, now) do
    cond do
      outcome_or_exit?(run) -> :run_ended
      not is_nil(run.released_at) -> :released
      refused?(run) -> :run_refused
      true -> by_exit(exit_stored(run), run, now)
    end
  end

  # What ends the run of the queue as its registered run's end once a projection folded an
  # exit: its outcome or its exit; for a prebuild, its outcome alone.
  defp ends?(%DispatchRun{step: @prebuild}, %Run{} = run), do: not is_nil(run.outcome_state)
  defp ends?(%DispatchRun{}, %Run{} = run), do: outcome_or_exit?(run)

  # A refusal folded, and no outcome or exit, stored or folded, when the run of the queue
  # is locked: the refusal ends the run of the queue. An outcome or an exit that comes
  # after the fold and before that end decides over the refusal, and the run ends
  # `run_ended`; an exit stored and not yet projected ends it when its projection folds it.
  defp refused?(%Run{} = run),
    do: not is_nil(run.refused_at) and not outcome_or_exit?(run) and is_nil(exit_stored(run))

  # An exit stored and not yet projected: its projection ends the run as its exit. One
  # projected that its fold did not take, skipped by its projection (`Apiary.Runs.Projector`):
  # it came first, so it ends the run of the queue as its exit, and no projection will.
  defp by_exit(:unprojected, _run, _now), do: nil
  defp by_exit(:projected, _run, _now), do: :run_ended

  defp by_exit(nil, run, now),
    do: if(unattached_past?(run, now) or past?(run.backstop_at, now), do: :lost)

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

  defp unattached_past?(%Run{attached_at: nil, attach_by: attach_by}, now),
    do: past?(attach_by, now)

  defp unattached_past?(%Run{}, _now), do: false

  # At or before `now` is not past: as the lost-run check and the attach window have it.
  defp past?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :lt
  defp past?(nil, _now), do: false

  defp locked_run(id), do: Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")

  # The run of the queue ended with `cause`, and `detail` kept on it, its live dispatch
  # with the cause, a stale one not yet ended `run_ended`, and the slot freed once.
  defp end_locked(%DispatchRun{id: id}, cause, now, detail \\ nil) do
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
