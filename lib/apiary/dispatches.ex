defmodule Apiary.Dispatches do
  @moduledoc false

  # The runs a workspace's node pools claim and start, as the provisioner contract has
  # them (qoryai/integrations, `contracts/provisioner/v1`): one queue per workspace, which
  # any node pool of the workspace claims from with its pool's access key
  # (`Apiary.Dispatches.DispatchRun`, `Apiary.Dispatches.Dispatch`).
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
  # release with retry before its handover is the same run, not a new one. While a run of
  # the take in has not ended, waiting, claimed or handed over, it is `{:error, :running}`;
  # once the highest attempt is its `of`, `{:error, :used_up}`; a take in with no run is
  # `{:error, :no_run}`, as its first run is `queue/2`'s to write. Two at once for one take
  # in take turns on the work item: the second reads the runs only once the first
  # committed, so the two never write the same attempt.
  #
  # `queue_prebuild(collection, pool, environment_ref)` writes, inside the caller's
  # transaction, a run for the step `prebuild`: waiting in the pool's workspace, which is
  # the collection's, held for that pool, for the collection's `environment_ref`. At most
  # one waits per collection and pool: while one waits, it is that run, its
  # `environment_ref` set to the newer one, with when it took it (`environment_ref_at`),
  # and its place in the queue kept; a claimed or
  # handed-over one is left as it is. It has no work item and counts toward no take in;
  # like any run, it takes a slot of the pool when it is claimed. `Apiary.Environments`
  # decides when one is due, and writes it under the lock of the pool's environment record
  # of the collection (`Apiary.Dispatches.Slots` names the order of every lock).
  #
  # `end_waiting_prebuilds(collection_ids, now)` ends, inside the caller's transaction,
  # which holds their environment records, the waiting prebuilds of collections that no
  # longer name an `environment_ref`, `collection_ended`: nothing is left to build for
  # them. A claimed or handed-over one is left as it is.
  #
  # `cancel_for_undo(work_item)`, inside the caller's transaction, is what an undo of
  # the work item's take in asks first. An undo works while no claim holds a run of the
  # current take in: `{:error, :claimed}` while a dispatch holds one, neither stale nor
  # ended before its handover, and once one was handed over, after its run ended too (a
  # dispatch keeps `handed_over_at`). Else it ends the take in's waiting runs, end cause
  # `undone`, a run back in the queue after a lapsed lease or a release with retry among
  # them, and answers `:ok`; a stale dispatch of a run it ends ends with it, end cause
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
  # (`Apiary.Dispatches.Slots.free/2`). A handed-over run is left as it is: it goes on to
  # its end, and its result and its outcome are taken as before.
  #
  # ## Claiming: `claim/2`
  #
  # `claim(access_key, now)` is one try at a claim by the node pool of `access_key`, in
  # one transaction:
  #
  #   1. the key read again as a request's verification reads it
  #      (`Apiary.AccessKeys.fetch_for_verification/1`): revoked, of a pool deleted, or of a
  #      workspace or an organisation marked for deletion or out of use since, it is
  #      `{:error, :unauthorized}`;
  #   2. `dispatch.claim` asked of the key's workspace (`Apiary.Access`): any refusal is
  #      `{:error, :forbidden}`, one answer whatever its reason;
  #   3. the pool's row locked `FOR NO KEY UPDATE`, so two claims of one pool, and a claim
  #      and a registration on the pool (`Apiary.Nodes.check_instance_limit/3`, which
  #      locks it `FOR UPDATE`), take turns, while a trigger's writes, whose foreign keys
  #      to the pool take `FOR KEY SHARE`, never wait on it (`Apiary.Dispatches.Slots`);
  #   4. the pool's choice of gateway, as it resolves now (`Apiary.Gateways.resolve/1`):
  #      one that leads to no gateway is `{:error, :no_gateway}`;
  #   5. the slots due freed (`Apiary.Dispatches.Slots.free/2`), then the pool's limit
  #      counted: its held slots and its live runs that were not dispatched; at the limit,
  #      `{:ok, :none}`;
  #   6. the oldest waiting run of the key's workspace, by `queued_at`, that the claim may
  #      take, locked `FOR UPDATE SKIP LOCKED`, so two claims never take one run and
  #      neither waits on the other; none is `{:ok, :none}`. A prebuild is taken only by
  #      the pool it is held for. A run whose work item has no target is taken as any
  #      other. A run whose work item is no longer live (closed, declined, undone, its
  #      connection ended, or gone) or no longer in the run's workspace is not handed
  #      out: it ends, `undone` for a work item undone and `closed` otherwise; nor is a
  #      prebuild whose collection ended, is assigned to no workspace or another one, has
  #      no target or no `environment_ref`, or whose connection ended: it ends,
  #      `collection_ended`. A stale dispatch of a run ended
  #      so ends with it (`run_ended`), and the next is taken, up to 100 per claim;
  #   7. the run claimed and its dispatch written: its pool, its access key, its
  #      organisation and its workspace from the key alone, `claimed_at` `now` and
  #      `lease_until` `now` in whole seconds plus `lease_seconds/0`.
  #
  # `{:ok, claimed}` carries the dispatch, its run, the run's work item (nil for a
  # prebuild), the prebuild's collection (nil for any other step) and the pool. The
  # workspaces whose queue the freed slots or the ended runs changed are told once the
  # transaction commits.
  #
  # ## The starter on a dispatch: `dispatched/3`, `handover/3`, `release/3` and `prebuilt/3`
  #
  # `dispatched(access_key, dispatch_id, meta)` records that the starter of the pool of
  # `access_key` started the job for a dispatch its pool claimed, and
  # `handover(access_key, dispatch_id, meta)` hands the dispatch's run over to that job:
  # the run registered through the gateway the pool's choice resolves to, its run key made
  # and the dispatch handed over in one transaction, or the refusal the provisioner
  # contract gives, in its order (`Apiary.Dispatches.Handover`). A handover that cannot form
  # what the run is made from ends the run and its dispatch, `collection_ended`,
  # `variables_invalid`, `ticket_gone` or `inputs_invalid`, answered as a dispatch that
  # ended.
  #
  # `release(access_key, dispatch_id, meta)` gives the dispatch's run back, with the
  # starter's reason and whether it should wait for another claim, in one transaction, or
  # refuses in the contract's order (`Apiary.Dispatches.Release`): before the handover the
  # dispatch ends, `released`, and its run waits again or ends; after it the run ends with
  # its registered run, `released`, and an explore run with retry queues the next run of
  # its take in (`queue_next/2`).
  #
  # `prebuilt(access_key, dispatch_id, meta)` records the image the job for a prebuild
  # built, on the environment record of its collection and the pool that claimed it, and
  # ends its run of the queue and its dispatch, `prebuilt`, the registered run left to its
  # outcome, in one transaction, or refuses in the contract's order
  # (`Apiary.Dispatches.Prebuilt`).
  #
  # ## The wake: `subscribe/1` and `broadcast/1`
  #
  # A claim held while its pool can claim nothing listens on its workspace's topic: a run
  # queued there, a run back in its queue, or a slot of its pools freed is told there as
  # `{Apiary.Dispatches, :changed}`, and the holder tries again. A run queued inside a
  # transaction is told before that transaction commits, so a holder may find nothing
  # when told; it tries again at its next poll (`ApiaryWeb.Contract.PoolClaimController`).
  #
  # ## The sweep: `sweep/1`
  #
  # `sweep(now)` frees what is due on every pool (`Apiary.Dispatches.Slots.free/2`), in
  # its transaction, and tells the workspaces it changed. `Apiary.Dispatches.Sweep` runs it
  # every minute.
  #
  # ## The end of a run handed over: `end_run_released/2` and `backstop_seconds/1`
  #
  # A run handed over ends with its registered run: by its starter's outcome or its exit,
  # by its starter's release after the handover (`release/3`, which ends it as
  # `end_run_released/2` does, `Apiary.Dispatches.Release`), or by the lost-run check, at
  # its gateway's `attach_by` should it never attach, or at `backstop_seconds/1` of its
  # step after its attach should it have neither an outcome nor an exit by then
  # (`Apiary.Dispatches.RunEnd`). Its dispatch ends with it and the slot
  # it held is freed, once.
  #
  # ## The clock
  #
  # `now/0` is the one clock of the queue: a claim's `claimed_at` and `lease_until`, the
  # slots freed, the sweep and the end of a run its projection ended all read it, never the
  # database's.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, AccessKeys, Gateways, Nodes, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover, Prebuilt, Release, RunEnd, Settle}
  alias Apiary.Dispatches.Slots
  alias Apiary.Nodes.Node
  alias Apiary.WorkItems.WorkItem

  # The step every run of a take in is queued for: the contract's `explore`.
  @step "explore"
  # The step of a run that builds a collection's environment for one node pool.
  @prebuild DispatchRun.prebuild()
  # The index that holds one waiting prebuild per collection and node pool.
  @waiting_prebuild "(source_collection_id, pool_id) WHERE step = 'prebuild' AND state = 'waiting'"
  # The runs a take in has at most, the explore contract's `run.of`.
  @of 3
  # How long a dispatch is the starter's, from its claim, in seconds.
  @lease_seconds 600
  # The waiting runs of work items no longer live one claim ends at most.
  @max_ended 100

  @typedoc """
  What a claim took: the dispatch, its run, the run's work item, or for a prebuild its
  collection, and the pool.
  """
  @type claimed :: %{
          dispatch: Dispatch.t(),
          run: DispatchRun.t(),
          work_item: WorkItem.t() | nil,
          collection: Collection.t() | nil,
          pool: Node.t()
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
  # organisation and the workspace it is in now.
  defp lock_work_item!(id) do
    Repo.one!(
      from w in WorkItem,
        where: w.id == ^id,
        lock: "FOR UPDATE",
        select: %{id: w.id, organisation_id: w.organisation_id, workspace_id: w.workspace_id}
    )
  end

  # A waiting run of take in `take_in` of the locked work item, `attempt` of `of`, for the
  # step `step/0`, in the work item's organisation and workspace; the workspace is told.
  defp insert_run(work_item, take_in, attempt, of) do
    %{id: id, organisation_id: organisation_id, workspace_id: workspace_id} = work_item

    result =
      %DispatchRun{organisation_id: organisation_id, workspace_id: workspace_id}
      |> DispatchRun.queue_changeset(%{
        work_item_id: id,
        step: @step,
        take_in: take_in,
        attempt: attempt,
        of: of,
        queued_at: now()
      })
      |> Repo.insert()

    with {:ok, _run} <- result, do: broadcast([workspace_id])
    result
  end

  # queue_prebuild/3 writes a run for the step `prebuild` of `collection`, held for the
  # node pool `pool` of the collection's workspace, for `environment_ref`, or sets it, and
  # when it was taken, on the one that waits, inside the caller's transaction (the
  # moduledoc).
  @doc false
  @spec queue_prebuild(Collection.t(), Node.t(), String.t()) ::
          {:ok, DispatchRun.t()} | {:error, Ecto.Changeset.t()}
  def queue_prebuild(
        %Collection{
          id: collection_id,
          organisation_id: organisation_id,
          workspace_id: workspace_id
        },
        %Node{
          kind: :pool,
          id: pool_id,
          organisation_id: organisation_id,
          workspace_id: workspace_id
        },
        environment_ref
      )
      when is_binary(workspace_id) and is_binary(environment_ref) do
    in_transaction!("queue_prebuild/3")

    result =
      %DispatchRun{organisation_id: organisation_id, workspace_id: workspace_id}
      |> DispatchRun.prebuild_changeset(%{
        source_collection_id: collection_id,
        pool_id: pool_id,
        environment_ref: environment_ref,
        queued_at: now()
      })
      |> Repo.insert(
        on_conflict: {:replace, [:environment_ref, :environment_ref_at, :updated_at]},
        conflict_target: {:unsafe_fragment, @waiting_prebuild},
        returning: true
      )

    with {:ok, _run} <- result, do: broadcast([workspace_id])
    result
  end

  # end_waiting_prebuilds/2 ends the waiting prebuilds of the collections
  # `collection_ids`, `collection_ended`, with any stale dispatch of them (`run_ended`),
  # inside the caller's transaction, which holds their environment records (the
  # moduledoc).
  @doc false
  @spec end_waiting_prebuilds([Ecto.UUID.t()], DateTime.t()) :: :ok
  def end_waiting_prebuilds(collection_ids, %DateTime{} = now) when is_list(collection_ids) do
    in_transaction!("end_waiting_prebuilds/2")

    {_count, ended} =
      Repo.update_all(
        from(r in DispatchRun,
          where: r.source_collection_id in ^collection_ids and r.step == ^@prebuild,
          where: fragment("? = 'waiting'", r.state),
          select: r.id
        ),
        set: [state: :ended, end_cause: :collection_ended, updated_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id in ^ended,
          where: not is_nil(d.stale_at) and is_nil(d.ended_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    :ok
  end

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

        freed = Slots.free({:runs, run_ids}, now)
        {:ok, Enum.uniq(workspace_ids ++ lapsed ++ freed)}
    end
  end

  ## Claiming

  # claim/2 is one try at a claim by the node pool of `access_key` at `now` (the
  # moduledoc): `{:ok, claimed}`, `{:ok, :none}` when the pool can claim nothing now, or
  # `{:error, :unauthorized | :forbidden | :no_gateway}`, after which nothing is written.
  @doc false
  @spec claim(AccessKey.t(), DateTime.t()) ::
          {:ok, claimed | :none} | {:error, :unauthorized | :forbidden | :no_gateway}
  def claim(%AccessKey{key_id: key_id}, %DateTime{} = now) when is_binary(key_id) do
    result =
      Repo.transact(fn ->
        with {:ok, key} <- current_key(key_id),
             :ok <- may_claim(key),
             {:ok, pool} <- lock_pool(key),
             :ok <- gateway(pool) do
          freed = Slots.free(pool.id, now)
          {taken, ended} = take(key, pool, now)
          {:ok, {taken, freed ++ ended}}
        end
      end)

    case result do
      {:ok, {taken, freed}} ->
        broadcast(freed)
        {:ok, taken}

      {:error, _reason} = error ->
        error
    end
  end

  # current_key/1 is the key `key_id` as a request's verification reads it now: of the
  # same pool, workspace and organisation as when the request verified, or
  # `{:error, :unauthorized}`.
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

      _other ->
        {:error, :unauthorized}
    end
  end

  # Asked of the key's workspace, the queue, as the key's scope holds it.
  defp may_claim(key) do
    scope = Scope.for_access_key(key)

    case Access.authorize(scope, :"dispatch.claim", scope.workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp lock_pool(%AccessKey{node_id: pool_id, workspace_id: workspace_id}) do
    pool =
      Repo.one(
        from n in Node,
          where: n.id == ^pool_id and n.workspace_id == ^workspace_id and n.kind == :pool,
          where: is_nil(n.deleted_at),
          lock: "FOR NO KEY UPDATE"
      )

    if pool, do: {:ok, pool}, else: {:error, :unauthorized}
  end

  defp gateway(pool) do
    case Gateways.resolve(pool) do
      :direct -> :ok
      {:gateway, _gateway} -> :ok
      {:error, _reason} -> {:error, :no_gateway}
    end
  end

  # The oldest waiting run the pool may take, claimed, with the workspaces whose queue
  # it ended runs of; `:none` at the limit or with none to take.
  defp take(key, pool, now) do
    case below_limit(pool, now) do
      :ok -> pick(key, pool, now, @max_ended, [])
      :at_limit -> {:none, []}
    end
  end

  # A waiting run whose work item, or a prebuild whose collection, can no longer be
  # handed out is ended, with any stale dispatch of it (`run_ended`), and the next one
  # looked at, `max` at most per claim.
  defp pick(_key, _pool, _now, 0, ended), do: {:none, ended}

  defp pick(key, pool, now, max, ended) do
    case oldest_waiting(key) do
      nil ->
        {:none, ended}

      %DispatchRun{} = run ->
        case for_run(run) do
          {:ok, for} ->
            {claim_run(key, pool, run, for, now), ended}

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

            pick(key, pool, now, max - 1, [run.workspace_id | ended])
        end
    end
  end

  # What the run is for: its work item, or a prebuild's collection.
  defp for_run(%DispatchRun{step: @prebuild} = run) do
    with {:ok, collection} <- collection_of(run), do: {:ok, %{collection: collection}}
  end

  defp for_run(%DispatchRun{} = run) do
    with {:ok, work_item} <- work_item_of(run), do: {:ok, %{work_item: work_item}}
  end

  # A prebuild's collection when it is live, assigned to the run's workspace, has a target
  # and an `environment_ref`, and its connection has not ended; else the run ends,
  # `collection_ended`. Read without a lock, as a work item is: the run is locked, and its
  # pool too.
  defp collection_of(%DispatchRun{
         source_collection_id: collection_id,
         workspace_id: workspace_id
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
         environment_ref: ref
       } = collection, connection}
      when is_binary(system) and is_binary(ref) and connection in [:pending, :connected] ->
        {:ok, collection}

      _ended_moved_or_without_target ->
        {:end, :collection_ended}
    end
  end

  # The run's work item when it is live, in the run's workspace, and its connection has
  # not ended; else the cause the run ends for: `undone` for a work item undone, `closed`
  # for any other (closed, declined, its connection ended, moved to another workspace,
  # or gone). Read without a lock: the run is locked, so an undo waits for the claim and
  # is then refused; a close that commits meanwhile finds the run claimed.
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
      %Dispatch{organisation_id: key.organisation_id, workspace_id: key.workspace_id}
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

  # A prebuild goes only to the pool it is held for.
  defp oldest_waiting(%AccessKey{
         organisation_id: organisation_id,
         workspace_id: workspace_id,
         node_id: pool_id
       }) do
    Repo.one(
      from r in DispatchRun,
        where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id,
        where: fragment("? = 'waiting'", r.state),
        where: r.step != ^@prebuild or r.pool_id == ^pool_id,
        order_by: [asc: r.queued_at, asc: r.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  ## The starter on a dispatch

  # dispatched/3 records that the starter started the job for the dispatch `dispatch_id`
  # (`Apiary.Dispatches.Handover.dispatched/3`).
  @doc false
  @spec dispatched(AccessKey.t(), term, %{external: map | nil}) ::
          :ok | {:error, Handover.refusal()}
  def dispatched(%AccessKey{} = access_key, dispatch_id, meta),
    do: Handover.dispatched(access_key, dispatch_id, meta)

  # handover/3 hands the run of the dispatch `dispatch_id` over to the job its starter
  # started, registering it (`Apiary.Dispatches.Handover.handover/3`).
  @doc false
  @spec handover(AccessKey.t(), term, %{body: binary}) ::
          {:ok, Handover.handed_over()} | {:error, Handover.refusal()}
  def handover(%AccessKey{} = access_key, dispatch_id, meta),
    do: Handover.handover(access_key, dispatch_id, meta)

  # release/3 gives back the run of the dispatch `dispatch_id`, with the starter's reason
  # and retry (`Apiary.Dispatches.Release.release/3`).
  @doc false
  @spec release(AccessKey.t(), term, Release.release()) :: :ok | {:error, Release.refusal()}
  def release(%AccessKey{} = access_key, dispatch_id, meta),
    do: Release.release(access_key, dispatch_id, meta)

  # prebuilt/3 records the image the job for the prebuild of the dispatch `dispatch_id`
  # built, and ends its run (`Apiary.Dispatches.Prebuilt.prebuilt/3`).
  @doc false
  @spec prebuilt(AccessKey.t(), term, Prebuilt.prebuilt()) ::
          :ok | {:error, Prebuilt.refusal()}
  def prebuilt(%AccessKey{} = access_key, dispatch_id, meta),
    do: Prebuilt.prebuilt(access_key, dispatch_id, meta)

  ## The end of a run handed over

  # end_run_released/2 ends the run of the queue `dispatch_run_id`, which its starter
  # released after its handover, at `now`, inside the caller's transaction
  # (`Apiary.Dispatches.RunEnd.released/2`): the registered run reads as cancelled with the
  # reason `released`, no outcome is recorded and no `end` is sent; the dispatch ends,
  # `released`, and its slot is freed once. `{:ok, %{run: run, changed: workspace_ids}}`
  # for the caller to broadcast and tell once its transaction commits, or
  # `{:error, :ended | :not_handed_over | :not_found}`, after which nothing is written. The
  # caller locks nothing of the run before, or locks the run of the queue first.
  @doc false
  @spec end_run_released(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, %{run: Apiary.Runs.Run.t() | nil, changed: [Ecto.UUID.t()]}}
          | {:error, :ended | :not_handed_over | :not_found}
  def end_run_released(dispatch_run_id, %DateTime{} = now),
    do: RunEnd.released(dispatch_run_id, now)

  # backstop_seconds/1 is the seconds after its attach by which a run of `step` has its
  # outcome or its exit, or is lost: 1200 for `explore` and 2100 for `prebuild`.
  @doc false
  @spec backstop_seconds(String.t() | nil) :: pos_integer
  def backstop_seconds(step), do: RunEnd.backstop_seconds(step)

  ## The sweep

  # sweep/1 frees what is due at `now` on every pool and tells the workspaces it changed:
  # their ids.
  @doc false
  @spec sweep(DateTime.t()) :: [Ecto.UUID.t()]
  def sweep(%DateTime{} = now) do
    {:ok, freed} = Repo.transact(fn -> {:ok, Slots.free(:all, now)} end)
    broadcast(freed)
    freed
  end

  ## The wake

  # subscribe/1 listens for the changes of the queue and the slots of `workspace_id`.
  @doc false
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term}
  def subscribe(workspace_id) when is_binary(workspace_id),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))

  # unsubscribe/1 stops listening on `workspace_id`.
  @doc false
  @spec unsubscribe(Ecto.UUID.t()) :: :ok
  def unsubscribe(workspace_id) when is_binary(workspace_id),
    do: Phoenix.PubSub.unsubscribe(Apiary.PubSub, topic(workspace_id))

  # broadcast/1 tells each workspace whose id `told` holds that its queue or its slots
  # changed, and each work item `told` names as `{:work_item, workspace_id, public_id}`,
  # whose run settled (`Apiary.Dispatches.Settle`), that it changed, on the topic of the
  # work items of its workspace (`Apiary.WorkItems.topic/1`): `{:work_items_changed, ids}`,
  # public ids only, one message per workspace.
  @doc false
  @spec broadcast([Ecto.UUID.t() | Settle.told()]) :: :ok
  def broadcast(told) when is_list(told) do
    {work_items, workspace_ids} = told |> Enum.uniq() |> Enum.split_with(&is_tuple/1)

    for workspace_id <- workspace_ids,
        do: Phoenix.PubSub.broadcast(Apiary.PubSub, topic(workspace_id), {__MODULE__, :changed})

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

  defp topic(workspace_id), do: "dispatches:" <> workspace_id

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.Dispatches.#{what} runs inside the caller's transaction")
  end
end
