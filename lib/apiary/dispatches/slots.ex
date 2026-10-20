defmodule Apiary.Dispatches.Slots do
  @moduledoc false

  # The slots of a node pool's instance limit its claims take (the provisioner contract's
  # `claim.schema.json`): each dispatch takes one at its claim, and its slot is freed
  # once, at the first of its release (`Apiary.Dispatches.Release`), the lapse of its
  # lease before its handover, its end before its handover because its work item was
  # closed or undone, or its run's end.
  # A dispatch holds its slot while `slot_freed_at` is nil, and `slot_freed_at` is set
  # once: every write here sets it only where it is nil, so a slot freed twice keeps the
  # first time.
  #
  # - `held/1` counts the slots a pool's dispatches hold, read from the partial index on
  #   the held ones. `Apiary.Nodes.check_instance_limit/3` adds them to the pool's live
  #   runs that were not dispatched, and a claim counts the same (`Apiary.Dispatches`).
  # - `free/2` frees what is due at `now`, for one pool, for every pool (`:all`) or for
  #   the dispatches of some runs of the queue (`{:runs, ids}`, as an undo asks): a
  #   dispatch whose lease lapsed before its handover (`now` at or after `lease_until`,
  #   neither handed over, stale nor ended) is marked stale at `now`, its slot freed, and
  #   its run, claimed, waits in its workspace's queue again with the same `run_id` and
  #   the same `queued_at`, so it takes back its place in the queue; except a prebuild
  #   whose collection and node pool have another prebuild waiting: one prebuild waits per
  #   collection and pool (`Apiary.Dispatches.queue_prebuild/3`), and the one that waits
  #   carries the `queued_ref` of the pool's environment record of the collection, the
  #   latest `environment_ref` asked for. So, per collection and pool, of its lapsed
  #   claimed prebuilds: while another waits, each ends, `superseded`, and the one that
  #   waits takes the record's `queued_ref`; while none waits, one waits again, with the
  #   record's `queued_ref`, the one queued for it or else the one queued last, and each
  #   other ends `superseded`. A prebuild that takes another `environment_ref` so keeps
  #   when it took it (`environment_ref_at`), its `queued_at` kept. A dispatch of a run that ends so ends with it
  #   (`run_ended`). A dispatch that ended with its slot still held has it freed.
  #   Whatever the state of the pool or of the key that claimed it: a deleted pool's or a
  #   revoked key's dispatch lapses at its `lease_until` as any other does. Its run then
  #   waits for the workspace's other pools, unless it is a prebuild: a lapsed prebuild
  #   waits again or ends as above, and the one that waits is still held for its pool,
  #   which alone may claim it.
  #   It answers the ids of the workspaces whose queue or slots changed, for the caller to
  #   tell once its transaction commits (`Apiary.Dispatches.broadcast/1`).
  # - `free_slot/2` frees one dispatch's slot, for the paths that end a dispatch.
  #
  # **Locks.** Every path that locks more than one of these takes them in this order (a
  # free of more than one batch takes the records once, then the rest batch by batch, as
  # below says), so that no two paths wait on each other:
  #
  #   1. the collections (a listing's part, by ref, or an assign, by id;
  #      `Apiary.Adapters.Collections`, whose lock order names what each holds before
  #      them, and the targets each makes after them and before the environment records;
  #      a Rebuild holds their connections `FOR SHARE`, by id, then them `FOR SHARE`, by
  #      id, `Apiary.Environments.rebuild/2`);
  #   2. a node pool's row: a claim takes it `FOR NO KEY UPDATE` (`Apiary.Dispatches`), so
  #      a registration on the pool, which takes it `FOR UPDATE`
  #      (`Apiary.Nodes.check_instance_limit/3`), and another claim take turns with it,
  #      while the `FOR KEY SHARE` that a trigger's writes take for their foreign keys to
  #      the pool never waits on it;
  #   3. the environment records, `FOR UPDATE`, by collection and then pool, each path in
  #      one statement: a trigger locks every record of its collections before it writes
  #      one (`Apiary.Environments.trigger/2`), whatever order its caller names them in,
  #      and `free/2` the records of every prebuild whose dispatch lapsed in its scope,
  #      those of every batch, before its first batch locks a run. It reads them before
  #      their lock, as a run's collection and pool never change. A prebuild seen lapsed
  #      only after that statement, its dispatch or its record committed after it, is
  #      taken only when its record is already locked, and is left for the next free
  #      otherwise. The free of an undo or a close, of the runs of work items, locks none;
  #   4. the runs of the queue whose dispatch lapsed, `FOR UPDATE`, by id (`free/2`), and
  #      the runs `Apiary.Dispatches` ends for an undo or a close; a run of the queue is
  #      locked before the run registered for it (`Apiary.Dispatches.RunEnd`), as every
  #      path that locks both does. The free of such an end, of a run handed over, comes
  #      after the end has ended each of its dispatches, so it finds none lapsed and locks
  #      no record;
  #   5. the waiting runs: the one prebuild that waits per collection and pool, which a
  #      trigger writes or ends and `free/2` reads `FOR UPDATE`, only under the record's
  #      lock; a claim takes a waiting run `FOR UPDATE SKIP LOCKED`, which waits on none;
  #   6. the dispatches.
  #
  # A handover (`Apiary.Dispatches.Handover`) keeps the order: for an explore run, first
  # the rows of the model providers its choices name and of their keys' secrets, each
  # `FOR SHARE` (`Apiary.Dispatches.RunSettings`), which come before every lock above;
  # then the free of its run (`{:runs, [id]}`), which locks a lapsed prebuild's
  # environment record before its run, then its run of the queue `FOR UPDATE`
  # (`Apiary.Dispatches.RunEnd`), then its dispatch, and only then, beyond these, the
  # gateway's row `FOR SHARE` and the run it registers, as a run of the queue is locked
  # before the run registered for it.
  #
  # A release (`Apiary.Dispatches.Release`) keeps it as well, and holds one row before
  # the free of its run: for an explore run, its work item `FOR UPDATE`, as a close
  # (`Apiary.WorkItems.close_locked/3`) and `Apiary.Dispatches.queue_next/2` hold a work
  # item before its runs; for a prebuild, its environment record `FOR UPDATE`, as 3.
  # has it. Then the free of its run, which locks that record again where its lease
  # lapsed, its run of the queue, its dispatch, and after its handover the run
  # registered for it (`Apiary.Dispatches.RunEnd.released/2`). A prebuild given back with
  # retry before its handover locks the one that waits of its collection and pool after
  # its dispatch (`wait_again/3`): under the record it holds, which every path that locks
  # the one that waits holds first, but a claim, whose `FOR UPDATE SKIP LOCKED` waits on
  # none. A path that locks a work item locks it before any run of the queue, never after.
  #
  # The lost-run check's end of a prebuild handed over (`Apiary.Dispatches.RunEnd`) keeps
  # it too: the prebuild's environment record `FOR UPDATE`, as 3. has it, then its run of
  # the queue, its registered run and its dispatches, then the free of its run, which
  # finds none lapsed.
  #
  # So a prebuild comes to wait, or the one that waits takes another `environment_ref`,
  # only under the lock of its record, and whoever comes second sees what the first
  # wrote; a claim that takes or ends the one that waits holds its row, and whoever reads
  # it `FOR UPDATE` meanwhile reads it again once the claim commits. The records come
  # before the runs: a run `free/2` locks by its id may have gone back to waiting
  # meanwhile, and a trigger that holds the record waits for that run's lock. `free/2`
  # writes the dispatches with each write asking its conditions again, so a dispatch
  # handed over, ended or freed meanwhile is left as it is.
  #
  # `free/2` takes its lapsed dispatches in batches, `@batch` at most, by run id, each
  # batch after the last run of the one before, all in one transaction: so a later
  # batch locks its runs after an earlier one locked its waiting runs and its
  # dispatches. No two paths wait on each other for that: it holds every record its
  # batches need before the first, so a path that holds a record never waits on it at a
  # run; it locks only the waiting runs of the records it holds, as it takes a prebuild
  # only when it holds its record (`candidates/3`, which says why every prebuild has
  # one), and only the dispatches of the runs it holds; and every path that locks runs
  # whose lease lapsed, another free, an undo or a close, takes them in the order of
  # their ids as well, so whichever of two waits on the other at a run holds only runs
  # of lower ids, which the other never asks for again. Every function here runs inside
  # the caller's transaction.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Environments.Record
  alias Apiary.Repo

  # The lapsed dispatches one batch takes at most; `free/2` takes the next, after the
  # last run of the one before, while a whole one lapsed.
  @batch 500

  # The slots the dispatches of `pool_id` hold.
  @doc false
  @spec held(Ecto.UUID.t()) :: non_neg_integer
  def held(pool_id) when is_binary(pool_id) do
    Repo.aggregate(
      from(d in Dispatch, where: d.pool_id == ^pool_id and is_nil(d.slot_freed_at)),
      :count
    )
  end

  # Frees what is due at `now` for the dispatches of `pool_id`, of every pool with `:all`,
  # or of the runs `ids` with `{:runs, ids}`, as the moduledoc says: the ids of the
  # workspaces whose queue or slots changed.
  @doc false
  @spec free(Ecto.UUID.t() | :all | {:runs, [Ecto.UUID.t()]}, DateTime.t()) :: [Ecto.UUID.t()]
  def free(pool, %DateTime{} = now)
      when is_binary(pool) or pool == :all or
             (is_tuple(pool) and tuple_size(pool) == 2 and elem(pool, 0) == :runs) do
    in_transaction!()
    records = lock_records(pool, now)
    lapsed = lapse(pool, now, records, nil, [])
    ended = free_ended(pool, now)
    Enum.uniq(lapsed ++ ended)
  end

  # Frees the slot of `dispatch` at `now`, once: `true` when this call freed it, `false`
  # when it was freed before.
  @doc false
  @spec free_slot(Dispatch.t(), DateTime.t()) :: boolean
  def free_slot(%Dispatch{id: id}, %DateTime{} = now) when is_binary(id) do
    in_transaction!()

    {count, _rows} =
      Repo.update_all(
        from(d in Dispatch, where: d.id == ^id and is_nil(d.slot_freed_at)),
        set: [slot_freed_at: now, updated_at: now]
      )

    count == 1
  end

  # One batch of the lapsed dispatches, by run id, after the run `after_id`, then the
  # next, while a whole one lapsed. The environment records were locked before the first
  # (`lock_records/2`); then the runs, then their dispatches (the moduledoc).
  defp lapse(pool, now, records, after_id, workspaces) do
    candidates =
      pool
      |> candidates(now, records)
      |> after_run(after_id)
      |> Repo.all()

    case candidates do
      [] ->
        workspaces

      run_ids ->
        runs =
          Repo.all(
            from r in DispatchRun,
              where: r.id in ^run_ids,
              order_by: r.id,
              lock: "FOR UPDATE"
          )

        {_count, stale} =
          Repo.update_all(
            from(d in lapsed(pool, now),
              where: d.dispatch_run_id in ^run_ids,
              select: {d.dispatch_run_id, d.workspace_id}
            ),
            set: [stale_at: now, slot_freed_at: now, updated_at: now]
          )

        {stale_runs, stale_workspaces} = Enum.unzip(stale)
        stale_runs = MapSet.new(stale_runs)

        {prebuilds, others} =
          runs
          |> Enum.filter(&(MapSet.member?(stale_runs, &1.id) and &1.state == :claimed))
          |> Enum.split_with(&(&1.step == DispatchRun.prebuild()))

        {_count, _rows} =
          Repo.update_all(
            from(r in DispatchRun,
              where: r.id in ^Enum.map(others, & &1.id),
              where: fragment("? = 'claimed'", r.state)
            ),
            set: [state: :waiting, updated_at: now]
          )

        _superseded = wait_again(prebuilds, records.queued_refs, now)
        workspaces = Enum.uniq(stale_workspaces ++ workspaces)

        # Another batch, after the last run of this one, while a whole one lapsed.
        if length(candidates) == @batch,
          do: lapse(pool, now, records, List.last(run_ids), workspaces),
          else: workspaces
    end
  end

  # The runs of the next batch, `@batch` at most, by id, of the lapsed dispatches of
  # `pool`: a run of any other step, which has no environment record (`is_nil(e.id)`), and
  # a prebuild only when the record of its collection and pool is among those
  # `lock_records/2` locked. A prebuild seen lapsed only after that lock, its dispatch or
  # its record committed after it, is so taken only when its record is already locked,
  # and is left for the next free otherwise. A prebuild without a record cannot occur:
  # its record is written before it (`Apiary.Environments`), and the purge deletes the
  # runs of the queue before the environment records.
  defp candidates(pool, now, %{ids: record_ids}) do
    from d in lapsed(pool, now),
      join: r in DispatchRun,
      on: r.id == d.dispatch_run_id,
      left_join: e in Record,
      on: e.source_collection_id == r.source_collection_id and e.pool_id == r.pool_id,
      where: is_nil(e.id) or e.id in ^record_ids,
      order_by: d.dispatch_run_id,
      limit: @batch,
      select: d.dispatch_run_id
  end

  defp after_run(query, nil), do: query
  defp after_run(query, run_id), do: from([d] in query, where: d.dispatch_run_id > ^run_id)

  # Locks, `FOR UPDATE`, in one statement, by collection and then pool, as
  # `Apiary.Environments.trigger/2` does, the environment records of the collections and
  # pools of every prebuild whose dispatch lapsed at `now` in the scope `pool`, of every
  # batch, before the first batch locks a run: their ids, and the `queued_ref` of each by
  # `{collection_id, pool_id}`. A run's collection and pool never change, so they are read
  # before its lock.
  defp lock_records(pool, now) do
    lapsed_runs = from d in lapsed(pool, now), select: d.dispatch_run_id

    keys =
      from e in Record,
        join: r in DispatchRun,
        on: r.source_collection_id == e.source_collection_id and r.pool_id == e.pool_id,
        where: r.id in subquery(lapsed_runs) and r.step == ^DispatchRun.prebuild(),
        select: e.id

    locked =
      Repo.all(
        from e in Record,
          where: e.id in subquery(keys),
          order_by: [e.source_collection_id, e.pool_id],
          lock: "FOR UPDATE",
          select: {e.id, {e.source_collection_id, e.pool_id}, e.queued_ref}
      )

    %{
      ids: Enum.map(locked, &elem(&1, 0)),
      queued_refs: Map.new(locked, fn {_id, key, queued_ref} -> {key, queued_ref} end)
    }
  end

  # wait_again/3 takes the claimed `prebuilds`, whose dispatch lapsed or was released
  # with retry before its handover, back to the queue, under the lock of their
  # environment records, which the caller holds, per collection and pool: while another
  # prebuild waits, each ends `superseded`, and the one that waits takes the record's
  # `queued_ref`; else one waits again, with its `run_id` and its `queued_at`, and the
  # record's `queued_ref`: the one queued for that `queued_ref`, or else the one queued
  # last; the others end `superseded`. `queued_refs` is each record's `queued_ref` by
  # `{collection_id, pool_id}`. Their stale dispatches end with them (`run_ended`). The
  # ids of the runs that ended `superseded`.
  @doc false
  @spec wait_again(
          [DispatchRun.t()],
          %{optional({Ecto.UUID.t(), Ecto.UUID.t()}) => String.t() | nil},
          DateTime.t()
        ) ::
          [Ecto.UUID.t()]
  def wait_again([], _queued_refs, %DateTime{}), do: []

  def wait_again(prebuilds, queued_refs, %DateTime{} = now) when is_list(prebuilds) do
    in_transaction!()

    superseded =
      prebuilds
      |> Enum.group_by(&{&1.source_collection_id, &1.pool_id})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, runs} -> wait_one(key, runs, Map.get(queued_refs, key), now) end)

    {_count, _rows} =
      Repo.update_all(
        from(r in DispatchRun,
          where: r.id in ^superseded and fragment("? = 'claimed'", r.state)
        ),
        set: [state: :ended, end_cause: :superseded, updated_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id in ^superseded,
          where: not is_nil(d.stale_at) and is_nil(d.ended_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    superseded
  end

  # The runs of one collection and pool that end `superseded`, the one that waits written.
  defp wait_one({collection_id, pool_id}, runs, queued_ref, now) do
    waiting =
      Repo.one(
        from w in DispatchRun,
          where: w.source_collection_id == ^collection_id and w.pool_id == ^pool_id,
          where: w.step == ^DispatchRun.prebuild() and fragment("? = 'waiting'", w.state),
          lock: "FOR UPDATE"
      )

    case waiting do
      %DispatchRun{} = waiting ->
        :ok = take_ref(waiting, queued_ref, now)
        Enum.map(runs, & &1.id)

      nil ->
        newest_first = Enum.sort_by(runs, &order/1, :desc)
        again = Enum.find(newest_first, &(&1.environment_ref == queued_ref)) || hd(newest_first)

        {1, _rows} =
          Repo.update_all(
            from(r in DispatchRun, where: r.id == ^again.id),
            set: [state: :waiting, updated_at: now] ++ ref(again, queued_ref, now)
          )

        for run <- runs, run.id != again.id, do: run.id
    end
  end

  # A prebuild that waits again takes the record's `queued_ref`, and when it took it,
  # when it has another; else it keeps its ref and when it took it.
  defp ref(%DispatchRun{environment_ref: ref}, ref, _now), do: []
  defp ref(%DispatchRun{}, nil, _now), do: []

  defp ref(%DispatchRun{}, queued_ref, now),
    do: [environment_ref: queued_ref, environment_ref_at: now]

  # The waiting prebuild takes the record's `queued_ref`, and when it took it, when it has
  # another.
  defp take_ref(%DispatchRun{environment_ref: ref}, ref, _now), do: :ok
  defp take_ref(%DispatchRun{}, nil, _now), do: :ok

  defp take_ref(%DispatchRun{id: id}, queued_ref, now) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id),
        set: [environment_ref: queued_ref, environment_ref_at: now, updated_at: now]
      )

    :ok
  end

  # When a prebuild was queued, the later the greater.
  defp order(%DispatchRun{queued_at: queued_at, inserted_at: inserted_at, id: id}),
    do:
      {DateTime.to_unix(queued_at, :microsecond), DateTime.to_unix(inserted_at, :microsecond), id}

  # The dispatches whose lease lapsed before their handover at `now`, with their slot
  # held: neither handed over, stale nor ended.
  defp lapsed(pool, now) do
    from(d in Dispatch,
      where: is_nil(d.slot_freed_at) and is_nil(d.handed_over_at),
      where: is_nil(d.stale_at) and is_nil(d.ended_at),
      where: d.lease_until <= ^now
    )
    |> of_pool(pool)
  end

  defp free_ended(pool, now) do
    {_count, rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: is_nil(d.slot_freed_at) and not is_nil(d.ended_at),
          select: d.workspace_id
        )
        |> of_pool(pool),
        set: [slot_freed_at: now, updated_at: now]
      )

    Enum.uniq(rows)
  end

  defp of_pool(query, :all), do: query

  defp of_pool(query, {:runs, run_ids}) when is_list(run_ids),
    do: from(d in query, where: d.dispatch_run_id in ^run_ids)

  defp of_pool(query, pool_id), do: from(d in query, where: d.pool_id == ^pool_id)

  defp in_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "the slots of a pool are freed inside the caller's transaction")
  end
end
