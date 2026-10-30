defmodule Apiary.Dispatches do
  @moduledoc false

  # The runs a workspace's node pools claim and start, as the provisioner contract has
  # them (qoryai/integrations, `contracts/provisioner/v1`): one queue per workspace, which
  # any node pool of the workspace claims from with its pool's access key
  # (`Apiary.Dispatches.DispatchRun`, `Apiary.Dispatches.Dispatch`). The instance's pool,
  # with no organisation and no workspace, claims from the queue of every workspace with
  # no pool in use.
  #
  # ## Queueing: `queue/2`, `queue_next/2`, `cancel_for_undo/1` and `cancel_for_close/2`
  #
  # `queue(work_item, take_in)` writes, inside the caller's transaction, the first run of a
  # take in of `work_item`: waiting, `attempt` 1 of `of/0`, for the step `step/0`, in the
  # workspace the work item is in as the transaction reads it, its row locked
  # `FOR UPDATE` first, so that a move of the work item to another workspace waits for
  # the run, or the run for the move. The database names a run's work item by the
  # organisation alone; this is what holds a queued run to its work item's workspace. The
  # run waits for no pool in particular: any pool of that workspace may claim it.
  #
  # `queue_next(work_item, take_in)` writes, inside the caller's transaction, the next run
  # of a take in that has one: waiting, `attempt` one past the highest of the take in's
  # runs, of the same `of`, for the step `step/0`, in the work item's workspace, its row
  # locked `FOR UPDATE` first as `queue/2` locks it, and only then the take in's runs read.
  # Every new run counts toward `of`; a run back in the queue after a lapsed lease or a
  # release before its handover is the same run, not a new one. While a run of
  # the take in has not ended, waiting, claimed or handed over, it is `{:error, :running}`;
  # once the highest attempt is its `of`, `{:error, :used_up}`; a take in with no run is
  # `{:error, :no_run}`, as its first run is `queue/2`'s to write. Two at once for one take
  # in take turns on the work item: the second reads the runs only once the first
  # committed, so the two never write the same attempt.
  #
  # `queue_prebuild(collection, pool, environment_ref)` writes, inside the caller's
  # transaction, a run for the step `prebuild`: waiting in the pool's workspace, which is
  # the collection's, held for that pool, for `environment_ref`, and the pool's
  # environment record of the collection where there is none. At most one waits per
  # collection, pool and `environment_ref`: while one waits, it is that run, its place in
  # the queue kept; one of another ref waits beside it, and a claimed or handed-over one
  # is left as it is. It has no work item and counts toward no take in; like any run, it
  # takes a slot of the pool when it is claimed. `Apiary.Environments` decides when one
  # is due (`Apiary.Dispatches.Slots` names the order of every lock).
  #
  # `requeue_for_image(dispatch_run)` writes, inside the caller's transaction, which holds
  # the work item `FOR UPDATE`, the next run of the take in of a run whose exit found its
  # image missing from the registry (`Apiary.Dispatches.RunEnd`): waiting, with its
  # `attempt` and its `of` one more each and `image_requeue` set, so the take in loses no
  # attempt; attempt 2 of 3 ends, attempt 3 of 4 waits. It writes none for a run that came
  # from such a requeue, for a work item no longer in Explore, in another workspace or at
  # another take in, or while another run of the take in has not ended:
  # `{:error, :not_requeued}`. `requeued_for_image?(run)` is whether a registered run's
  # exit found its image missing and the next run of its take in was written so: its
  # page says so (`ApiaryWeb.RunLive.Show`).
  #
  # `end_held(work_item_ids, workspace_id, target, now)` ends, inside the caller's
  # transaction, the waiting runs of those work items with `target` that are not
  # prebuilds, `build_failed`, with the outcome `error`, when the build they were held
  # for failed (`Apiary.Environments.build_failed/6`).
  #
  # `cancel_for_undo(work_item)`, inside the caller's transaction, is what an undo of
  # the work item's take in asks first. An undo works while no claim holds a run of the
  # current take in: `{:error, :claimed}` while a dispatch holds one, neither stale nor
  # ended before its handover, and once one was handed over, after its run ended too (a
  # dispatch keeps `handed_over_at`). Else it ends the take in's waiting runs, end cause
  # `undone`, a run back in the queue after a lapsed lease or a release among them, and answers `:ok`; a stale dispatch of a run it ends ends with it, end cause
  # `run_ended`. A lease that lapsed and was not yet swept is lapsed first
  # (`Apiary.Dispatches.Slots.free/2`), so the run it held waits again. The runs of the
  # take in are locked `FOR UPDATE` before their dispatches are looked at, so a claim of
  # one either commits before and is seen, or finds the run ended.
  #
  # `cancel_for_close(work_item_ids, now)`, inside the caller's transaction, which holds
  # the work items `FOR UPDATE`, is what a close of the work items asks
  # (`Apiary.WorkItems.close_locked/3`). Their runs not yet handed over, waiting or
  # claimed, are locked `FOR UPDATE` in the order of their ids; a lease that lapsed and
  # was not yet swept is lapsed first (`Apiary.Dispatches.Slots.free/2`), as an undo has
  # it. Then each run ends, end cause `closed`. A stale dispatch of one ends with it, end
  # cause `run_ended`; a claimed run's live dispatch, neither stale nor handed over, ends
  # with it, end cause `closed`: a dispatch that ended, which the provisioner contract
  # answers `410 gone`. The slot each ended dispatch held is freed once
  # (`Apiary.Dispatches.Slots.free/2`), and a claimed run's registered run is deleted
  # with its run code (`Apiary.Dispatches.Handover.drop/1`). A handed-over run is left as
  # it is: it goes on to its end, and its exit and its result are taken as before.
  #
  # ## Claiming: `claim/3`
  #
  # `claim(access_key, now, body)` is one try at a claim by the node pool of `access_key`,
  # for the claim's raw `body`, in one transaction:
  #
  #   1. the key read again as a request's verification reads it
  #      (`Apiary.AccessKeys.fetch_for_verification/1`): revoked, of a pool deleted, or of a
  #      workspace or an organisation marked for deletion or out of use since, it is
  #      `{:error, :unauthorized}`;
  #   2. `dispatch.claim` asked of the key's workspace, or of the instance's pool for its
  #      key (`Apiary.Access`): any refusal is
  #      `{:error, :forbidden}`, one answer whatever its reason;
  #   3. the connections and then the collections a build for the pool is due for, with
  #      the collections of the pool's prebuilds whose dispatch lapsed at `now`, held
  #      `FOR SHARE`, by id, in one statement (`Apiary.Environments.hold_builds/3`): a
  #      build is due for the collections of the targets of the runs held for the pool's
  #      build (`Apiary.Environments.held/1`) with no prebuild of their `environment_ref`
  #      for the pool waiting, claimed or handed over; then the pool's
  #      row locked `FOR NO KEY UPDATE`, so two claims of one pool, and a claim and a
  #      registration on the pool (`Apiary.Nodes.check_instance_limit/3`, which locks it
  #      `FOR UPDATE`), take turns, while a prebuild's writes, whose foreign keys to the
  #      pool take `FOR KEY SHARE`, never wait on it (`Apiary.Dispatches.Slots`);
  #   4. the gateway the pool's choice resolves to now (`Apiary.Gateways.resolve/1`),
  #      read `FOR SHARE`, with its active keys: a choice that leads to no gateway,
  #      direct among them, is `{:error, :no_gateway}`
  #      (`Apiary.Dispatches.Handover.gateway/1`);
  #   5. the slots due freed (`Apiary.Dispatches.Slots.free/3`), which inserts the missing
  #      environment records of the collections held at 3 with no live prebuild of their
  #      ref for the pool, once it has locked the records of the lapsed prebuilds and
  #      before it locks a run (`Apiary.Environments.make_records/2`), then a prebuild of
  #      each collection held at 3 queued for the pool, where none is live yet
  #      (`Apiary.Environments.queue_builds/2`), then the pool's limit counted: its held
  #      slots and its live runs that were not dispatched; at the limit, `{:ok, :none}`;
  #   6. the oldest waiting run of the key's workspace, by `queued_at`, that the claim may
  #      take, or, for the instance's pool, of any workspace with no pool in use: no pool
  #      that is not deleted, enrolled or not, in a workspace and an organisation in use
  #      (`waiting_query/1`); locked `FOR UPDATE SKIP LOCKED`, so two claims never take one run and
  #      neither waits on the other; none is `{:ok, :none}`. A prebuild is taken only by
  #      the pool it is held for, and only on an instance with a registry
  #      (`Apiary.Registry.configured?/0`). A run held for the pool's build of its target
  #      is not taken (`Apiary.Environments.held/1`), nor one that a key change or a
  #      cleared image held again after that read (`Apiary.Environments.claim_image/2`): it
  #      waits, and so does a run whose harness walk is pending
  #      (`Apiary.Harnesses.WalkJob`). An explore run is given the image its target's build made for the pool,
  #      nil for the pool's default. A run whose work item has no target is taken as any
  #      other. A run whose work item is no longer live (closed, declined, undone, its
  #      connection ended, or gone) or no longer in the run's workspace is not handed
  #      out: it ends, `undone` for a work item undone and `closed` otherwise; nor is a
  #      prebuild whose collection ended, is assigned to no workspace or another one, has
  #      no target or no `environment_ref`, or whose connection ended: it ends,
  #      `collection_ended`; nor is a prebuild of an `environment_ref` its collection no
  #      longer has: it ends, `superseded`. A stale dispatch of a run ended so ends with
  #      it (`run_ended`), and the next is taken, up to 100 per claim;
  #   7. the run claimed and its dispatch written: its pool, its access key, its
  #      organisation and its workspace from the run, `claimed_at` `now` and
  #      `lease_until` `now` in whole seconds plus `lease_seconds/0`;
  #   8. the run registered through that gateway, with a run code bound to it
  #      (`Apiary.Dispatches.Handover.register/2`). A run the claim cannot form ends, with
  #      its dispatch, and the next is taken, within the same 100; a run that cannot be
  #      registered for any other reason is `{:error, :unavailable}`, and the whole
  #      transaction rolls back. An exception rolls it back too, is logged by its module
  #      alone, and is `{:error, :unavailable}`.
  #
  # `{:ok, claimed}` carries the dispatch, its run, the run's work item (nil for a
  # prebuild), the prebuild's collection (nil for any other step), the pool, the
  # registered run, its run code and the address of the gateway the code is bound to. The
  # workspaces whose queue the freed slots or the ended runs changed are told, and the
  # registered run is broadcast as changed, once the transaction commits.
  #
  # ## The starter on a dispatch: `dispatched/3`, `release/3` and `upload_machine_log/3`
  #
  # `dispatched(access_key, dispatch_id, meta)` records that the starter of the pool of
  # `access_key` started the machine for a dispatch its pool claimed: the first one,
  # within the dispatch's lease, hands the dispatch over, and a later one changes nothing
  # (`Apiary.Dispatches.Handover`). The first redemption of the run's code hands it over
  # too (`Apiary.Runs.RunCode`).
  #
  # `release(access_key, dispatch_id, meta)` gives the dispatch's run back, with the
  # starter's reason, in one transaction, or refuses in the contract's order
  # (`Apiary.Dispatches.Release`): before the handover the dispatch ends, `released`, the
  # registered run goes with its run code, and the run waits again; after it the release
  # is refused, `machine_exists`, and nothing is written.
  #
  # `upload_machine_log(access_key, dispatch_id, meta)` stores the dispatch's machine log,
  # once per dispatch, before or after the dispatch ends, and `machine_log(scope,
  # dispatch_id)` reads it, for an instance admin alone (`Apiary.Dispatches.MachineLogs`).
  #
  # ## The wake: `subscribe/1` and `broadcast/1`
  #
  # A claim held while its pool can claim nothing listens on its workspace's topic: a run
  # queued there, a run back in its queue, or a slot of its pools freed is told there as
  # `{Apiary.Dispatches, :changed}`, and the holder tries again. The instance's pool has
  # no workspace: its claim listens on the instance's topic, where every such change of
  # any workspace is told too, and tries again, as its claim reads the queues of every
  # workspace it serves. A run queued inside a transaction is told before that
  # transaction commits, so a holder may find nothing when told; it tries again at its
  # next poll (`ApiaryWeb.Contract.PoolClaimController`).
  #
  # ## The sweep: `sweep/1`
  #
  # `sweep(now)` frees what is due on every pool (`Apiary.Dispatches.Slots.free/2`), in
  # its transaction, then ends the waiting prebuilds of deleted node pools
  # (`end_deleted_prebuilds/1`), and tells the workspaces it changed.
  # `Apiary.Dispatches.Sweep` runs it every minute.
  #
  # Only a prebuild's pool may claim it, and a deleted pool claims nothing, so a prebuild
  # of a deleted pool that waits, from before the deletion or back in the queue after its
  # lease lapsed, would wait for good. `end_deleted_prebuilds(now)` ends such a prebuild
  # `lost`, at most `@max_deleted` per sweep, each in a separate transaction, as the
  # lost-run check ends a prebuild handed over (`Apiary.Dispatches.RunEnd`): it holds
  # what `Apiary.Dispatches.RunEnd.hold/1` holds, the connections and then the
  # collections of its target `FOR SHARE`, the work items whose runs wait for its build
  # `FOR KEY SHARE`, then its environment record `FOR UPDATE`; then the run of the queue
  # `FOR UPDATE`, ended only while it still waits, with a stale dispatch of it not yet
  # ended (`run_ended`). The record then has its last build failed, `lost`, unless its
  # image is newer than the prebuild's ref or was made by it
  # (`Apiary.Environments.newer_build?/2`, `Apiary.Environments.built_by?/2`), and the
  # runs held for the build go on as `Apiary.Environments.build_failed/6` has a loss on a
  # deleted pool: they end `build_failed`, unless a live pool has an image for their
  # target from its collection's `environment_ref`.
  #
  # ## The end of a run handed over: `backstop_seconds/1`
  #
  # A run handed over ends with its registered run: by its exit, by its gateway's refusal,
  # or by the lost-run check, at its gateway's `attach_by` should it never attach, at
  # `backstop_seconds/1` of its step after its attach should it have no exit by then, or
  # once it went 600 seconds without a heartbeat after its attach and before an exit
  # (`Apiary.Dispatches.RunEnd`). Its dispatch ends with it and the slot
  # it held is freed, once.
  #
  # ## The clock
  #
  # `now/0` is the one clock of the queue: a claim's `claimed_at` and `lease_until`, the
  # slots freed, the sweep and the end of a run its projection ended all read it, never the
  # database's.

  import Ecto.Query, only: [dynamic: 2, from: 2]

  require Logger

  alias Apiary.{Access, AccessKeys, Environments, Nodes, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover, MachineLogs, Release}
  alias Apiary.Dispatches.{RunEnd, Settle}
  alias Apiary.Dispatches.Slots
  alias Apiary.Environments.Record
  alias Apiary.Harnesses.{RunHarness, WalkJob}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.WorkItems.WorkItem

  # The step every run of a take in is queued for: the contract's `explore`.
  @step "explore"
  # The step of a run that builds a collection's environment for one node pool.
  @prebuild DispatchRun.prebuild()
  # The index that holds one waiting prebuild per collection, node pool and
  # `environment_ref`.
  @waiting_prebuild "(source_collection_id, pool_id, environment_ref) " <>
                      "WHERE step = 'prebuild' AND state = 'waiting'"
  # The runs a take in has at most, the explore contract's `run.of`.
  @of 3
  # How long a dispatch is the starter's, from its claim, in seconds.
  @lease_seconds 600
  # The waiting runs of work items no longer live one claim ends at most.
  @max_ended 100
  # The waiting prebuilds of deleted node pools one sweep ends at most.
  @max_deleted 100

  @typedoc """
  What a claim took: the dispatch, its run, the run's work item, or for a prebuild its
  collection, the pool, the run registered for it, its run code, the address of the
  gateway the code is bound to, and what the run's documents are made from.
  """
  @type claimed :: %{
          dispatch: Dispatch.t(),
          run: DispatchRun.t(),
          work_item: WorkItem.t() | nil,
          collection: Collection.t() | nil,
          pool: Node.t(),
          registered: Apiary.Runs.Run.t(),
          run_code: String.t(),
          gateway_url: String.t(),
          documents: map
        }

  # step/0 is the step a run is queued for.
  @doc false
  @spec step() :: String.t()
  def step, do: @step

  # of/0 is the runs a take in has at most.
  @doc false
  @spec of() :: pos_integer
  def of, do: @of

  # lease_seconds/0 is how long a dispatch is the starter's, from its claim.
  @doc false
  @spec lease_seconds() :: pos_integer
  def lease_seconds, do: @lease_seconds

  # now/0 is the queue's clock.
  @doc false
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  # lease_until/1 is the lease of a dispatch claimed at `claimed_at`: in whole seconds,
  # `lease_seconds/0` after it, held to microseconds as the column is.
  @doc false
  @spec lease_until(DateTime.t()) :: DateTime.t()
  def lease_until(%DateTime{} = claimed_at) do
    lease_until =
      claimed_at
      |> DateTime.truncate(:second)
      |> DateTime.add(@lease_seconds, :second)

    %{lease_until | microsecond: {0, 6}}
  end

  ## Queueing

  # queue/2 writes the first run of take in `take_in` of `work_item`, waiting in the work
  # item's workspace, inside the caller's transaction (the moduledoc).
  @doc false
  @spec queue(WorkItem.t(), pos_integer) :: {:ok, DispatchRun.t()} | {:error, Ecto.Changeset.t()}
  def queue(%WorkItem{id: id}, take_in) when is_binary(id) and is_integer(take_in) do
    in_transaction!("queue/2")
    id |> lock_work_item!() |> insert_run(take_in, 1, @of)
  end

  # queue_next/2 writes the next run of take in `take_in` of `work_item`, once every run
  # of the take in ended and while one is left of its `of`, waiting in the work item's
  # workspace, inside the caller's transaction (the moduledoc).
  @doc false
  @spec queue_next(WorkItem.t(), pos_integer) ::
          {:ok, DispatchRun.t()}
          | {:error, :no_run | :running | :used_up | Ecto.Changeset.t()}
  def queue_next(%WorkItem{id: id}, take_in) when is_binary(id) and is_integer(take_in) do
    in_transaction!("queue_next/2")
    work_item = lock_work_item!(id)

    runs =
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^id and r.take_in == ^take_in,
          select: %{state: r.state, attempt: r.attempt, of: r.of}
      )

    case runs do
      [] ->
        {:error, :no_run}

      runs ->
        %{attempt: attempt, of: of} = Enum.max_by(runs, & &1.attempt)

        cond do
          Enum.any?(runs, &(&1.state != :ended)) -> {:error, :running}
          attempt >= of -> {:error, :used_up}
          true -> insert_run(work_item, take_in, attempt + 1, of)
        end
    end
  end

  # The work item `id` locked `FOR UPDATE`, as the transaction reads it: its id, its
  # organisation, the workspace it is in now and its target.
  defp lock_work_item!(id) do
    Repo.one!(
      from w in WorkItem,
        where: w.id == ^id,
        lock: "FOR UPDATE",
        select: %{
          id: w.id,
          organisation_id: w.organisation_id,
          workspace_id: w.workspace_id,
          target_system: w.target_system,
          target_path: w.target_path,
          test: w.test,
          connection_id: w.connection_id
        }
    )
  end

  # A waiting run of take in `take_in` of the locked work item, `attempt` of `of`, for the
  # step `step/0`, in the work item's organisation and workspace, with `image_requeue`,
  # and its harness walk (`Apiary.Harnesses.WalkJob.queue/2`); the workspace is told.
  defp insert_run(work_item, take_in, attempt, of, image_requeue \\ false) do
    %{id: id, organisation_id: organisation_id, workspace_id: workspace_id} = work_item

    result =
      %DispatchRun{
        organisation_id: organisation_id,
        workspace_id: workspace_id,
        image_requeue: image_requeue
      }
      |> DispatchRun.queue_changeset(%{
        work_item_id: id,
        step: @step,
        take_in: take_in,
        attempt: attempt,
        of: of,
        queued_at: now()
      })
      |> Repo.insert()

    with {:ok, run} <- result,
         {:ok, _walk} <- WalkJob.queue(run, harness_place(work_item)) do
      broadcast([workspace_id])
      {:ok, run}
    end
  end

  # What the run's harness walk is for: `:test` for a test work item, `test` set and no
  # connection, as the database holds them together (`work_items_test_check`), which gets
  # the built-in harness (`Apiary.Harnesses.Builtin`); else the work item's target.
  defp harness_place(%{test: true, connection_id: nil}), do: :test
  defp harness_place(work_item), do: target(work_item)

  defp target(%{target_system: system, target_path: path})
       when is_binary(system) and is_binary(path),
       do: %{system: system, path: path}

  defp target(_work_item), do: nil

  # queue_prebuild/3 writes a run for the step `prebuild` of `collection`, held for the
  # node pool `pool` of the collection's workspace, or the instance's pool, for
  # `environment_ref`, unless one waits for that ref already, which it answers, and the
  # environment record of the collection and pool where there is none, inside the
  # caller's transaction (the moduledoc). The run and the record are in the collection's
  # workspace.
  @doc false
  @spec queue_prebuild(Collection.t(), Node.t(), String.t()) ::
          {:ok, DispatchRun.t()} | {:error, Ecto.Changeset.t()}
  def queue_prebuild(
        %Collection{workspace_id: workspace_id} = collection,
        %Node{kind: :pool, id: pool_id, organisation_id: nil, workspace_id: nil},
        environment_ref
      )
      when is_binary(workspace_id) and is_binary(environment_ref),
      do: insert_prebuild(collection, pool_id, environment_ref)

  def queue_prebuild(
        %Collection{organisation_id: organisation_id, workspace_id: workspace_id} =
          collection,
        %Node{
          kind: :pool,
          id: pool_id,
          organisation_id: organisation_id,
          workspace_id: workspace_id
        },
        environment_ref
      )
      when is_binary(workspace_id) and is_binary(environment_ref),
      do: insert_prebuild(collection, pool_id, environment_ref)

  defp insert_prebuild(
         %Collection{
           id: collection_id,
           organisation_id: organisation_id,
           workspace_id: workspace_id
         },
         pool_id,
         environment_ref
       ) do
    in_transaction!("queue_prebuild/3")
    now = now()

    {_count, _rows} =
      Repo.insert_all(
        Record,
        [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: organisation_id,
            workspace_id: workspace_id,
            pool_id: pool_id,
            source_collection_id: collection_id,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:pool_id, :source_collection_id]
      )

    result =
      %DispatchRun{organisation_id: organisation_id, workspace_id: workspace_id}
      |> DispatchRun.prebuild_changeset(%{
        source_collection_id: collection_id,
        pool_id: pool_id,
        environment_ref: environment_ref,
        queued_at: now
      })
      |> Repo.insert(
        on_conflict: {:replace, [:updated_at]},
        conflict_target: {:unsafe_fragment, @waiting_prebuild},
        returning: true
      )

    with {:ok, _run} <- result, do: broadcast([workspace_id])
    result
  end

  # end_held/4 ends the waiting runs of the work items `work_item_ids`, which the caller
  # holds `FOR KEY SHARE`, that are not prebuilds, in the workspace `workspace_id`, of
  # work items with `target`, `build_failed`, with the outcome `error`, with any stale
  # dispatch of them (`run_ended`), inside the caller's transaction
  # (`Apiary.Environments.build_failed/6`): the workspace and the work items to tell. A
  # run a claim took is no longer waiting and is left as it is, and so is a run whose
  # target's run configuration names an image (`Apiary.Environments.unset_by_policy/1`),
  # as no build holds it.
  @doc false
  @spec end_held(
          [Ecto.UUID.t()],
          Ecto.UUID.t(),
          %{system: String.t(), path: String.t()},
          DateTime.t()
        ) ::
          [Ecto.UUID.t() | Settle.told()]
  def end_held([], _workspace_id, _target, %DateTime{}), do: []

  def end_held(work_item_ids, workspace_id, %{system: system, path: path}, %DateTime{} = now) do
    in_transaction!("end_held/4")

    {_count, ended} =
      Repo.update_all(
        from(r in DispatchRun,
          join: w in WorkItem,
          as: :work_item,
          on: w.id == r.work_item_id,
          where: r.work_item_id in ^work_item_ids and r.workspace_id == ^workspace_id,
          where: r.step != ^@prebuild and fragment("? = 'waiting'", r.state),
          where: w.target_system == ^system and w.target_path == ^path,
          where: ^Environments.unset_by_policy(workspace_id),
          select: {r.id, r.work_item_id}
        ),
        set: [state: :ended, end_cause: :build_failed, result_outcome: :error, updated_at: now]
      )

    {run_ids, ended_work_items} = Enum.unzip(ended)

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id in ^run_ids,
          where: not is_nil(d.stale_at) and is_nil(d.ended_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    case ended_work_items do
      [] -> []
      ids -> [workspace_id | Enum.flat_map(Enum.uniq(ids), &Settle.told/1)]
    end
  end

  # requeue_for_image/1 writes the next run of the take in of `dispatch_run`, which its
  # end by an exit that found its image missing ended in the caller's transaction, which
  # holds its work item `FOR UPDATE` (`Apiary.Dispatches.RunEnd`): waiting, with its
  # attempt and its `of` one more each and `image_requeue` set, so the take in loses no
  # attempt. Only while `dispatch_run` is not such a run itself, its work item is in
  # Explore, in the run's workspace, at the run's take in, and every run of the take in
  # ended, `dispatch_run` the last; else `{:error, :not_requeued}`.
  @doc false
  @spec requeue_for_image(DispatchRun.t()) ::
          {:ok, DispatchRun.t()} | {:error, :not_requeued | Ecto.Changeset.t()}
  def requeue_for_image(%DispatchRun{
        image_requeue: false,
        work_item_id: id,
        workspace_id: workspace_id,
        take_in: take_in,
        attempt: attempt,
        of: of
      })
      when is_binary(id) and is_integer(take_in) do
    in_transaction!("requeue_for_image/1")

    work_item =
      Repo.one!(
        from w in WorkItem,
          where: w.id == ^id,
          select: %{
            id: w.id,
            organisation_id: w.organisation_id,
            workspace_id: w.workspace_id,
            target_system: w.target_system,
            target_path: w.target_path,
            test: w.test,
            connection_id: w.connection_id,
            state: w.state,
            take_in: w.take_in
          }
      )

    runs =
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^id and r.take_in == ^take_in,
          select: {r.state, r.attempt}
      )

    if work_item.state == :exploring and work_item.workspace_id == workspace_id and
         work_item.take_in == take_in and Enum.all?(runs, &(elem(&1, 0) == :ended)) and
         Enum.max(Enum.map(runs, &elem(&1, 1))) == attempt,
       do: insert_run(work_item, take_in, attempt + 1, of + 1, true),
       else: {:error, :not_requeued}
  end

  def requeue_for_image(%DispatchRun{}), do: {:error, :not_requeued}

  # requeued_for_image?/1 is whether the registered run `run`, of a run of the queue,
  # exited `failed` with the reason `image_missing`, and the next run of its take in was
  # queued for that (`requeue_for_image/1`), read without a lock.
  @doc false
  @spec requeued_for_image?(Apiary.Runs.Run.t()) :: boolean
  def requeued_for_image?(%Apiary.Runs.Run{
        dispatch_run_id: id,
        exit_state: "failed",
        exit_reason: "image_missing"
      })
      when is_binary(id) do
    Repo.exists?(
      from r in DispatchRun,
        join: next in DispatchRun,
        on:
          next.work_item_id == r.work_item_id and next.take_in == r.take_in and
            next.attempt == r.attempt + 1,
        where: r.id == ^id and next.image_requeue
    )
  end

  def requeued_for_image?(_run), do: false

  # cancel_for_undo/1 ends the waiting runs of the current take in of `work_item`, or
  # refuses while a claim holds one of its runs or once one was handed over, inside the
  # caller's transaction (the moduledoc).
  @doc false
  @spec cancel_for_undo(WorkItem.t()) :: :ok | {:error, :claimed}
  def cancel_for_undo(%WorkItem{id: id}) when is_binary(id) do
    in_transaction!("cancel_for_undo/1")
    now = now()

    take_in =
      Repo.one!(from w in WorkItem, where: w.id == ^id, lock: "FOR UPDATE", select: w.take_in)

    run_ids =
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^id and r.take_in == ^take_in,
          order_by: r.id,
          lock: "FOR UPDATE",
          select: r.id
      )

    # A lease that lapsed unswept frees its run first; then the runs as they stand, and
    # whether any was ever handed over: a dispatch of it keeps `handed_over_at` after the
    # run ended, lost, run_ended or released after the handover.
    freed = if run_ids == [], do: [], else: Slots.free({:runs, run_ids}, now)
    runs = Repo.all(from r in DispatchRun, where: r.id in ^run_ids)

    handed_over? =
      Repo.exists?(
        from d in Dispatch,
          where: d.dispatch_run_id in ^run_ids and not is_nil(d.handed_over_at)
      )

    if handed_over? or Enum.any?(runs, &(&1.state in [:claimed, :handed_over])) do
      {:error, :claimed}
    else
      waiting = for %DispatchRun{state: :waiting, id: run_id} <- runs, do: run_id

      {_count, _rows} =
        Repo.update_all(
          from(r in DispatchRun, where: r.id in ^waiting),
          set: [state: :ended, end_cause: :undone, updated_at: now]
        )

      {_count, _rows} =
        Repo.update_all(
          from(d in Dispatch,
            where: d.dispatch_run_id in ^waiting,
            where: not is_nil(d.stale_at) and is_nil(d.ended_at)
          ),
          set: [ended_at: now, end_cause: :run_ended, updated_at: now]
        )

      broadcast(freed)
      :ok
    end
  end

  # cancel_for_close/2 ends the runs not yet handed over of the work items
  # `work_item_ids`, and their dispatches, at `now`, inside the caller's transaction (the
  # moduledoc): `{:ok, workspace_ids}`, the workspaces whose queue or slots changed, for
  # the caller to tell once its transaction commits.
  @doc false
  @spec cancel_for_close([Ecto.UUID.t()], DateTime.t()) :: {:ok, [Ecto.UUID.t()]}
  def cancel_for_close(work_item_ids, %DateTime{} = now) when is_list(work_item_ids) do
    in_transaction!("cancel_for_close/2")

    runs =
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id in ^work_item_ids,
          where: fragment("? IN ('waiting', 'claimed')", r.state),
          order_by: r.id,
          lock: "FOR UPDATE",
          select: {r.id, r.workspace_id}
      )

    case runs do
      [] ->
        {:ok, []}

      _some ->
        {run_ids, workspace_ids} = Enum.unzip(runs)

        # A lease that lapsed unswept frees its run first, as an undo has it.
        lapsed = Slots.free({:runs, run_ids}, now)

        {_count, _rows} =
          Repo.update_all(from(r in DispatchRun, where: r.id in ^run_ids),
            set: [state: :ended, end_cause: :closed, updated_at: now]
          )

        # A stale dispatch ends with its run; a live one, not handed over, as its run.
        {_count, _rows} =
          Repo.update_all(
            from(d in Dispatch,
              where: d.dispatch_run_id in ^run_ids,
              where: not is_nil(d.stale_at) and is_nil(d.ended_at)
            ),
            set: [ended_at: now, end_cause: :run_ended, updated_at: now]
          )

        {_count, _rows} =
          Repo.update_all(
            from(d in Dispatch,
              where: d.dispatch_run_id in ^run_ids,
              where: is_nil(d.stale_at) and is_nil(d.handed_over_at) and is_nil(d.ended_at)
            ),
            set: [ended_at: now, end_cause: :closed, updated_at: now]
          )

        # A claimed run's registered run goes with its run code (`Handover.drop/1`).
        _dropped = Handover.drop(run_ids)
        freed = Slots.free({:runs, run_ids}, now)
        {:ok, Enum.uniq(workspace_ids ++ lapsed ++ freed)}
    end
  end

  ## Claiming

  # claim/3 is one try at a claim by the node pool of `access_key` at `now`, for the
  # claim's raw `body` (the moduledoc): `{:ok, claimed}`, `{:ok, :none}` when the pool can
  # claim nothing now, or `{:error, :unauthorized | :forbidden | :no_gateway |
  # :unavailable}`, after which nothing is written.
  @doc false
  @spec claim(AccessKey.t(), DateTime.t(), binary) ::
          {:ok, claimed | :none}
          | {:error, :unauthorized | :forbidden | :no_gateway | :unavailable}
  def claim(%AccessKey{key_id: key_id}, %DateTime{} = now, body \\ "")
      when is_binary(key_id) and is_binary(body) do
    result =
      Repo.transact(fn ->
        with {:ok, key} <- current_key(key_id),
             :ok <- may_claim(key),
             builds = Environments.hold_builds(key.workspace_id, key.node_id, now),
             {:ok, pool} <- lock_pool(key),
             {:ok, gateway, keys} <- Handover.gateway(pool) do
          freed = Slots.free(pool.id, now, fn -> Environments.make_records(builds, pool) end)
          queued = Environments.queue_builds(builds, pool)
          through = %{gateway: gateway, keys: keys, body: body}

          case take(key, pool, through, now) do
            {:error, :unavailable} = error -> error
            {taken, ended} -> {:ok, {taken, freed ++ queued_in(queued) ++ ended}}
          end
        end
      end)

    case result do
      {:ok, {taken, freed}} ->
        broadcast(freed)
        Handover.broadcast_run({:ok, %{run: registered(taken)}})
        {:ok, taken}

      {:error, _reason} = error ->
        error
    end
  rescue
    exception ->
      Logger.error("a claim could not be made: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp registered(%{registered: run}), do: run
  defp registered(:none), do: nil

  defp queued_in([]), do: []
  defp queued_in([%DispatchRun{workspace_id: workspace_id} | _rest]), do: [workspace_id]

  # current_key/1 is the key `key_id` as a request's verification reads it now: of the
  # same pool, workspace and organisation as when the request verified, or
  # `{:error, :unauthorized}`. The key of the instance's pool has neither, as its pool has
  # none.
  @doc false
  @spec current_key(String.t()) :: {:ok, AccessKey.t()} | {:error, :unauthorized}
  def current_key(key_id) do
    case AccessKeys.fetch_for_verification(key_id) do
      {:ok,
       %AccessKey{
         node: %Node{kind: :pool, id: pool_id, workspace_id: workspace_id},
         node_id: pool_id,
         workspace_id: workspace_id,
         organisation_id: organisation_id
       } = key}
      when is_binary(workspace_id) and is_binary(organisation_id) ->
        {:ok, key}

      {:ok,
       %AccessKey{
         node: %Node{kind: :pool, id: pool_id, workspace_id: nil, organisation_id: nil},
         node_id: pool_id,
         workspace_id: nil,
         organisation_id: nil
       } = key} ->
        {:ok, key}

      _other ->
        {:error, :unauthorized}
    end
  end

  # Asked of the key's place (`Apiary.Accounts.Scope.key_place/1`): the key's workspace,
  # the queue, or the instance's pool, which claims in every workspace with no pool in use.
  defp may_claim(key) do
    scope = Scope.for_access_key(key)

    case Access.authorize(scope, :"dispatch.claim", Scope.key_place(scope)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp lock_pool(%AccessKey{node_id: pool_id} = key) do
    pool =
      Repo.one(
        from n in Node,
          where: n.id == ^pool_id and n.kind == :pool and is_nil(n.deleted_at),
          where: ^pool_place(key),
          lock: "FOR NO KEY UPDATE"
      )

    if pool, do: {:ok, pool}, else: {:error, :unauthorized}
  end

  # The pool of the key's workspace, or the instance's pool, with no organisation and no
  # workspace.
  defp pool_place(%AccessKey{workspace_id: nil}),
    do: dynamic([n], is_nil(n.organisation_id) and is_nil(n.workspace_id))

  defp pool_place(%AccessKey{workspace_id: workspace_id}),
    do: dynamic([n], n.workspace_id == ^workspace_id)

  # The oldest waiting run the pool may take, claimed and registered through the gateway
  # `through` has, with the workspaces whose queue it ended runs of; `:none` at the limit
  # or with none to take; `{:error, :unavailable}` when a run could not be registered.
  defp take(key, pool, through, now) do
    case below_limit(pool, now) do
      :ok -> pick(key, pool, through, now, @max_ended, [])
      :at_limit -> {:none, []}
    end
  end

  # A waiting run whose work item, or a prebuild whose collection, can no longer be
  # handed out is ended, with any stale dispatch of it (`run_ended`), and the next one
  # looked at; so is a run claimed that the claim cannot form
  # (`Apiary.Dispatches.Handover.register/2`): `max` at most per claim.
  defp pick(_key, _pool, _through, _now, 0, ended), do: {:none, ended}

  defp pick(key, pool, through, now, max, ended) do
    case key |> waiting_query() |> Repo.one() do
      nil ->
        {:none, ended}

      %DispatchRun{} = run ->
        case for_run(run, pool) do
          :held ->
            pick(key, pool, through, now, max - 1, ended)

          {:ok, for} ->
            claimed = claim_run(key, pool, run, for, now)

            case Handover.register(Map.merge(claimed, Map.put(through, :key, key)), now) do
              {:ok, registered} ->
                {Map.merge(claimed, %{
                   registered: registered.run,
                   run_code: registered.run_code,
                   gateway_url: registered.gateway_url,
                   documents: registered.documents
                 }), ended}

              {:ended, changed} ->
                pick(key, pool, through, now, max - 1, changed ++ ended)

              {:error, :unavailable} = error ->
                error
            end

          {:end, cause} ->
            {1, _rows} =
              Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
                set: [state: :ended, end_cause: cause, updated_at: now]
              )

            # A stale dispatch of the run ends with it; the lapse freed its slot already.
            {_count, _rows} =
              Repo.update_all(
                from(d in Dispatch,
                  where: d.dispatch_run_id == ^run.id,
                  where: not is_nil(d.stale_at) and is_nil(d.ended_at)
                ),
                set: [ended_at: now, end_cause: :run_ended, updated_at: now]
              )

            pick(key, pool, through, now, max - 1, [run.workspace_id | ended])
        end
    end
  end

  # What the run is for: its work item, with the image `pool` keeps for its target, or a
  # prebuild's collection. A run whose image went since `waiting_query/1` read it is
  # held again (`Apiary.Environments.claim_image/2`): `:held`, and it waits.
  defp for_run(%DispatchRun{step: @prebuild} = run, _pool) do
    with {:ok, collection} <- collection_of(run), do: {:ok, %{collection: collection}}
  end

  defp for_run(%DispatchRun{} = run, pool) do
    with {:ok, work_item} <- work_item_of(run),
         {:ok, image} <- Environments.claim_image(pool, work_item) do
      {:ok, %{work_item: work_item, image: image}}
    end
  end

  # A prebuild's collection when it is live, assigned to the run's workspace, has a target
  # and an `environment_ref`, and its connection has not ended; else the run ends,
  # `collection_ended`. A prebuild of another `environment_ref` than its collection's
  # ends `superseded`: a held run asks for the build of the ref its collection has
  # (`Apiary.Environments.queue_builds/2`). Read without a lock, as a work item is: the run
  # is locked, and its pool too.
  defp collection_of(%DispatchRun{
         source_collection_id: collection_id,
         workspace_id: workspace_id,
         environment_ref: run_ref
       }) do
    found =
      Repo.one(
        from c in Collection,
          join: n in Connection,
          on: n.id == c.connection_id,
          where: c.id == ^collection_id,
          select: {c, n.state}
      )

    case found do
      {%Collection{
         ended_at: nil,
         workspace_id: ^workspace_id,
         target_system: system,
         environment_ref: ^run_ref
       } = collection, connection}
      when is_binary(system) and connection in [:pending, :connected] ->
        {:ok, collection}

      {%Collection{
         ended_at: nil,
         workspace_id: ^workspace_id,
         target_system: system,
         environment_ref: ref
       }, connection}
      when is_binary(system) and is_binary(ref) and connection in [:pending, :connected] ->
        {:end, :superseded}

      _ended_moved_or_without_target ->
        {:end, :collection_ended}
    end
  end

  # The run's work item when it is live, in the run's workspace, and its connection has
  # not ended; else the cause the run ends for: `undone` for a work item undone, `closed`
  # for any other (closed, declined, its connection ended, moved to another workspace,
  # or gone). Read without a lock: the run is locked, so an undo waits for the claim and
  # is then refused; a close that commits meanwhile finds the run claimed.
  #
  # A test work item has no connection to check (`WorkItem.test_changeset/2`): only one
  # with `test` set and no `connection_id` skips that check, and the database holds both
  # together (`work_items_test_check`). Every other work item keeps it.
  defp work_item_of(%DispatchRun{work_item_id: work_item_id, workspace_id: workspace_id}) do
    found =
      Repo.one(
        from w in WorkItem,
          left_join: c in Connection,
          on: c.id == w.connection_id,
          where: w.id == ^work_item_id,
          select: {w, c.state}
      )

    case found do
      {%WorkItem{state: :exploring, workspace_id: ^workspace_id} = work_item, connection}
      when connection in [:pending, :connected] ->
        {:ok, work_item}

      {%WorkItem{
         state: :exploring,
         workspace_id: ^workspace_id,
         test: true,
         connection_id: nil
       } = work_item, nil} ->
        {:ok, work_item}

      {%WorkItem{state: :undone}, _connection} ->
        {:end, :undone}

      _ended_moved_or_gone ->
        {:end, :closed}
    end
  end

  defp claim_run(key, pool, run, for, now) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [state: :claimed, updated_at: now]
      )

    dispatch =
      %Dispatch{organisation_id: run.organisation_id, workspace_id: run.workspace_id}
      |> Dispatch.claim_changeset(%{
        dispatch_run_id: run.id,
        pool_id: key.node_id,
        access_key_id: key.id,
        claimed_at: now,
        lease_until: lease_until(now)
      })
      |> PublicId.Insert.insert!()

    Map.merge(
      %{dispatch: dispatch, run: %{run | state: :claimed}, work_item: nil, collection: nil},
      Map.put(for, :pool, pool)
    )
  end

  # The pool's held slots and its live runs that were not dispatched, against its limit;
  # a pool without one takes any.
  defp below_limit(%Node{instance_limit: nil}, _now), do: :ok

  defp below_limit(%Node{instance_limit: limit} = pool, now) do
    if Nodes.instances_in_use(pool, now) < limit, do: :ok, else: :at_limit
  end

  # waiting_query/1 is the query of the oldest waiting run the pool of `key` may take,
  # locked `FOR UPDATE SKIP LOCKED`. A prebuild goes only to the pool it is held for, only
  # on an instance with a registry (`prebuild_taken/0`); a run held for the pool's build
  # of its target
  # (`Apiary.Environments.held/1`) is left waiting.
  @doc false
  @spec waiting_query(AccessKey.t()) :: Ecto.Query.t()
  def waiting_query(%AccessKey{
        organisation_id: organisation_id,
        workspace_id: workspace_id,
        node_id: pool_id
      })
      when is_binary(workspace_id) do
    query =
      from r in DispatchRun,
        as: :run,
        where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id,
        where: fragment("? = 'waiting'", r.state),
        where: r.step != ^@prebuild or r.pool_id == ^pool_id,
        where: ^prebuild_taken(),
        where: not exists(walk_unresolved()),
        order_by: [asc: r.queued_at, asc: r.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"

    if Environments.holds?(workspace_id),
      do:
        from(r in query,
          where: r.step == ^@prebuild or not exists(Environments.held(pool_id))
        ),
      else: query
  end

  # The instance's pool takes the oldest waiting run of any workspace with no pool in use,
  # across organisations, and the prebuilds held for it, each in a place in use
  # (`in_use_place/0`). A workspace whose pool never enrolled has a pool in use: its runs
  # wait for that pool.
  def waiting_query(%AccessKey{workspace_id: nil, node_id: pool_id}) do
    takes =
      dynamic(
        [run: r],
        (r.step == ^@prebuild and r.pool_id == ^pool_id) or
          (r.step != ^@prebuild and ^no_pool_in_use() and
             not exists(Environments.held(pool_id)))
      )

    from r in DispatchRun,
      as: :run,
      where: fragment("? = 'waiting'", r.state),
      where: ^takes,
      where: ^prebuild_taken(),
      where: ^in_use_place(),
      where: not exists(walk_unresolved()),
      order_by: [asc: r.queued_at, asc: r.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
  end

  # The condition, on a run of the queue bound `:run`, that a claim may take it: a run
  # that is not a prebuild; a prebuild only on an instance with a registry
  # (`Apiary.Registry.configured?/0`), as its documents have its destinations there
  # (`Apiary.Dispatches.Handover`). A prebuild that is not taken waits.
  defp prebuild_taken do
    if Apiary.Registry.configured?(),
      do: dynamic([run: _r], true),
      else: dynamic([run: r], r.step != ^@prebuild)
  end

  # The harness walk of a run bound `:run` that has not resolved: pending, or failed, which
  # ends the run in the transaction that writes it (`Apiary.Harnesses.WalkJob`). A run
  # with no walk, a prebuild, has none.
  defp walk_unresolved do
    from h in RunHarness,
      where: h.dispatch_run_id == parent_as(:run).id and h.state != :resolved,
      select: 1
  end

  # no_pool_in_use/0 is the condition, on a row bound `:run` with a `workspace_id`, a run
  # of the queue or a collection, that its workspace has no node pool in use: none that
  # is not deleted, enrolled or not. The instance's pool serves such a workspace.
  @doc false
  @spec no_pool_in_use() :: Ecto.Query.dynamic_expr()
  def no_pool_in_use do
    pool_in_use =
      from n in Node,
        where: n.workspace_id == parent_as(:run).workspace_id,
        where: n.kind == :pool and is_nil(n.deleted_at),
        select: 1

    dynamic([run: _r], not exists(pool_in_use))
  end

  # in_use_place/0 is the condition, on a row bound `:run` with a `workspace_id` and an
  # `organisation_id`, a run of the queue or a collection, that its workspace and its
  # organisation are in use: neither marked for deletion, nor the organisation out of use
  # (`Apiary.AccessKeys.place_in_use?/2`). A workspace pool's key is held to its place
  # when it is verified; the instance's pool's key has no place, so its claim holds each
  # run to the run's.
  @doc false
  @spec in_use_place() :: Ecto.Query.dynamic_expr()
  def in_use_place do
    in_use =
      from(w in Workspace,
        join: o in Organisation,
        as: :organisation,
        on: o.id == w.organisation_id,
        where: w.id == parent_as(:run).workspace_id,
        where: o.id == parent_as(:run).organisation_id,
        where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at),
        select: 1
      )
      |> Apiary.Edition.active_organisations(:organisation)

    dynamic([run: _r], exists(in_use))
  end

  ## The starter on a dispatch

  # dispatched/3 records that the starter started the job for the dispatch `dispatch_id`
  # (`Apiary.Dispatches.Handover.dispatched/3`).
  @doc false
  @spec dispatched(AccessKey.t(), term, %{external: map | nil}) ::
          :ok | {:error, Handover.refusal()}
  def dispatched(%AccessKey{} = access_key, dispatch_id, meta),
    do: Handover.dispatched(access_key, dispatch_id, meta)

  # release/3 gives back the run of the dispatch `dispatch_id`, with the starter's reason
  # (`Apiary.Dispatches.Release.release/3`).
  @doc false
  @spec release(AccessKey.t(), term, Release.release()) :: :ok | {:error, Release.refusal()}
  def release(%AccessKey{} = access_key, dispatch_id, meta),
    do: Release.release(access_key, dispatch_id, meta)

  # upload_machine_log/3 stores the machine log of the dispatch `dispatch_id`, once
  # (`Apiary.Dispatches.MachineLogs.upload/3`).
  @doc false
  @spec upload_machine_log(AccessKey.t(), term, MachineLogs.upload()) ::
          :ok | {:error, MachineLogs.refusal()}
  def upload_machine_log(%AccessKey{} = access_key, dispatch_id, meta),
    do: MachineLogs.upload(access_key, dispatch_id, meta)

  # machine_log/2 is the machine log of the dispatch `dispatch_id`, for an instance admin
  # alone (`Apiary.Dispatches.MachineLogs.machine_log/2`).
  @doc false
  @spec machine_log(Scope.t() | nil, term) ::
          {:ok, MachineLogs.machine_log()} | {:error, :forbidden | :not_found | :unreadable}
  def machine_log(scope, dispatch_id), do: MachineLogs.machine_log(scope, dispatch_id)

  ## The end of a run handed over

  # backstop_seconds/1 is the seconds after its attach by which a run of `step` has its
  # exit, or is lost: 87,300 for `explore` and 4500 for `prebuild`.
  @doc false
  @spec backstop_seconds(String.t() | nil) :: pos_integer
  def backstop_seconds(step), do: RunEnd.backstop_seconds(step)

  ## The sweep

  # sweep/1 frees what is due at `now` on every pool, ends the waiting prebuilds of
  # deleted pools (`end_deleted_prebuilds/1`) and tells what changed: the ids of the
  # workspaces, and the work items whose run ended.
  @doc false
  @spec sweep(DateTime.t()) :: [Ecto.UUID.t() | Settle.told()]
  def sweep(%DateTime{} = now) do
    {:ok, freed} = Repo.transact(fn -> {:ok, Slots.free(:all, now)} end)
    changed = Enum.uniq(freed ++ end_deleted_prebuilds(now))
    broadcast(changed)
    changed
  end

  # end_deleted_prebuilds/1 ends `lost`, at `now`, the waiting prebuilds of deleted node
  # pools, `@max_deleted` at most, by id, each in a separate transaction (the moduledoc).
  # One that raises is logged by its id and the exception's module, and the rest are
  # still ended. The ids of the workspaces whose queue changed, and the work items whose
  # held runs ended, for the caller to tell (`broadcast/1`).
  @doc false
  @spec end_deleted_prebuilds(DateTime.t()) :: [Ecto.UUID.t() | Settle.told()]
  def end_deleted_prebuilds(%DateTime{} = now) do
    from(r in DispatchRun,
      join: n in Node,
      on: n.id == r.pool_id,
      where: r.step == ^@prebuild and fragment("? = 'waiting'", r.state),
      where: not is_nil(n.deleted_at),
      order_by: r.id,
      limit: @max_deleted,
      select: r.id
    )
    |> Repo.all()
    |> Enum.flat_map(&end_deleted_guarded(&1, now))
    |> Enum.uniq()
  end

  defp end_deleted_guarded(id, now) do
    {:ok, changed} = Repo.transact(fn -> {:ok, end_deleted(id, now)} end)
    changed
  rescue
    error ->
      Logger.error("prebuild end failed dispatch_run=#{id} error=#{inspect(error.__struct__)}")
      []
  end

  # The rules again, under the locks: the prebuild still waits, and its pool is deleted.
  defp end_deleted(id, now) do
    held = RunEnd.hold(id)

    case RunEnd.lock(id) do
      %DispatchRun{step: @prebuild, state: :waiting, pool_id: pool_id} = run ->
        if Repo.exists?(from n in Node, where: n.id == ^pool_id and not is_nil(n.deleted_at)),
          do: [run.workspace_id | end_lost(run, held, now)],
          else: []

      _ended_or_claimed ->
        []
    end
  end

  # The waiting prebuild `run` ended `lost`, with a stale dispatch of it not yet ended
  # (`run_ended`); its slot was freed when its lease lapsed. Then its build failed on the
  # record `held` has, and the runs held for it go on (the moduledoc).
  defp end_lost(%DispatchRun{id: id} = run, held, now) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id),
        set: [state: :ended, end_cause: :lost, updated_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^id,
          where: not is_nil(d.stale_at) and is_nil(d.ended_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    case held do
      {:build, %Record{} = record, collections, work_item_ids} ->
        if Environments.newer_build?(record, run) or Environments.built_by?(record, run) do
          []
        else
          :ok = Environments.record_end_failure(record, :lost, now)
          lost = %{record | failure_cause: :lost}
          Environments.build_failed(lost, run, :lost, collections, work_item_ids, now)
        end

      _no_record ->
        []
    end
  end

  ## The wake

  # subscribe/1 listens for the changes of the queue and the slots of `workspace_id`, or,
  # with `:instance`, of every workspace.
  @doc false
  @spec subscribe(Ecto.UUID.t() | :instance) :: :ok | {:error, term}
  def subscribe(workspace_id) when is_binary(workspace_id) or workspace_id == :instance,
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))

  # unsubscribe/1 stops listening on `workspace_id`, or on `:instance`.
  @doc false
  @spec unsubscribe(Ecto.UUID.t() | :instance) :: :ok
  def unsubscribe(workspace_id) when is_binary(workspace_id) or workspace_id == :instance,
    do: Phoenix.PubSub.unsubscribe(Apiary.PubSub, topic(workspace_id))

  # broadcast/1 tells each workspace whose id `told` holds that its queue or its slots
  # changed, and the instance's topic once when `told` has any workspace id, and each
  # work item `told` names as `{:work_item, workspace_id, public_id}`, whose run settled
  # (`Apiary.Dispatches.Settle`), that it changed, on the topic of the work items of its
  # workspace (`Apiary.WorkItems.topic/1`): `{:work_items_changed, ids}`, public ids
  # only, one message per workspace.
  @doc false
  @spec broadcast([Ecto.UUID.t() | Settle.told()]) :: :ok
  def broadcast(told) when is_list(told) do
    {work_items, workspace_ids} = told |> Enum.uniq() |> Enum.split_with(&is_tuple/1)

    for workspace_id <- workspace_ids,
        do: Phoenix.PubSub.broadcast(Apiary.PubSub, topic(workspace_id), {__MODULE__, :changed})

    if workspace_ids != [],
      do: Phoenix.PubSub.broadcast(Apiary.PubSub, topic(:instance), {__MODULE__, :changed})

    for {workspace_id, ids} <-
          Enum.group_by(work_items, &elem(&1, 1), &elem(&1, 2)) do
      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Apiary.WorkItems.topic(workspace_id),
        {:work_items_changed, ids}
      )
    end

    :ok
  end

  defp topic(:instance), do: "dispatches:instance"
  defp topic(workspace_id), do: "dispatches:" <> workspace_id

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.Dispatches.#{what} runs inside the caller's transaction")
  end
end
