defmodule Apiary.Dispatches.RunEnd do
  @moduledoc false

  # The end of a run of the queue once it was handed over (`Apiary.Dispatches.DispatchRun`,
  # `:handed_over`), with its dispatches and the slot its dispatch holds. The run registered
  # for it (`Apiary.Runs.Run`, whose `dispatch_run_id` names it) ends in one of three ways,
  # and the first to come decides the end cause:
  #
  # - its starter's outcome, or its exit once folded: `run_ended`. The outcome's write ends
  #   it in its transaction (`lock/1`, then `finish/4`, from `Apiary.Runs.Outcome`), and a
  #   projection that folded the exit right after it (`run_ended/1`, from
  #   `Apiary.Runs.Projector`);
  # - its starter's release after the handover (`released/2`): `released`. The registered
  #   run reads as cancelled with the reason `released` (`runs.released_at`, which the fold
  #   applies until an outcome decides, `Apiary.Runs.Fold`), and no outcome is recorded, so
  #   no `end` is sent for it: an end follows only the starter's outcome
  #   (`Apiary.Runs.Ingest`). Its gateway's attach is refused `410` from then on, as for any
  #   run that ended (`Apiary.Runs.Attach`). A release that finds the registered run's
  #   outcome or exit folded and its end not yet written, or its exit projected and not
  #   folded, is too late: it changes nothing, and that end is written `run_ended`;
  # - the lost-run check (`lose/1`, from `Apiary.Runs.Liveness`): `lost`, for a run its
  #   gateway never attached by its `attach_by`, or with neither an outcome nor an exit by
  #   its `backstop_at`, which its attach sets to the attach and `backstop_seconds/1` of its
  #   step. The check marks the registered run lost by its rules first; this ends the run of
  #   the queue. It also ends, `run_ended`, one whose outcome or exit came and whose end was
  #   not written, should a projection have stopped between its pass and its end, and one
  #   whose exit its projection skipped unfolded (`Apiary.Runs.Projector`).
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
  # **Locks.** The run of the queue is locked `FOR UPDATE` first, then the registered run
  # (its row, and for a release its projection lock too, `Apiary.Runs.Projector.lock/1`),
  # then the dispatches are written. Every path that locks a run of the queue together with
  # its dispatches or its registered run locks the run of the queue first
  # (`Apiary.Dispatches.Slots`), so two ends of one run take turns there and the second
  # finds it ended. A projection and an attach lock the registered run and nothing of the
  # queue, so an end that waits for one of them is never waited for by it. A caller that
  # locks anything of the run of the queue before it calls here locks the run of the queue
  # first.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Fold, Projector, Run}

  # The seconds from its attach by which a run of each step has its outcome or its exit,
  # or is lost; a step not named here has Explore's.
  @backstops %{"explore" => 1200}
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

  # finish/4 ends `dispatch_run`, locked by `lock/1` in the caller's transaction, with
  # `cause`, when it is still handed over and `run` is its registered run, locked after it:
  # the ids of the workspaces whose slots changed, for the caller to tell once its
  # transaction commits (`Apiary.Dispatches.broadcast/1`); none otherwise.
  @doc false
  @spec finish(DispatchRun.t() | nil, Run.t(), atom, DateTime.t()) ::
          [Ecto.UUID.t()]
  def finish(
        %DispatchRun{state: :handed_over, id: id} = dispatch_run,
        %Run{dispatch_run_id: id},
        cause,
        %DateTime{} = now
      ) do
    in_transaction!()
    end_locked(dispatch_run, cause, now)
  end

  def finish(_dispatch_run, %Run{}, _cause, %DateTime{}), do: []

  # released/2 ends the run of the queue `dispatch_run_id` released by its starter after
  # its handover, at `now`, inside the caller's transaction (the moduledoc): `{:ok, %{run:
  # run, changed: workspace_ids}}`, the registered run as it is now (nil should there be
  # none) for the caller to broadcast, and the workspaces whose slots changed, for the
  # caller to tell, both once its transaction commits; `{:error, :ended}` for one that
  # ended already, whatever its cause, or whose registered run has its outcome or its exit
  # folded and its end not yet written, or its exit projected and not folded: the first to
  # come decides, and the projection that folded the exit, or the lost-run check, writes
  # that end (`run_ended/1`, `lose/1`);
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
    if run && (outcome_or_exit?(run) or exit_stored(run) == :projected),
      do: {:error, :ended},
      else:
        {:ok,
         %{
           run: run && release(run, now),
           changed: end_locked(dispatch_run, :released, now)
         }}
  end

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
  # for the caller to tell (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec run_ended(Run.t()) :: [Ecto.UUID.t()]
  def run_ended(%Run{id: run_id, dispatch_run_id: dispatch_run_id})
      when is_binary(dispatch_run_id) do
    {:ok, changed} =
      Repo.transact(fn ->
        with %DispatchRun{state: :handed_over} = dispatch_run <- lock(dispatch_run_id),
             %Run{} = run <- locked_run(run_id),
             true <- outcome_or_exit?(run) do
          {:ok, finish(dispatch_run, run, :run_ended, now())}
        else
          _not_ended -> {:ok, []}
        end
      end)

    changed
  end

  def run_ended(%Run{}), do: []

  # lose/1 ends, at `now`, the runs of the queue handed over whose registered run its
  # gateway never attached by its `attach_by`, or that has neither an outcome nor an exit
  # by its `backstop_at` (`lost`), or whose outcome or exit came and whose end was not
  # written (`run_ended`): at most `@batch`, each in a separate transaction. One that
  # raises is logged by its id and the exception's module, and the rest are still ended.
  # The ids of the workspaces whose slots changed, for the caller to tell
  # (`Apiary.Dispatches.broadcast/1`).
  @doc false
  @spec lose(DateTime.t()) :: [Ecto.UUID.t()]
  def lose(%DateTime{} = now) do
    from(d in DispatchRun,
      join: r in Run,
      on: r.dispatch_run_id == d.id,
      where: fragment("? = 'handed_over'", d.state),
      where:
        not is_nil(r.outcome_state) or not is_nil(r.exited_at) or not is_nil(r.exit_state) or
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
  # its run's end, and an attach that came meanwhile leaves it to its backstop.
  defp lose_one(id, now) do
    with %DispatchRun{state: :handed_over} = dispatch_run <- lock(id),
         %Run{} = run <-
           Repo.one(from r in Run, where: r.dispatch_run_id == ^id, lock: "FOR UPDATE"),
         cause when not is_nil(cause) <- cause(run, now) do
      end_locked(dispatch_run, cause, now)
    else
      _nothing -> []
    end
  end

  defp cause(run, now) do
    cond do
      outcome_or_exit?(run) -> :run_ended
      not is_nil(run.released_at) -> :released
      true -> by_exit(exit_stored(run), run, now)
    end
  end

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

  # The run of the queue ended with `cause`, its live dispatch with it, a stale one not
  # yet ended `run_ended`, and the slot freed once.
  defp end_locked(%DispatchRun{id: id}, cause, now) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id),
        set: [state: :ended, end_cause: cause, updated_at: now]
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
