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
  #   neither handed over, stale nor ended) is marked stale at `now`, its slot freed, the
  #   run registered at its claim deleted with its run code
  #   (`Apiary.Dispatches.Handover.drop/1`), and its run, claimed, waits in its
  #   workspace's queue again with the same `run_id` and
  #   the same `queued_at`, so it takes back its place in the queue; except a prebuild
  #   whose collection, node pool and `environment_ref` have another prebuild waiting: one
  #   prebuild waits per collection, pool and `environment_ref`
  #   (`Apiary.Dispatches.queue_prebuild/3`). So, per collection, pool and ref, of its
  #   lapsed claimed prebuilds: while another waits, each ends, `superseded`; while none
  #   waits, the one queued last waits again, and each other ends `superseded`. A
  #   prebuild of a ref its collection no longer has waits again as well: the claim that
  #   takes it ends it, `superseded` (`Apiary.Dispatches`). A dispatch of a run that ends
  #   so ends with it (`run_ended`). A dispatch that ended with its slot still held has it
  #   freed.
  #   Whatever the state of the pool or of the key that claimed it: a deleted pool's or a
  #   revoked key's dispatch lapses at its `lease_until` as any other does. Its run then
  #   waits for the workspace's other pools, unless it is a prebuild: a lapsed prebuild
  #   waits again or ends as above, and the one that waits is still held for its pool,
  #   which alone may claim it. A deleted pool claims nothing: the sweep ends its waiting
  #   prebuilds `lost` (`Apiary.Dispatches.end_deleted_prebuilds/1`).
  #   It answers the ids of the workspaces whose queue or slots changed, for the caller to
  #   tell once its transaction commits (`Apiary.Dispatches.broadcast/1`).
  # - `free_slot/2` frees one dispatch's slot, for the paths that end a dispatch.
  #
  # **Locks.** Every path that locks more than one of these takes them in this order (a
  # free of more than one batch takes the records once, then the rest batch by batch, as
  # below says), so that no two paths wait on each other:
  #
  #   1. the collections (a listing's part, by ref, or an assign, by id, `FOR UPDATE`;
  #      `Apiary.Adapters.Collections`, whose lock order names what each holds before
  #      them, and the targets each makes after them; a Rebuild holds their connections
  #      `FOR SHARE`, by id, then them `FOR SHARE`, by id, `Apiary.Environments.rebuild/2`,
  #      and so do the end of a run whose image was missing,
  #      `Apiary.Environments.hold_missing/3`, and the end of a prebuild handed over,
  #      `Apiary.Environments.hold_build/2`; a claim holds the connections and then the
  #      collections it queues a build of, with the collections of its pool's lapsed
  #      prebuilds, `FOR SHARE`, by id, in one statement,
  #      `Apiary.Environments.hold_builds/3`). A path that
  #      holds a work item after them holds it next: the end of a prebuild handed over,
  #      the work items whose runs wait for its build, `FOR KEY SHARE`, by id; the end of
  #      a run whose image was missing, its work item `FOR UPDATE`;
  #   2. a node pool's row: a claim takes it `FOR NO KEY UPDATE` (`Apiary.Dispatches`), so
  #      a registration on the pool, which takes it `FOR UPDATE`
  #      (`Apiary.Nodes.check_instance_limit/3`), and another claim take turns with it,
  #      while the `FOR KEY SHARE` that a prebuild's writes take for their foreign keys to
  #      the pool never waits on it;
  #   3. the environment records, `FOR UPDATE`, by collection and then pool, each path in
  #      one statement: a Rebuild locks every record of its collections before it queues
  #      one prebuild (`Apiary.Environments.rebuild/2`), and `free/2` the records of every
  #      prebuild whose dispatch lapsed in its scope, those of every batch, before its
  #      first batch locks a run. A path inserts a missing record only after that
  #      statement, by collection: a Rebuild's prebuild inserts the record of its pool
  #      where there is none (`Apiary.Dispatches.queue_prebuild/3`), and a claim's free,
  #      after its statement and before its first batch, inserts the missing records of
  #      the collections it queues a build of (`Apiary.Environments.make_records/2`). A
  #      lock statement never waits on an insert not yet committed, so two such paths
  #      wait on each other only among their inserts, which both make in one order. The
  #      free reads the records before their lock, as a run's collection and pool never
  #      change. A prebuild seen lapsed only after that statement, its dispatch or its
  #      record committed after it, is taken only when its record is
  #      already locked, and is left for the next free otherwise. The free of an undo or a
  #      close, of the runs of work items, locks none;
  #   4. the runs of the queue whose dispatch lapsed, `FOR UPDATE`, by id (`free/2`), and
  #      the runs `Apiary.Dispatches` ends for an undo or a close; a run of the queue is
  #      locked before the run registered for it (`Apiary.Dispatches.RunEnd`), as every
  #      path that locks both does. The free of such an end, of a run handed over, comes
  #      after the end has ended each of its dispatches, so it finds none lapsed and locks
  #      no record;
  #   5. the waiting runs: the one prebuild that waits per collection, pool and
  #      `environment_ref`, which a Rebuild, the end of a run whose image was missing and
  #      the end of a prebuild lost once write, and `free/2` reads `FOR UPDATE`, each under
  #      the record's lock, and which a claim writes under the pool's row
  #      (`Apiary.Environments.queue_builds/2`); a claim takes a waiting run
  #      `FOR UPDATE SKIP LOCKED`, which waits on none;
  #   6. the dispatches.
  #
  # A claim (`Apiary.Dispatches`) keeps the order: the connections and the collections it
  # queues a build of or whose lapsed prebuilds its free writes, as 1., then the pool's
  # row, as 2., then the gateway's row `FOR SHARE`, then the free of its pool, which
  # inserts the missing records of the collections it queues a build of after its record
  # statement, as 3., then the prebuilds it queues, as 5., whose records exist by then,
  # then the waiting run it takes, as 5., and its dispatch, inserted; then, for an
  # explore run, the rows of the model
  # providers its choices name and of their keys' secrets, each `FOR SHARE`
  # (`Apiary.Dispatches.RunSettings`), which no path that locks anything above locks
  # after, and the run it registers (`Apiary.Dispatches.Handover.register/2`), as a run
  # of the queue is locked before the run registered for it. A `dispatched` keeps it too:
  # the free of its run, its run of the queue, then its dispatch.
  #
  # A release (`Apiary.Dispatches.Release`) keeps it as well, and holds one row before
  # the free of its run: for an explore run, its work item `FOR UPDATE`, as a close
  # (`Apiary.WorkItems.close_locked/3`) and `Apiary.Dispatches.queue_next/2` hold a work
  # item before its runs; for a prebuild, its environment record `FOR UPDATE`, as 3.
  # has it. Then the free of its run, which locks that record again where its lease
  # lapsed, its run of the queue, and its dispatch. A prebuild given back locks the one
  # that waits of its collection, pool and ref after its dispatch (`wait_again/2`): under
  # the record it holds, which every path that locks the one that waits holds first, but
  # a claim, whose `FOR UPDATE SKIP LOCKED` waits on none and which writes one only
  # while none of that ref is waiting, claimed or handed over, under the pool's row that
  # the free of the pool's lapsed leases holds too. A path that locks a work item
  # locks it before any run of the queue, with one exception, the claim: its free sets a
  # lapsed run back to waiting, the claim then takes that run and writes it again, and
  # Postgres checks the second write's foreign key with a `FOR KEY SHARE` lock on the
  # work item, taken after the claim holds the run of the queue. A release that holds
  # that work item and waits on that run can then deadlock with the claim: Postgres
  # aborts one side (40P01), the aborted side returns `{:error, :unavailable}`, and the
  # starter retries its call. The order of the queue does not change.
  #
  # The end of a prebuild handed over (`Apiary.Dispatches.RunEnd`), by the lost-run check
  # or by its exit, keeps it too: the connections and then the live collections of its
  # target that name an `environment_ref` `FOR SHARE`, by id, as 1. has a Rebuild hold
  # them, then the work items in Explore whose runs wait for its build `FOR KEY SHARE`,
  # by id, then the prebuild's environment record `FOR UPDATE`, as 3. has it, then its run
  # of the queue, its registered run and its dispatches; then, for a first loss of its
  # ref, the prebuild it queues again, as 5., or, for a failure, the waiting runs of those
  # work items it ends `build_failed`; then the free of its run, which finds none lapsed.
  # The sweep's end of a waiting prebuild of a deleted pool
  # (`Apiary.Dispatches.end_deleted_prebuilds/1`) holds the same rows in the same order,
  # then locks the run of the queue, its dispatches, and the waiting runs it ends
  # `build_failed`.
  # The end of any other run handed over, by the check or by an exit's projection, holds
  # its work item `FOR KEY SHARE` in place of the rows before the record, then the same.
  # The end of such a run whose exit says its image was missing first holds the
  # connections and then the collections of the records of that image `FOR SHARE`, by id,
  # as 1. has a Rebuild hold them, then its work item `FOR UPDATE`, then those records
  # `FOR UPDATE`, as 3. has them, then the same, then the prebuilds it queues, as 5., and
  # the next run of its take in, inserted under its work item's lock, as
  # `Apiary.Dispatches.queue_next/2` inserts one.
  #
  # So a prebuild comes to wait under the lock of its record, or, for a claim, under the
  # pool's row, and whoever comes second sees what the first wrote, or, at the index of
  # the waiting ones, finds the first's; a claim that takes or ends the one that waits
  # holds its row, and whoever reads it `FOR UPDATE` meanwhile reads it again once the
  # claim commits. The records come before the runs: a run `free/2` locks by its id may
  # have gone back to waiting meanwhile, and a Rebuild that holds the record waits for
  # that run's lock. A claim whose free set a lapsed prebuild back to waiting and that
  # then takes or ends it writes it a second time, and so does a claim that takes a
  # prebuild it queued: Postgres checks that write's foreign key with a `FOR KEY SHARE`
  # lock on the collection, which would wait for a path that holds the collection
  # `FOR UPDATE`, such as a listing's part, an assign, a Backlog switch or an adapter's
  # start (`Apiary.Adapters.Collections`). So the claim holds every such collection
  # `FOR SHARE` before anything but the connections, in one statement, by id: the
  # collections of the pool's prebuilds whose dispatch lapsed at its `now`
  # (`lapsed_collections/2`) and those it queues a build of. A path that holds
  # collections `FOR UPDATE` then waits for the claim at the first of them the claim
  # holds, or the claim waits there for that path before it holds any collection or the
  # pool, and the claim's later `FOR KEY SHARE` meets only the claim's `FOR SHARE` lock
  # on the same row. A part, which holds its connection `FOR UPDATE` first, can also
  # wait at a connection the claim holds `FOR SHARE`, before it holds any collection of
  # it. So neither waits on the other in turn. A dispatch claimed after the claim read
  # the lapsed ones has a lease past the claim's `now`, so the claim's free finds no
  # lapsed dispatch the claim did not read.
  # `free/2` writes the dispatches with each write asking its conditions again, so a
  # dispatch handed over, ended or freed meanwhile is left as it is.
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

  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover}
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
  # workspaces whose queue or slots changed. `records` runs once the environment records
  # are locked and before any run is: a claim makes there the records of the builds it
  # queues (`Apiary.Environments.make_records/2`), so it writes records before runs.
  @doc false
  @spec free(
          Ecto.UUID.t() | :all | {:runs, [Ecto.UUID.t()]},
          DateTime.t(),
          (-> :ok)
        ) :: [Ecto.UUID.t()]
  def free(pool, %DateTime{} = now, records_made \\ fn -> :ok end)
      when (is_binary(pool) or pool == :all or
              (is_tuple(pool) and tuple_size(pool) == 2 and elem(pool, 0) == :runs)) and
             is_function(records_made, 0) do
    in_transaction!()
    records = lock_records(pool, now)
    :ok = records_made.()
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

        claimed = Enum.filter(runs, &(MapSet.member?(stale_runs, &1.id) and &1.state == :claimed))
        {prebuilds, others} = Enum.split_with(claimed, &(&1.step == DispatchRun.prebuild()))

        # The runs registered at their claims go, with their run codes.
        _dropped = Handover.drop(Enum.map(claimed, & &1.id))

        {_count, _rows} =
          Repo.update_all(
            from(r in DispatchRun,
              where: r.id in ^Enum.map(others, & &1.id),
              where: fragment("? = 'claimed'", r.state)
            ),
            set: [state: :waiting, updated_at: now]
          )

        _superseded = wait_again(prebuilds, now)
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

  # Locks, `FOR UPDATE`, in one statement, by collection and then pool, the environment
  # records of the collections and pools of every prebuild whose dispatch lapsed at `now`
  # in the scope `pool`, of every batch, before the first batch locks a run: their ids. A
  # run's collection and pool never change, so they are read before its lock.
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
          select: e.id
      )

    %{ids: locked}
  end

  # lapsed_collections/2 is the ids of the collections of the claimed prebuilds of the
  # node pool `pool_id` whose dispatch lapsed at `now`, read without a lock: the
  # collections whose prebuilds a free of the pool at `now` writes, which a claim holds
  # `FOR SHARE` with the ones it queues a build of, before the pool's row
  # (`Apiary.Environments.hold_builds/3`; the moduledoc).
  @doc false
  @spec lapsed_collections(Ecto.UUID.t(), DateTime.t()) :: [Ecto.UUID.t()]
  def lapsed_collections(pool_id, %DateTime{} = now) when is_binary(pool_id) do
    Repo.all(
      from d in lapsed(pool_id, now),
        join: r in DispatchRun,
        on: r.id == d.dispatch_run_id,
        where: r.step == ^DispatchRun.prebuild() and not is_nil(r.source_collection_id),
        distinct: true,
        select: r.source_collection_id
    )
  end

  # wait_again/2 takes the claimed `prebuilds`, whose dispatch lapsed or was released
  # before its handover, back to the queue, under the lock of their environment records,
  # which the caller holds, per collection, pool and `environment_ref`: while another
  # prebuild of that ref waits, each ends `superseded`; else the one queued last waits
  # again, with its `run_id`, its `queued_at` and its ref, and the others end
  # `superseded`. Their stale dispatches end with them (`run_ended`). The ids of the runs
  # that ended `superseded`.
  @doc false
  @spec wait_again([DispatchRun.t()], DateTime.t()) :: [Ecto.UUID.t()]
  def wait_again([], %DateTime{}), do: []

  def wait_again(prebuilds, %DateTime{} = now) when is_list(prebuilds) do
    in_transaction!()

    superseded =
      prebuilds
      |> Enum.group_by(&{&1.source_collection_id, &1.pool_id, &1.environment_ref})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, runs} -> wait_one(key, runs, now) end)

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

  # The runs of one collection, pool and `environment_ref` that end `superseded`, the one
  # that waits again written.
  defp wait_one({collection_id, pool_id, ref}, runs, now) do
    waiting =
      Repo.one(
        from w in DispatchRun,
          where: w.source_collection_id == ^collection_id and w.pool_id == ^pool_id,
          where: w.step == ^DispatchRun.prebuild() and w.environment_ref == ^ref,
          where: fragment("? = 'waiting'", w.state),
          lock: "FOR UPDATE"
      )

    case waiting do
      %DispatchRun{} ->
        Enum.map(runs, & &1.id)

      nil ->
        [again | others] = Enum.sort_by(runs, &order/1, :desc)

        {1, _rows} =
          Repo.update_all(
            from(r in DispatchRun, where: r.id == ^again.id),
            set: [state: :waiting, updated_at: now]
          )

        Enum.map(others, & &1.id)
    end
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
