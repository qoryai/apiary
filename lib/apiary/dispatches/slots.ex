defmodule Apiary.Dispatches.Slots do
  @moduledoc false

  # The slots of a node pool's instance limit its claims take (the provisioner contract's
  # `claim.schema.json`): each dispatch takes one at its claim, and its slot is freed
  # once, at the first of its release, the lapse of its lease before its handover, its end
  # before its handover because its work item was closed or undone, or its run's end.
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
  #   the same `queued_at`, so it takes back its place in the queue; a dispatch that ended
  #   with its slot still held has it freed. Whatever the state of the pool or of the key
  #   that claimed it: a deleted pool's or a revoked key's dispatch lapses at its
  #   `lease_until` as any other does, and its run waits for the workspace's other pools.
  #   It answers the ids of the workspaces whose queue or slots changed, for the caller to
  #   tell once its transaction commits (`Apiary.Dispatches.broadcast/1`).
  # - `free_slot/2` frees one dispatch's slot, for the paths that end a dispatch.
  #
  # **Locks.** A run of the queue is locked before its dispatch, as every path that locks
  # both does, so that no two of them wait on each other: `free/2` locks the runs of the
  # lapsed dispatches `FOR UPDATE`, in the order of their ids, and only then writes the
  # dispatches, each write asking its conditions again, so a dispatch handed over, ended or
  # freed meanwhile is left as it is. Every function here runs inside the caller's
  # transaction.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Repo

  # The lapsed dispatches one statement writes at most; `free/2` goes on until none is
  # left.
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
    lapsed = lapse(pool, now, [])
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

  defp lapse(pool, now, workspaces) do
    candidates =
      from(d in lapsed(pool, now),
        order_by: d.dispatch_run_id,
        limit: @batch,
        select: {d.id, d.dispatch_run_id}
      )
      |> Repo.all()

    case candidates do
      [] ->
        workspaces

      _some ->
        {ids, run_ids} = Enum.unzip(candidates)

        # The runs first, then their dispatches.
        _locked =
          Repo.all(
            from r in DispatchRun,
              where: r.id in ^run_ids,
              order_by: r.id,
              lock: "FOR UPDATE",
              select: r.id
          )

        {_count, stale} =
          Repo.update_all(
            from(d in lapsed(pool, now),
              where: d.id in ^ids,
              select: {d.dispatch_run_id, d.workspace_id}
            ),
            set: [stale_at: now, slot_freed_at: now, updated_at: now]
          )

        {stale_runs, stale_workspaces} = Enum.unzip(stale)

        {_count, _rows} =
          Repo.update_all(
            from(r in DispatchRun,
              where: r.id in ^stale_runs and fragment("? = 'claimed'", r.state)
            ),
            set: [state: :waiting, updated_at: now]
          )

        workspaces = Enum.uniq(stale_workspaces ++ workspaces)

        # Another batch, while a whole one lapsed.
        if length(candidates) == @batch,
          do: lapse(pool, now, workspaces),
          else: workspaces
    end
  end

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
