defmodule Apiary.Dispatches.Prebuilt do
  @moduledoc false

  # A node pool's starter reports the image the job for a prebuild built (the provisioner
  # contract's `prebuilt.schema.json`): `prebuilt/3`, with the run's `run_id`, the
  # `image`, its `size`, the `environment_ref` the job read from its handover's input and
  # the `commit` it built from. `Apiary.Dispatches` delegates it here.
  #
  # ## What it asks first
  #
  # A `dispatch_id` not of a dispatch's shape is `{:error, :forbidden}`, looked up nowhere.
  # Then, in one transaction, as a release asks (`Apiary.Dispatches.Handover.transact/5`):
  #
  #   1. the key read again as a request's verification reads it: revoked, of a pool
  #      deleted, or of a place out of use since, `{:error, :unauthorized}`;
  #   2. the dispatch by its public id, read without a lock, and `dispatch.prebuilt` asked
  #      of it (`Apiary.Access`): an unknown dispatch, one another pool claimed and any
  #      refusal of the key are one answer, `{:error, :forbidden}`, decided before any
  #      lock, after which nothing is written;
  #   3. for a prebuild, its environment record of its collection and pool, `FOR UPDATE`
  #      (`Apiary.Environments.lock_record/2`), from the dispatch's run of the queue read
  #      without a lock, for its columns that never change, before anything of the queue;
  #      for any other step, nothing;
  #   4. the slots due freed for the dispatch's run (`Apiary.Dispatches.Slots.free/2`), so
  #      a lease that lapsed and was not yet swept lapses now, and that is committed
  #      whatever follows;
  #   5. the run of the queue locked `FOR UPDATE` (`Apiary.Dispatches.RunEnd.lock/1`), then
  #      the dispatch, and the clock read once both are held.
  #
  # Then the first of these that applies, in the contract's order:
  #
  #   6. a dispatch that ended, or of a run that ended, a second prebuilt among them, since
  #      the first ended the run: `{:error, :gone}`;
  #   7. a dispatch not handed over that is stale, or whose `lease_until` the clock is at or
  #      past: `{:error, :lease_expired}`. A dispatch handed over is never refused so;
  #   8. a dispatch whose step is not `prebuild`: `{:error, :not_prebuild}`;
  #   9. a dispatch not handed over yet: `{:error, :not_handed_over}`;
  #   10. a `run_id` that is not the dispatch's run: `{:error, :run_mismatch}`.
  #
  # ## On success
  #
  # The run of the queue ends, `prebuilt` (`Apiary.Dispatches.RunEnd.prebuilt/2`): the
  # dispatch ends with it, `prebuilt`, and its slot is freed once. The registered run is
  # left as it is, to its starter's outcome, which decides its state as any outcome does;
  # nothing reads it as cancelled. Its exit, folded or not, ends nothing of the queue, so
  # a prebuilt after it acts as before it; a registered run whose outcome came first is
  # too late for it, `{:error, :gone}`, and nothing is written. Then the build is recorded
  # on the record of the prebuild's pool and collection (`Apiary.Environments.record_build/4`):
  # the image, its size, its commit, the `environment_ref` the job reported, as it is even
  # where it differs from the record's `queued_ref`, when it was recorded, and the target
  # it was built for, the registered run's target, which its handover named from the
  # collection's target as it was then (`Apiary.Lingo.Domain.target/2` of its registration
  # labels), and when the prebuild took the `environment_ref` it built (`built_queued_at`,
  # from its `environment_ref_at`). The last failure is
  # cleared and nothing is queued, so a reported ref that differs never loops.
  # `retired_at` is cleared only when the prebuild took its ref after the record was
  # retired, and the record is served again; a prebuild that took its ref before the
  # retirement leaves the record retired.
  #
  # A prebuild whose ref is older than the record's image's, taken before the prebuild
  # that made the image took its (`Apiary.Environments.newer_build?/2`, asked under the
  # record's lock), leaves the record
  # as it is, its image and its last failure, and writes no audit entry, as nothing was
  # recorded: its run ends as above, and the answer is the same.
  #
  # ## The answer
  #
  # `:ok` once the build is written, or the run ended alone as above, with one entry in
  # the audit trail, in the transaction, where the build was written: `dispatch.prebuilt`,
  # by the pool's key, about the registered run, its `details` the dispatch's public id,
  # the image's size, its commit and the `environment_ref` reported; the image itself is on
  # the record alone, as the trail keeps nothing with an `@`. A refusal writes no entry: it
  # commits what the lapse of step 4 wrote, and nothing else. An exception rolls the
  # transaction back, is logged by its module alone, never the key or the body, and is
  # `{:error, :unavailable}`. Once it commits, the registered run is broadcast as changed
  # and the workspaces whose queue or slots changed are told; a failure of either never
  # changes the answer.
  #
  # Locks, in the order a release takes them (`Apiary.Dispatches.Slots`): the record, the
  # records a lapse needs, the run of the queue, the dispatch, then the registered run; the
  # record is written last, under its lock taken first.

  alias Apiary.{Audit, Environments, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover, RunEnd}
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Run

  @prebuild DispatchRun.prebuild()

  @type refusal ::
          :unauthorized
          | :forbidden
          | :gone
          | :lease_expired
          | :not_prebuild
          | :not_handed_over
          | :run_mismatch
          | :unavailable

  @type prebuilt :: %{
          run_id: String.t(),
          image: String.t(),
          size: pos_integer,
          environment_ref: String.t(),
          commit: String.t()
        }

  # prebuilt/3 records the image the job for the dispatch `dispatch_id` of the pool of
  # `access_key` built: the moduledoc.
  @doc false
  @spec prebuilt(AccessKey.t(), term, prebuilt) :: :ok | {:error, refusal}
  def prebuilt(%AccessKey{key_id: key_id}, dispatch_id, %{run_id: run_id} = prebuilt)
      when is_binary(run_id) do
    if Dispatch.public_id?(dispatch_id) do
      key_id
      |> Handover.transact(dispatch_id, :"dispatch.prebuilt", &hold/1, fn locked ->
        with :ok <- Handover.not_ended(locked),
             :ok <- lease_held(locked),
             :ok <- prebuild(locked),
             :ok <- handed_over(locked),
             :ok <- same_run(locked, run_id) do
          record(locked, prebuilt)
        end
      end)
      |> Handover.answered()
      |> Handover.broadcast_run()
      |> case do
        {:ok, _recorded} -> :ok
        {:error, _reason} = refused -> refused
      end
    else
      {:error, :forbidden}
    end
  end

  # The row held before anything of the queue: a prebuild's environment record.
  defp hold(%DispatchRun{step: @prebuild, pool_id: pool_id, source_collection_id: id}),
    do: Environments.lock_record(pool_id, id)

  defp hold(%DispatchRun{}), do: nil

  # A dispatch handed over is never lease_expired.
  defp lease_held(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}}), do: :ok
  defp lease_held(locked), do: Handover.lease_held(locked)

  defp prebuild(%{run: %DispatchRun{step: @prebuild}}), do: :ok
  defp prebuild(_locked), do: {:refused, :not_prebuild}

  defp handed_over(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}}), do: :ok
  defp handed_over(_locked), do: {:refused, :not_handed_over}

  defp same_run(%{run: %DispatchRun{run_id: run_id}}, run_id), do: :ok
  defp same_run(_locked, _run_id), do: {:refused, :run_mismatch}

  # The run of the queue ended, `prebuilt`, then the build recorded and the one audit
  # entry written; for a prebuild whose ref is older than the record's image's, the run
  # ended alone.
  defp record(locked, prebuilt) do
    case RunEnd.prebuilt(locked.run.id, locked.now) do
      {:ok, %{run: run, changed: changed}} ->
        if not Environments.newer_build?(locked.held, locked.run) do
          :ok =
            Environments.record_build(
              locked.run,
              prebuilt,
              built_target(locked, run),
              locked.now
            )

          audit(locked, prebuilt, run || locked.key.node)
        end

        {:done, {:ok, %{run: run}}, changed}

      {:error, :ended} ->
        {:refused, :gone}
    end
  end

  # The registered run's target, as its registration labels name it in the pool's
  # workspace: the target its handover named.
  defp built_target(%{key: %AccessKey{workspace_id: workspace_id}}, %Run{} = run) do
    case Domain.target(Repo.get!(Workspace, workspace_id), run.registration_labels) do
      {:ok, target} -> target
      :none -> nil
    end
  end

  defp built_target(_locked, nil), do: nil

  # The one audit entry, in the transaction, about `subject`.
  defp audit(%{key: key, dispatch: dispatch}, prebuilt, subject) do
    details = %{
      "dispatch_id" => dispatch.public_id,
      "size" => prebuilt.size,
      "commit" => prebuilt.commit,
      "environment_ref" => prebuilt.environment_ref
    }

    {:ok, _entry} =
      Audit.record(Repo, Scope.for_access_key(key), :"dispatch.prebuilt", subject, %{
        details: details
      })

    :ok
  end
end
