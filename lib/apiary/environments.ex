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
  # held for that pool) when the collection is live, linked to the pool's workspace, has a
  # target and an `environment_ref`, and the pool's record of it is missing, was queued
  # for another `environment_ref`, or was retired after it was last queued. Queuing sets
  # the record's `queued_ref` and `queued_at`, making the record when there was none. So
  # the same `environment_ref` named again queues nothing, and a change while a build waits
  # or runs queues its own build, never folded into that one.
  #
  # `trigger(collections, now)` applies it, inside the caller's transaction, to
  # collections as they now stand, for every live pool of each one's workspace: a
  # listing's part calls it for the collections it made or updated, and an assign for
  # those it linked or moved to a workspace (`Apiary.Adapters.Collections`). A collection
  # without an `environment_ref` queues nothing, and its records that are not retired yet
  # are retired at `now`: the image goes from new runs, and the record keeps the rest. A
  # collection linked to no workspace, or without a target, queues nothing.
  #
  # `trigger_for_pool(pool, now)` applies it, inside the caller's transaction, to a new
  # node pool, for every collection linked to its workspace (`Apiary.Nodes.create_node/2`).
  #
  # The record is written by one statement that decides, under the row's lock, whether it
  # is due (`INSERT … ON CONFLICT … DO UPDATE … WHERE`), so two triggers at once for the
  # same pool and collection queue one prebuild.

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

  ## The trigger

  # trigger/2 applies the trigger to `collections` as they now stand, at `now`, inside
  # the caller's transaction (the moduledoc): the prebuilds it queued.
  @doc false
  @spec trigger([Collection.t()], DateTime.t()) :: [Apiary.Dispatches.DispatchRun.t()]
  def trigger(collections, %DateTime{} = now) when is_list(collections) do
    in_transaction!("trigger/2")

    {absent, present} = Enum.split_with(collections, &is_nil(&1.environment_ref))
    :ok = retire(absent, now)
    due = Enum.filter(present, &due?/1)
    pools = pools(due |> Enum.map(& &1.workspace_id) |> Enum.uniq())

    for collection <- Enum.sort_by(due, & &1.id),
        run <- queue(collection, Map.get(pools, collection.workspace_id, []), now),
        do: run
  end

  # trigger_for_pool/2 applies the trigger to the new node pool `pool`, at `now`, for
  # every collection linked to its workspace, inside the caller's transaction (the
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

  # A live collection linked to a workspace, with a target and an `environment_ref`.
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

  # Retires, at `now`, the records not yet retired of `collections`.
  defp retire([], _now), do: :ok

  defp retire(collections, now) do
    ids = Enum.map(collections, & &1.id)

    {_count, _rows} =
      Repo.update_all(
        from(r in Record, where: r.source_collection_id in ^ids and is_nil(r.retired_at)),
        set: [retired_at: now, updated_at: now]
      )

    :ok
  end

  # Writes the record of `collection` for each of `pools` that is due, in one statement,
  # and queues a prebuild held for each of those pools.
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
          inserted_at: now,
          updated_at: now
        }
      end

    due =
      from r in Record,
        where:
          r.queued_ref != fragment("EXCLUDED.queued_ref") or
            (not is_nil(r.retired_at) and r.queued_at < r.retired_at),
        update: [
          set: [
            queued_ref: fragment("EXCLUDED.queued_ref"),
            queued_at: fragment("EXCLUDED.queued_at"),
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
