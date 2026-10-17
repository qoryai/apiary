defmodule Apiary.Dispatches do
  @moduledoc false

  # The runs a workspace's node pools claim and start, as the provisioner contract has
  # them (qoryai/integrations, `contracts/provisioner/v1`): one queue per workspace, which
  # any node pool of the workspace claims from with its pool's access key
  # (`Apiary.Dispatches.DispatchRun`, `Apiary.Dispatches.Dispatch`).
  #
  # ## Queueing: `queue/2` and `cancel_for_undo/1`
  #
  # `queue(work_item, take_in)` writes, inside the caller's transaction, the first run of a
  # take in of `work_item`: waiting, `attempt` 1 of `of/0`, for the step `step/0`, in the
  # workspace the work item is in as the transaction reads it, its row locked
  # `FOR UPDATE` first, so that a move of the work item to another workspace waits for
  # the run, or the run for the move. The database names a run's work item by the
  # organisation alone; this is what holds a queued run to its work item's workspace. The
  # run waits for no pool in particular: any pool of that workspace may claim it.
  #
  # `cancel_for_undo(work_item)`, inside the caller's transaction, is what an undo of
  # the work item's take in asks first. An undo works while no claim holds a run of the
  # current take in: `{:error, :claimed}` while a dispatch holds one, neither stale nor
  # ended before its handover, and once one was handed over. Else it ends the take in's
  # waiting runs, end cause `undone`, a run back in the queue after a lapsed lease or a
  # release with retry among them, and answers `:ok`; a stale dispatch of a run it ends
  # ends with it, end cause `run_ended`. A lease that lapsed and was not yet swept is
  # lapsed first (`Apiary.Dispatches.Slots.free/2`), so the run it held waits again. The
  # runs of the take in are locked `FOR UPDATE` before their dispatches are looked at, so
  # a claim of one either commits before and is seen, or finds the run ended.
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
  #   3. the pool's row locked `FOR UPDATE`, so two claims of one pool, and a claim and a
  #      registration on the pool (`Apiary.Nodes.check_instance_limit/3`), take turns;
  #   4. the pool's choice of gateway, as it resolves now (`Apiary.Gateways.resolve/1`):
  #      one that leads to no gateway is `{:error, :no_gateway}`;
  #   5. the slots due freed (`Apiary.Dispatches.Slots.free/2`), then the pool's limit
  #      counted: its held slots and its live runs that were not dispatched; at the limit,
  #      `{:ok, :none}`;
  #   6. the oldest waiting run of the key's workspace, by `queued_at`, locked
  #      `FOR UPDATE SKIP LOCKED`, so two claims never take one run and neither waits on
  #      the other; none is `{:ok, :none}`;
  #   7. the run claimed and its dispatch written: its pool, its access key, its
  #      organisation and its workspace from the key alone, `claimed_at` `now` and
  #      `lease_until` `now` in whole seconds plus `lease_seconds/0`.
  #
  # `{:ok, claimed}` carries the dispatch, its run, the run's work item and the pool. The
  # workspaces whose queue the freed slots changed are told once the transaction commits.
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
  # ## The clock
  #
  # `now/0` is the one clock of the queue: a claim's `claimed_at` and `lease_until`, the
  # slots freed and the sweep all read it, never the database's.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, AccessKeys, Gateways, Nodes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Nodes.Node
  alias Apiary.WorkItems.WorkItem

  # The step every run is queued for today: the contract's `explore`.
  @step "explore"
  # The runs a take in has at most, the explore contract's `run.of`.
  @of 3
  # How long a dispatch is the starter's, from its claim, in seconds.
  @lease_seconds 600

  @typedoc "What a claim took: the dispatch, its run, the run's work item and the pool."
  @type claimed :: %{
          dispatch: Dispatch.t(),
          run: DispatchRun.t(),
          work_item: WorkItem.t(),
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

    %{organisation_id: organisation_id, workspace_id: workspace_id} =
      Repo.one!(
        from w in WorkItem,
          where: w.id == ^id,
          lock: "FOR UPDATE",
          select: %{organisation_id: w.organisation_id, workspace_id: w.workspace_id}
      )

    result =
      %DispatchRun{organisation_id: organisation_id, workspace_id: workspace_id}
      |> DispatchRun.queue_changeset(%{
        work_item_id: id,
        step: @step,
        take_in: take_in,
        attempt: 1,
        of: @of,
        queued_at: now()
      })
      |> Repo.insert()

    with {:ok, _run} <- result, do: broadcast([workspace_id])
    result
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

    # A lease that lapsed unswept frees its run first; then the runs as they stand.
    freed = if run_ids == [], do: [], else: Slots.free({:runs, run_ids}, now)
    runs = Repo.all(from r in DispatchRun, where: r.id in ^run_ids)

    if Enum.any?(runs, &(&1.state in [:claimed, :handed_over])) do
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
          {:ok, {take(key, pool, now), freed}}
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

  # The key as a request's verification reads it now: of the same pool, workspace and
  # organisation as when the request verified, or none.
  defp current_key(key_id) do
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
          lock: "FOR UPDATE"
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

  defp take(key, pool, now) do
    with :ok <- below_limit(pool, now),
         %DispatchRun{} = run <- oldest_waiting(key) do
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
        |> Repo.insert!()

      work_item = Repo.get!(WorkItem, run.work_item_id)

      %{dispatch: dispatch, run: %{run | state: :claimed}, work_item: work_item, pool: pool}
    else
      _none -> :none
    end
  end

  # The pool's held slots and its live runs that were not dispatched, against its limit;
  # a pool without one takes any.
  defp below_limit(%Node{instance_limit: nil}, _now), do: :ok

  defp below_limit(%Node{instance_limit: limit} = pool, now) do
    if Nodes.instances_in_use(pool, now) < limit, do: :ok, else: :at_limit
  end

  defp oldest_waiting(%AccessKey{organisation_id: organisation_id, workspace_id: workspace_id}) do
    Repo.one(
      from r in DispatchRun,
        where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id,
        where: fragment("? = 'waiting'", r.state),
        order_by: [asc: r.queued_at, asc: r.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
    )
  end

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

  # broadcast/1 tells each of `workspace_ids` that its queue or its slots changed.
  @doc false
  @spec broadcast([Ecto.UUID.t()]) :: :ok
  def broadcast(workspace_ids) when is_list(workspace_ids) do
    for workspace_id <- Enum.uniq(workspace_ids),
        do: Phoenix.PubSub.broadcast(Apiary.PubSub, topic(workspace_id), {__MODULE__, :changed})

    :ok
  end

  defp topic(workspace_id), do: "dispatches:" <> workspace_id

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.Dispatches.#{what} runs inside the caller's transaction")
  end
end
