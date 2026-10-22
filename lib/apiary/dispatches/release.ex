defmodule Apiary.Dispatches.Release do
  @moduledoc false

  # A node pool's starter gives back the run of a dispatch its pool claimed (the
  # provisioner contract's `release.schema.json`): `release/3`, with the starter's
  # `reason`. Whether the run waits again is Qory's to decide, not the starter's: before
  # the handover it always waits again, and after it the run ends.
  # `Apiary.Dispatches` delegates it here.
  #
  # ## What it asks first
  #
  # A `dispatch_id` not of a dispatch's shape is `{:error, :forbidden}`, looked up nowhere.
  # Then, in one transaction, as a handover asks (`Apiary.Dispatches.Handover`):
  #
  #   1. the key read again as a request's verification reads it: revoked, of a pool
  #      deleted, or of a place out of use since, `{:error, :unauthorized}`;
  #   2. the dispatch by its public id, read without a lock, and `dispatch.release` asked
  #      of it (`Apiary.Access`): an unknown dispatch, one another pool claimed and any
  #      refusal of the key are one answer, `{:error, :forbidden}`, decided before any
  #      lock, after which nothing is written;
  #   3. the row the release holds before anything of the queue, from the dispatch's run
  #      of the queue read without a lock, for its columns that never change: an explore
  #      run's work item, `FOR UPDATE`, always; a prebuild's environment record of its
  #      collection and pool, `FOR UPDATE` (`Apiary.Environments.lock_record/2`);
  #   4. the slots due freed for the dispatch's run (`Apiary.Dispatches.Slots.free/2`), so
  #      a lease that lapsed and was not yet swept lapses now, and that is committed
  #      whatever follows: its run waits again, or a prebuild ends `superseded`;
  #   5. the run of the queue locked `FOR UPDATE` (`Apiary.Dispatches.RunEnd.lock/1`), then
  #      the dispatch, and the clock read once both are held;
  #   6. a dispatch that ended, or of a run that ended, is `{:error, :gone}`;
  #   7. a dispatch that was not handed over, and is stale or whose `lease_until` the clock
  #      is at or past, is `{:error, :lease_expired}`. A dispatch handed over is never
  #      refused so, whatever its `lease_until`: after the handover the release is answered
  #      as a success.
  #
  # ## Before the handover
  #
  # The dispatch ends, `released`, the slot it took is freed once, and the run registered
  # at its claim is deleted with its run code (`Apiary.Dispatches.Handover.drop/1`), so
  # the code redeems no more. Then the run waits again, as when its lease lapses:
  #
  #   - an explore run waits in its workspace's queue again with the same `run_id` and the
  #     same `queued_at`, so it takes back its place in the queue. The work item is left as
  #     it is;
  #   - a prebuild goes back to the queue as a lapsed one does, under its record's lock
  #     (`Apiary.Dispatches.Slots.wait_again/3`): it waits again with the record's
  #     `queued_ref`, or ends `superseded` while another prebuild of its collection and
  #     pool waits. No failure is recorded.
  #
  # ## After the handover
  #
  # The run ends with its registered run, `released` (`Apiary.Dispatches.RunEnd.released/2`):
  # the registered run reads as cancelled with the reason `released`, no outcome is
  # recorded, the dispatch ends with it and its slot is freed once. A registered run whose
  # outcome or exit came first is too late for it, `{:error, :gone}`, and nothing is
  # written; for a prebuild, whose exit ends nothing of the queue, its outcome alone is.
  # Nothing is queued: an explore run's work item reads its run as cancelled, and a member
  # may run Explore again; a prebuild's record keeps the last build as failed,
  # `released`, with the reason, and its last good build as it was.
  #
  # A prebuild whose ref is older than the record's image's records no failure, before the
  # handover or after it (`Apiary.Environments.newer_build?/2`, asked under the
  # record's lock): the record is left as it is, and the run ends as above.
  #
  # ## The answer
  #
  # `:ok` once the release is written, with one entry in the audit trail, in the
  # transaction: `dispatch.release`, by the pool's key, about the run registered for it
  # after the handover, and about the pool before it, its `details` the dispatch's public
  # id, the step, `handed_over`, then what came of the run, one of `waits` (true: it waits
  # again), `superseded` (true: it ended so) or `ended` (true: it ended), and the
  # `reason`. The reason is kept there and shown nowhere. A refusal writes no entry: it
  # commits what the lapse of step
  # 4 wrote, and nothing else. An exception rolls the transaction back, is logged by its
  # module alone, never the key or the reason, and is `{:error, :unavailable}`. Once it
  # commits, the registered run is broadcast as changed and the workspaces whose queue or
  # slots changed are told; a failure of either never changes the answer.
  #
  # Locks, in the order `Apiary.Dispatches.Slots` gives: the work item or the record,
  # the records a lapse needs, the run of the queue, the dispatch, then after the handover
  # the registered run, or before it, for a prebuild, the one that waits of its
  # collection and pool, under the record. A work item is never locked after the run of
  # the queue.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Audit, Environments, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover, RunEnd, Slots}
  alias Apiary.Environments.Record
  alias Apiary.WorkItems.WorkItem

  @prebuild DispatchRun.prebuild()

  @type refusal :: :unauthorized | :forbidden | :gone | :lease_expired | :unavailable

  @type release :: %{reason: String.t()}

  # release/3 gives back the run of the dispatch `dispatch_id` of the pool of
  # `access_key`, with the starter's `reason`: the moduledoc.
  @doc false
  @spec release(AccessKey.t(), term, release) :: :ok | {:error, refusal}
  def release(%AccessKey{key_id: key_id}, dispatch_id, %{reason: reason} = release)
      when is_binary(reason) do
    if Dispatch.public_id?(dispatch_id) do
      key_id
      |> Handover.transact(dispatch_id, :"dispatch.release", &hold/1, fn locked ->
        with :ok <- Handover.not_ended(locked),
             :ok <- lease_held(locked) do
          give_back(locked, release)
        end
      end)
      |> Handover.answered()
      |> Handover.broadcast_run()
      |> case do
        {:ok, _released} -> :ok
        {:error, _reason} = refused -> refused
      end
    else
      {:error, :forbidden}
    end
  end

  # The row held before anything of the queue: an explore run's work item, a prebuild's
  # environment record.
  defp hold(%DispatchRun{step: @prebuild, pool_id: pool_id, source_collection_id: id}),
    do: Environments.lock_record(pool_id, id)

  defp hold(%DispatchRun{work_item_id: id}) when is_binary(id),
    do: Repo.one(from w in WorkItem, where: w.id == ^id, lock: "FOR UPDATE")

  defp hold(%DispatchRun{}), do: nil

  # A dispatch handed over is never lease_expired: its release is a success.
  defp lease_held(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}}), do: :ok
  defp lease_held(locked), do: Handover.lease_held(locked)

  ## After the handover

  defp give_back(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}} = locked, release) do
    case RunEnd.released(locked.run.id, locked.now) do
      {:ok, %{run: run, changed: changed}} ->
        :ok = build_failed(locked, release)
        record(locked, release, %{"ended" => true}, run || locked.key.node)
        {:done, {:ok, %{run: run}}, changed}

      {:error, :ended} ->
        {:refused, :gone}
    end
  end

  ## Before the handover: the run waits again

  defp give_back(%{run: %DispatchRun{step: @prebuild}} = locked, release) do
    changed = end_dispatch(locked)
    run = locked.run
    queued_refs = queued_refs(locked.held, run)

    came =
      if run.id in Slots.wait_again([run], queued_refs, locked.now),
        do: %{"superseded" => true},
        else: %{"waits" => true}

    record(locked, release, came, locked.key.node)
    {:done, {:ok, %{run: nil}}, changed}
  end

  defp give_back(%{run: %DispatchRun{} = run} = locked, release) do
    changed = end_dispatch(locked)

    {1, _rows} =
      Repo.update_all(
        from(r in DispatchRun, where: r.id == ^run.id and fragment("? = 'claimed'", r.state)),
        set: [state: :waiting, updated_at: locked.now]
      )

    record(locked, release, %{"waits" => true}, locked.key.node)
    {:done, {:ok, %{run: nil}}, changed}
  end

  # The dispatch ended, `released`, its slot freed once, and the run registered at its
  # claim deleted with its run code: the workspace whose slots changed.
  defp end_dispatch(%{dispatch: %Dispatch{id: id} = dispatch, run: run, now: now}) do
    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [ended_at: now, end_cause: :released, updated_at: now]
      )

    _dropped = Handover.drop([run.id])

    _freed = Slots.free_slot(dispatch, now)
    [dispatch.workspace_id]
  end

  defp queued_refs(%Record{queued_ref: queued_ref}, %DispatchRun{} = run),
    do: %{{run.source_collection_id, run.pool_id} => queued_ref}

  defp queued_refs(nil, %DispatchRun{}), do: %{}

  # A prebuild's last build failed, `released`, with the reason; the last good build kept.
  # A prebuild whose ref is older than the record's image's records nothing.
  defp build_failed(
         %{run: %DispatchRun{step: @prebuild} = run, held: %Record{} = record} = locked,
         %{reason: reason}
       ) do
    if Environments.newer_build?(record, run),
      do: :ok,
      else: Environments.record_release_failure(record, reason, locked.now)
  end

  defp build_failed(_locked, _release), do: :ok

  # The one audit entry, in the transaction, about `subject`.
  defp record(%{key: key, dispatch: dispatch, run: run}, release, came, subject) do
    details =
      %{
        "dispatch_id" => dispatch.public_id,
        "step" => run.step,
        "handed_over" => not is_nil(dispatch.handed_over_at),
        "reason" => release.reason
      }
      |> Map.merge(came)

    {:ok, _entry} =
      Audit.record(Repo, Scope.for_access_key(key), :"dispatch.release", subject, %{
        details: details
      })

    :ok
  end
end
