defmodule Apiary.Environments do
  @moduledoc false

  # The environment records of the collections (`Apiary.Environments.Record`), one per
  # node pool and collection: what the last prebuild of a collection's target built for a
  # pool, and what was asked of it.
  #
  # The reads here serve the paths that queue, record and use a build: they ask nothing
  # of `Apiary.Access`, and whoever answers a person with them asks it first.
  #
  # ## The trigger: `trigger/2` and `trigger_for_pool/2`
  #
  # A prebuild is queued for a collection and a node pool (`Apiary.Dispatches.queue_prebuild/3`,
  # held for that pool) when the collection is live, assigned to the pool's workspace, has a
  # target and an `environment_ref`, and the pool's record of it is missing, was queued
  # for another `environment_ref` or another target, or was retired after it was last
  # queued: the trigger is keyed on the target and the `environment_ref`. Queuing
  # sets the record's `queued_ref`, `queued_at` and queued target (`queued_target_system`,
  # `queued_target_path`), making the record when there was none. So the same
  # `environment_ref` named again for the same target queues nothing, and a target that
  # changes with the same `environment_ref` queues a prebuild. A change while a prebuild of
  # the collection waits for the pool sets the change's `environment_ref` on that waiting
  # one, in the same transaction as the record's `queued_ref`, so at most one waits per
  # collection and pool; a change while one is claimed or runs queues the one that waits
  # next.
  #
  # `trigger(collections, now)` applies it, inside the caller's transaction, to
  # collections as they now stand, for every live pool of each one's workspace: a
  # listing's part calls it for the collections it made or updated, and an assign for
  # those it assigned or moved to a workspace (`Apiary.Adapters.Collections`). A collection
  # without an `environment_ref` queues nothing, its records not retired since they were
  # last queued are retired at `now`, and its prebuilds that wait end, `collection_ended`
  # (`Apiary.Dispatches.end_waiting_prebuilds/2`): the image goes from new runs, nothing
  # is left to build, and the record keeps the rest. A collection assigned to no
  # workspace, or without a target, queues nothing.
  #
  # `trigger_for_pool(pool, now)` applies it, inside the caller's transaction, to a new
  # node pool, for every collection assigned to its workspace (`Apiary.Nodes.create_node/2`).
  #
  # `trigger/2` first locks every record of its collections, of every pool, `FOR UPDATE`,
  # in one statement, by collection and then pool, whatever order its caller names them
  # in; a free of lapsed leases locks the records of every claimed prebuild that lapsed
  # in its scope in the same order, in one statement, before its first batch decides
  # which prebuild waits (`Apiary.Dispatches.Slots`, which names the order of every
  # lock). The record is then written by one statement that decides whether it is
  # due (`INSERT … ON CONFLICT … DO UPDATE … WHERE`), so two triggers at once for the same
  # pool and collection take turns, and the second sees the first's `queued_ref`; and the
  # prebuild that waits is one per pool and collection in the database too
  # (`Apiary.Dispatches.queue_prebuild/3`). A caller calls `trigger/2` once per
  # transaction: two calls would lock in two orders.
  #
  # ## A build given back: `lock_record/2` and `record_release_failure/3`
  #
  # `lock_record(pool_id, collection_id)` locks the record of a prebuild's pool and
  # collection `FOR UPDATE`, inside the caller's transaction: a starter's release of the
  # prebuild holds it before the free of its run and before its run of the queue, as a
  # free of lapsed leases holds it (`Apiary.Dispatches.Release`, `Apiary.Dispatches.Slots`).
  # `record_release_failure(record, reason, now)` then records the last build as failed,
  # `released`, with the starter's `reason` and `now`: the last good build, `image`,
  # `size`, `commit`, `built_at` and `reported_ref`, is left as it was, and nothing is
  # queued. A release of a prebuild whose ref is older than the image's records nothing
  # (`newer_build?/2`).
  #
  # ## A build lost: `record_end_failure/3`
  #
  # `record_end_failure(record, cause, now)` records the last build as failed when the
  # lost-run check ends a prebuild after its handover (`Apiary.Dispatches.RunEnd`), on the
  # record of its collection and of the pool that claimed it, which the check locks with
  # `lock_record/2` before its run of the queue: `lost` when the prebuild's gateway never
  # attached it by its run key's `attach_by`, `timed_out` when it had neither an outcome
  # nor an exit by its backstop, with `now` and no reason. The last good build is left as
  # it was, and nothing is queued. A prebuild whose ref is older than the image's records
  # nothing (`newer_build?/2`).
  #
  # ## A run's image: `image_for/2`
  #
  # `image_for(pool, target)` is the image a run of `pool` for `target` starts in: of the
  # live collections assigned to the pool's workspace with that target, only those with an
  # `environment_ref` count, and of their records for the pool built for that target
  # (`built_target_system`, `built_target_path`), the one built last (`built_at`)
  # that is not retired gives its `image`; nil when there is none, and the run starts in
  # the pool's default. A record whose image was built for another target gives none,
  # until a prebuild for its target lands.
  #
  # ## A build recorded: `record_build/4`
  #
  # `record_build(dispatch_run, build, built_target, now)` records the build a prebuild's
  # `prebuilt` reported (`Apiary.Dispatches.Prebuilt`) on the record of its pool and
  # collection, which the caller locked first (`lock_record/2`): `image`, `size`, `commit`,
  # `reported_ref`, the `environment_ref` the job reported, kept as it is even when it
  # differs from `queued_ref`, `built_at`, `now`, and the built target
  # (`built_target_system`, `built_target_path`), the registered run's target. The last
  # failure is cleared, and the queued ref and the queued target are left as they are;
  # nothing is queued. `retired_at` is cleared only when the build's run took its ref
  # (`environment_ref_at`) after the record was retired: the ref came back and this build
  # is of it, so the record is served again. A build whose run took its ref before the
  # retirement, one claimed before the collection's `environment_ref` went absent and
  # landing late, is stored and the record stays retired, even when a new ref has come
  # since. A record that is missing is made with the
  # build, queued for the run's `environment_ref` when the run was queued, and for the
  # built target. `built_queued_at` is written with the image: when the run took the
  # `environment_ref` it built (`environment_ref_at`), which a wait again or a change while
  # it waits sets anew, where its `queued_at` stays.
  #
  # ## A build whose ref is older than the image's: `newer_build?/2`
  #
  # `newer_build?(record, dispatch_run)` is whether the image `record` keeps was made by a
  # prebuild that took its `environment_ref` after `dispatch_run` took its
  # (`built_queued_at` later than the run's `environment_ref_at`), asked under the record's
  # lock: the run's ref is older than the image's, and an older build never replaces a
  # newer one. Then neither a `prebuilt` nor a
  # failure of `dispatch_run` is written on the record: the image and the last build's
  # failure stay as they are, and the run ends as it would otherwise. A record that is
  # missing, or keeps no `built_queued_at`, as a record with no image, is never newer, and
  # every writer writes it as before.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Adapters.Collection
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node

  # fetch/2 is the record of the pool `pool_id` and the collection `collection_id`, or nil.
  @doc false
  @spec fetch(Ecto.UUID.t(), Ecto.UUID.t()) :: Record.t() | nil
  def fetch(pool_id, collection_id) when is_binary(pool_id) and is_binary(collection_id),
    do: Repo.get_by(Record, pool_id: pool_id, source_collection_id: collection_id)

  # for_collection/1 is every record of the collection `collection_id`, of any pool and
  # workspace, the oldest first.
  @doc false
  @spec for_collection(Ecto.UUID.t()) :: [Record.t()]
  def for_collection(collection_id) when is_binary(collection_id) do
    Repo.all(
      from r in Record,
        where: r.source_collection_id == ^collection_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  ## A build given back

  # lock_record/2 locks the record of the pool `pool_id` and the collection
  # `collection_id` `FOR UPDATE`, inside the caller's transaction: the record, or nil.
  @doc false
  @spec lock_record(Ecto.UUID.t(), Ecto.UUID.t()) :: Record.t() | nil
  def lock_record(pool_id, collection_id) when is_binary(pool_id) and is_binary(collection_id) do
    in_transaction!("lock_record/2")

    Repo.one(
      from r in Record,
        where: r.pool_id == ^pool_id and r.source_collection_id == ^collection_id,
        lock: "FOR UPDATE"
    )
  end

  # record_release_failure/3 records the last build of `record`, locked by
  # `lock_record/2`, as failed by the starter's release, with its `reason`, at `now`,
  # inside the caller's transaction (the moduledoc).
  @doc false
  @spec record_release_failure(Record.t(), String.t(), DateTime.t()) :: :ok
  def record_release_failure(%Record{id: id}, reason, %DateTime{} = now)
      when is_binary(id) and is_binary(reason) do
    in_transaction!("record_release_failure/3")

    {1, _rows} =
      Repo.update_all(from(r in Record, where: r.id == ^id),
        set: [failure_cause: :released, failure_reason: reason, failed_at: now, updated_at: now]
      )

    :ok
  end

  # record_end_failure/3 records the last build of `record`, locked by `lock_record/2`,
  # as failed by the end of its prebuild, `cause` (`:lost` or `:timed_out`), at `now`,
  # inside the caller's transaction (the moduledoc).
  @doc false
  @spec record_end_failure(Record.t(), :lost | :timed_out, DateTime.t()) :: :ok
  def record_end_failure(%Record{id: id}, cause, %DateTime{} = now)
      when is_binary(id) and cause in [:lost, :timed_out] do
    in_transaction!("record_end_failure/3")

    {1, _rows} =
      Repo.update_all(from(r in Record, where: r.id == ^id),
        set: [failure_cause: cause, failure_reason: nil, failed_at: now, updated_at: now]
      )

    :ok
  end

  ## A run's image

  # image_for/2 is the image a run of `pool` for `target` starts in, or nil (the
  # moduledoc).
  @doc false
  @spec image_for(Node.t(), %{system: String.t(), path: String.t()}) :: String.t() | nil
  def image_for(%Node{kind: :pool, id: pool_id, workspace_id: workspace_id}, %{
        system: system,
        path: path
      })
      when is_binary(workspace_id) and is_binary(system) and is_binary(path) do
    Repo.one(
      from r in Record,
        join: c in Collection,
        on: c.id == r.source_collection_id,
        where: r.pool_id == ^pool_id and not is_nil(r.image) and is_nil(r.retired_at),
        where: r.built_target_system == ^system and r.built_target_path == ^path,
        where: c.workspace_id == ^workspace_id and is_nil(c.ended_at),
        where: not is_nil(c.environment_ref),
        where: c.target_system == ^system and c.target_path == ^path,
        order_by: [desc: r.built_at, desc: r.id],
        limit: 1,
        select: r.image
    )
  end

  ## A build whose ref is older than the image's

  # newer_build?/2 is whether the image of `record`, locked by `lock_record/2`, was made by
  # a prebuild that took its `environment_ref` after `dispatch_run` took its (the
  # moduledoc).
  @doc false
  @spec newer_build?(Record.t() | nil, Apiary.Dispatches.DispatchRun.t()) :: boolean
  def newer_build?(
        %Record{built_queued_at: %DateTime{} = built_queued_at},
        %Apiary.Dispatches.DispatchRun{environment_ref_at: %DateTime{} = ref_at}
      ),
      do: DateTime.compare(ref_at, built_queued_at) == :lt

  def newer_build?(_record, %Apiary.Dispatches.DispatchRun{}), do: false

  ## A build recorded

  # record_build/4 records the build of the prebuild `dispatch_run` its `prebuilt`
  # reported, built for `built_target` (nil for none), at `now`, inside the caller's
  # transaction, which locked the record first (the moduledoc).
  @doc false
  @spec record_build(
          Apiary.Dispatches.DispatchRun.t(),
          %{
            image: String.t(),
            size: pos_integer,
            commit: String.t(),
            environment_ref: String.t()
          },
          %{system: String.t(), path: String.t()} | nil,
          DateTime.t()
        ) :: :ok
  def record_build(
        %Apiary.Dispatches.DispatchRun{pool_id: pool_id, source_collection_id: collection_id} =
          run,
        %{image: image, size: size, commit: commit, environment_ref: reported_ref},
        built_target,
        %DateTime{} = now
      )
      when is_binary(pool_id) and is_binary(collection_id) do
    in_transaction!("record_build/4")

    {system, path} =
      if built_target, do: {built_target.system, built_target.path}, else: {nil, nil}

    built = [
      image: image,
      size: size,
      commit: commit,
      built_at: now,
      reported_ref: reported_ref,
      built_target_system: system,
      built_target_path: path,
      built_queued_at: run.environment_ref_at,
      failure_cause: nil,
      failure_reason: nil,
      failed_at: nil,
      updated_at: now
    ]

    row =
      Map.new(built)
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        pool_id: pool_id,
        source_collection_id: collection_id,
        queued_ref: run.environment_ref,
        queued_at: run.queued_at,
        queued_target_system: system,
        queued_target_path: path,
        inserted_at: now
      })

    # A retired record is served again only by a build whose run took its ref after the
    # retirement: an older build, claimed before the ref went absent, leaves it retired.
    ref_at = run.environment_ref_at

    on_conflict =
      from r in Record,
        update: [
          set: ^built,
          set: [
            retired_at:
              fragment(
                "CASE WHEN ? < ? THEN NULL ELSE ? END",
                r.retired_at,
                type(^ref_at, :utc_datetime_usec),
                r.retired_at
              )
          ]
        ]

    {1, _rows} =
      Repo.insert_all(Record, [row],
        on_conflict: on_conflict,
        conflict_target: [:pool_id, :source_collection_id]
      )

    :ok
  end

  ## The trigger

  # trigger/2 applies the trigger to `collections` as they now stand, at `now`, inside
  # the caller's transaction (the moduledoc): the prebuilds it queued.
  @doc false
  @spec trigger([Collection.t()], DateTime.t()) :: [Apiary.Dispatches.DispatchRun.t()]
  def trigger(collections, %DateTime{} = now) when is_list(collections) do
    in_transaction!("trigger/2")

    :ok = lock_records(collections)
    {absent, present} = Enum.split_with(collections, &is_nil(&1.environment_ref))
    :ok = retire(absent, now)
    due = Enum.filter(present, &due?/1)
    pools = pools(due |> Enum.map(& &1.workspace_id) |> Enum.uniq())

    for collection <- Enum.sort_by(due, & &1.id),
        run <- queue(collection, Map.get(pools, collection.workspace_id, []), now),
        do: run
  end

  # trigger_for_pool/2 applies the trigger to the new node pool `pool`, at `now`, for
  # every collection assigned to its workspace, inside the caller's transaction (the
  # moduledoc): the prebuilds it queued.
  @doc false
  @spec trigger_for_pool(Node.t(), DateTime.t()) :: [Apiary.Dispatches.DispatchRun.t()]
  def trigger_for_pool(
        %Node{kind: :pool, deleted_at: nil, workspace_id: workspace_id} = pool,
        now
      )
      when is_binary(workspace_id) do
    in_transaction!("trigger_for_pool/2")

    collections =
      Repo.all(
        from c in Collection,
          where: c.workspace_id == ^workspace_id and is_nil(c.ended_at),
          where: not is_nil(c.environment_ref) and not is_nil(c.target_system),
          order_by: c.id
      )

    for collection <- collections, run <- queue(collection, [pool], now), do: run
  end

  # A live collection assigned to a workspace, with a target and an `environment_ref`.
  defp due?(%Collection{ended_at: nil, workspace_id: workspace_id, target_system: system}),
    do: is_binary(workspace_id) and is_binary(system)

  defp due?(%Collection{}), do: false

  # The live node pools of `workspace_ids`, by workspace, each list by id.
  defp pools([]), do: %{}

  defp pools(workspace_ids) do
    Repo.all(
      from n in Node,
        where: n.workspace_id in ^workspace_ids and n.kind == :pool and is_nil(n.deleted_at),
        order_by: n.id
    )
    |> Enum.group_by(& &1.workspace_id)
  end

  # Locks the records of `collections`, of every pool, `FOR UPDATE`, by collection and
  # then pool, in one statement, before any of them is written (the moduledoc).
  defp lock_records([]), do: :ok

  defp lock_records(collections) do
    ids = Enum.map(collections, & &1.id)

    _locked =
      Repo.all(
        from r in Record,
          where: r.source_collection_id in ^ids,
          order_by: [r.source_collection_id, r.pool_id],
          lock: "FOR UPDATE",
          select: r.id
      )

    :ok
  end

  # Retires, at `now`, the records of `collections` not retired since they were last
  # queued, and ends their prebuilds that wait, `collection_ended`.
  defp retire([], _now), do: :ok

  defp retire(collections, now) do
    ids = Enum.map(collections, & &1.id)

    {_count, _rows} =
      Repo.update_all(
        from(r in Record,
          where: r.source_collection_id in ^ids,
          where: is_nil(r.retired_at) or r.retired_at < r.queued_at
        ),
        set: [retired_at: now, updated_at: now]
      )

    Dispatches.end_waiting_prebuilds(ids, now)
  end

  # Writes the record of `collection` for each of `pools` that is due, in one statement,
  # and queues a prebuild held for each of those pools: due when the record is new, was
  # queued for another `environment_ref` or another target, or was retired after it was
  # last queued.
  defp queue(_collection, [], _now), do: []

  defp queue(%Collection{environment_ref: ref} = collection, pools, now) do
    rows =
      for pool <- pools do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: collection.organisation_id,
          workspace_id: pool.workspace_id,
          pool_id: pool.id,
          source_collection_id: collection.id,
          queued_ref: ref,
          queued_at: now,
          queued_target_system: collection.target_system,
          queued_target_path: collection.target_path,
          inserted_at: now,
          updated_at: now
        }
      end

    due =
      from r in Record,
        where:
          r.queued_ref != fragment("EXCLUDED.queued_ref") or
            fragment("? IS DISTINCT FROM EXCLUDED.queued_target_system", r.queued_target_system) or
            fragment("? IS DISTINCT FROM EXCLUDED.queued_target_path", r.queued_target_path) or
            (not is_nil(r.retired_at) and r.queued_at < r.retired_at),
        update: [
          set: [
            queued_ref: fragment("EXCLUDED.queued_ref"),
            queued_at: fragment("EXCLUDED.queued_at"),
            queued_target_system: fragment("EXCLUDED.queued_target_system"),
            queued_target_path: fragment("EXCLUDED.queued_target_path"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]

    {_count, written} =
      Repo.insert_all(Record, rows,
        on_conflict: due,
        conflict_target: [:pool_id, :source_collection_id],
        returning: [:pool_id]
      )

    queued = MapSet.new(written, & &1.pool_id)

    for pool <- pools, MapSet.member?(queued, pool.id) do
      {:ok, run} = Dispatches.queue_prebuild(collection, pool, ref)
      run
    end
  end

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.Environments.#{what} runs inside the caller's transaction")
  end
end
