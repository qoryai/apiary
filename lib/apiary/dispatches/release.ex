defmodule Apiary.Dispatches.Release do
  @moduledoc false

  # A node pool's starter gives back the run of a dispatch its pool claimed (the
  # provisioner contract's `release.schema.json`): `release/3`, with the starter's
  # `reason`. A release is accepted only before the handover: before `dispatched` and
  # while the run code is unredeemed. The run then waits again.
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
  #   7. a dispatch handed over, by its `dispatched` or by the redemption of its run code,
  #      is `{:error, :machine_exists}`: a machine exists for it;
  #   8. a dispatch that is stale or whose `lease_until` the clock is at or past is
  #      `{:error, :lease_expired}`.
  #
  # ## The release
  #
  # The dispatch ends, `released`, with the starter's reason as its `release_reason`, the
  # slot it took is freed once, and the run registered at its claim ends failed,
  # `machine_not_made`, and leaves the run of the queue
  # (`Apiary.Dispatches.Handover.fail_start/3`), so the code redeems no more. Then the run
  # of the queue waits again, as when its lease lapses:
  #
  #   - an explore run waits in its workspace's queue again with the same `run_id` and the
  #     same `queued_at`, so it takes back its place in the queue. The work item is left as
  #     it is;
  #   - a prebuild goes back to the queue as a lapsed one does, under its record's lock
  #     (`Apiary.Dispatches.Slots.wait_again/2`): it waits again with its
  #     `environment_ref`, or ends `superseded` while another prebuild of its collection,
  #     pool and `environment_ref` waits. No failure is recorded.
  #
  # A prebuild given back records no failure: its environment record keeps its last
  # build as it was.
  #
  # ## The answer
  #
  # `:ok` once the release is written, with one entry in the audit trail, in the
  # transaction: `dispatch.release`, by the pool's key, about the pool, its `details` the
  # dispatch's public id, the step, `handed_over` (false), then what came of the run, one
  # of `waits` (true: it waits again) or `superseded` (true: it ended so), and the
  # `reason`. The reason is kept there and on the dispatch, and the page of the run that
  # failed shows it. A refusal writes no entry: it
  # commits what the lapse of step
  # 4 wrote, and nothing else. An exception rolls the transaction back, is logged by its
  # module alone, never the key or the reason, and is `{:error, :unavailable}`. Once it
  # commits, the workspaces whose queue or slots changed are told; a failure never changes
  # the answer.
  #
  # Locks, in the order `Apiary.Dispatches.Slots` gives: the work item or the record,
  # the records a lapse needs, the run of the queue, the dispatch, then, for a prebuild,
  # the one that waits of its collection and pool, under the record. A work item is never locked after the run of
  # the queue.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Audit, Environments, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover, Slots}
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @prebuild DispatchRun.prebuild()

  @type refusal ::
          :unauthorized | :forbidden | :gone | :machine_exists | :lease_expired | :unavailable

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
             :ok <- no_machine(locked),
             :ok <- Handover.lease_held(locked) do
          give_back(Map.put(locked, :reason, reason), release)
        end
      end)
      |> Handover.answered()
      |> case do
        {:ok, %{failed: failed}} -> broadcast_failed(failed)
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

  # A dispatch handed over has a machine: its `dispatched` came, or its run code was
  # redeemed.
  defp no_machine(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}}),
    do: {:refused, :machine_exists}

  defp no_machine(_locked), do: :ok

  ## The run waits again

  defp give_back(%{run: %DispatchRun{step: @prebuild}} = locked, release) do
    {changed, failed} = end_dispatch(locked)
    run = locked.run

    came =
      if run.id in Slots.wait_again([run], locked.now),
        do: %{"superseded" => true},
        else: %{"waits" => true}

    record(locked, release, came, locked.key.node)
    {:done, {:ok, %{run: nil, failed: failed}}, changed}
  end

  defp give_back(%{run: %DispatchRun{} = run} = locked, release) do
    {changed, failed} = end_dispatch(locked)

    {1, _rows} =
      Repo.update_all(
        from(r in DispatchRun, where: r.id == ^run.id and fragment("? = 'claimed'", r.state)),
        set: [state: :waiting, updated_at: locked.now]
      )

    record(locked, release, %{"waits" => true}, locked.key.node)
    {:done, {:ok, %{run: nil, failed: failed}}, changed}
  end

  # The dispatch ended, `released`, with the starter's reason, its slot freed once, and
  # the run registered at its claim failed, `machine_not_made`: the workspace whose slots
  # changed, and the ids of the runs that failed.
  defp end_dispatch(%{dispatch: %Dispatch{id: id} = dispatch, run: run, now: now} = locked) do
    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [ended_at: now, end_cause: :released, release_reason: locked.reason, updated_at: now]
      )

    failed = Handover.fail_start([{run.id, id}], "machine_not_made", now)

    _freed = Slots.free_slot(dispatch, now)
    {[dispatch.workspace_id], failed}
  end

  # Once the release commits, the run that failed is told, as any run that changes
  # (`Apiary.Runs.broadcast_changed/1`). A failure of it is logged by its kind alone and
  # never changes the answer.
  defp broadcast_failed(ids) do
    Repo.all(from r in Run, where: r.id in ^ids) |> Enum.each(&Runs.broadcast_changed/1)
    :ok
  rescue
    exception ->
      Logger.error("a failed run could not be told: #{inspect(exception.__struct__)}")
      :ok
  end

  # The one audit entry, in the transaction, about `subject`, the key's pool, in the trail
  # of the dispatch's organisation: the key's, or, for the instance's pool's key, which
  # has none, the organisation of the workspace it served
  # (`Apiary.Accounts.Scope.key_in_organisation/2`).
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
      Audit.record(Repo, scope(key, dispatch), :"dispatch.release", subject, %{
        details: details
      })

    :ok
  end

  defp scope(%AccessKey{organisation_id: nil} = key, %Dispatch{organisation_id: id}),
    do: Scope.key_in_organisation(Scope.for_access_key(key), Repo.get!(Organisation, id))

  defp scope(%AccessKey{} = key, %Dispatch{}), do: Scope.for_access_key(key)
end
