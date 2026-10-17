defmodule Apiary.DispatchesTest do
  # The queue of a workspace and its claims (`Apiary.Dispatches`): a run queued in its
  # work item's workspace, an undo before, during and after a claim, one try at a claim
  # against the pool's limit, the slots freed once, the sweep of lapsed leases on one clock, and
  # the instance limit of a pool that counts both its dispatched and its other runs. A
  # claim asks `dispatch.claim`, of the `factory` feature.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Nodes}
  alias Apiary.Adapters.Connection
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Nodes.Node
  alias Apiary.WorkItems.WorkItem

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{scope: scope, pool: pool, key: key}
  end

  defp queue!(work_item, take_in \\ 1) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, take_in) end)
    run
  end

  defp queued!(scope), do: scope |> work_item_fixture() |> queue!()

  defp claimed!(key, now \\ Dispatches.now()) do
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, now)
    dispatch
  end

  # A work item's columns as it stands in an ended `state`, with the time it ended.
  defp ended_state(:closed), do: [state: :closed, closed_at: Dispatches.now()]
  defp ended_state(:declined), do: [state: :declined, declined_at: Dispatches.now()]
  defp ended_state(:undone), do: [state: :undone]

  defp undo(work_item), do: Repo.transact(fn -> {:ok, Dispatches.cancel_for_undo(work_item)} end)

  defp run!(run), do: Repo.get!(DispatchRun, run.id)
  defp dispatch!(dispatch), do: Repo.get!(Dispatch, dispatch.id)

  describe "queue/2" do
    test "writes the first run of the take in, waiting in the work item's workspace", ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)

      assert %DispatchRun{
               state: :waiting,
               step: "explore",
               take_in: 1,
               attempt: 1,
               of: 3,
               end_cause: nil
             } = run!(run)

      assert run.work_item_id == work_item.id
      assert run.workspace_id == ctx.scope.workspace.id
      assert run.organisation_id == ctx.scope.organisation.id
      assert {:ok, _uuid} = Ecto.UUID.cast(run.run_id)
      assert Dispatches.step() == "explore" and Dispatches.of() == 3
    end

    test "queues in the workspace the work item is in now, not the one the caller loaded",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      other = workspace_fixture(ctx.scope.organisation)

      # Moved after the caller loaded it: the struct still names the first workspace.
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      run = queue!(work_item)
      assert run.workspace_id == other.id
      assert run!(run).workspace_id == other.id
    end

    test "tells the work item's workspace", ctx do
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)
      queued!(ctx.scope)
      assert_received {Dispatches, :changed}
    end

    test "runs only inside the caller's transaction", ctx do
      work_item = work_item_fixture(ctx.scope)
      assert_raise ArgumentError, fn -> Dispatches.queue(work_item, 1) end
      assert_raise ArgumentError, fn -> Dispatches.cancel_for_undo(work_item) end
    end
  end

  describe "cancel_for_undo/1" do
    @describetag needs: :factory

    test "before a claim ends the waiting run, cause undone, and no pool claims it", ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)

      assert {:ok, :ok} = undo(work_item)
      assert %DispatchRun{state: :ended, end_cause: :undone} = run!(run)
      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
    end

    test "while a claim holds the run is refused, and changes nothing", ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)

      assert {:ok, {:error, :claimed}} = undo(work_item)
      assert %DispatchRun{state: :claimed, end_cause: nil} = run!(run)
      assert %Dispatch{ended_at: nil, stale_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
    end

    test "after the lease lapsed and the run waits again, ends it undone, and its stale dispatch with it",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)
      Dispatches.sweep(dispatch.lease_until)
      assert run!(run).state == :waiting

      assert {:ok, :ok} = undo(work_item)
      assert %DispatchRun{state: :ended, end_cause: :undone} = run!(run)

      assert %Dispatch{stale_at: %DateTime{}, ended_at: %DateTime{}, end_cause: :run_ended} =
               dispatch!(dispatch)

      assert Dispatches.claim(ctx.key, dispatch.lease_until) == {:ok, :none}
    end

    test "a lease that lapsed and was not yet swept is lapsed first, and the run ends undone",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [
          claimed_at: DateTime.add(dispatch.claimed_at, -700, :second),
          lease_until: DateTime.add(dispatch.lease_until, -700, :second)
        ]
      )

      assert {:ok, :ok} = undo(work_item)
      assert %DispatchRun{state: :ended, end_cause: :undone} = run!(run)

      assert %Dispatch{
               stale_at: %DateTime{},
               slot_freed_at: %DateTime{},
               end_cause: :run_ended
             } = dispatch!(dispatch)

      assert Slots.held(ctx.pool.id) == 0
    end

    test "after a release with retry, the run waiting again, ends it undone", ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)
      released_at = Dispatches.now()

      # As a release with retry before the handover leaves them.
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [ended_at: released_at, end_cause: :released, slot_freed_at: released_at]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [state: :waiting])

      assert {:ok, :ok} = undo(work_item)
      assert %DispatchRun{state: :ended, end_cause: :undone} = run!(run)
      assert %Dispatch{end_cause: :released} = dispatch!(dispatch)
    end

    test "after the handover is refused", ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)
      at = DateTime.add(dispatch.claimed_at, 1, :second)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [state: :handed_over])

      assert {:ok, {:error, :claimed}} = undo(work_item)
      assert run!(run).state == :handed_over
    end

    test "with no run queued is :ok", ctx do
      work_item = work_item_fixture(ctx.scope)
      assert {:ok, :ok} = undo(work_item)
    end
  end

  describe "claim/2" do
    @describetag needs: :factory

    test "takes the oldest waiting run of the key's workspace, with the key's pool and key",
         ctx do
      first = queued!(ctx.scope)
      _second = queued!(ctx.scope)
      now = Dispatches.now()

      {:ok, %{dispatch: dispatch, run: run, work_item: work_item, pool: pool}} =
        Dispatches.claim(ctx.key, now)

      assert run.id == first.id
      assert run!(first).state == :claimed
      assert pool.id == ctx.pool.id
      assert work_item.id == first.work_item_id

      assert %Dispatch{
               pool_id: pool_id,
               access_key_id: key_id,
               organisation_id: organisation_id,
               workspace_id: workspace_id,
               claimed_at: ^now,
               slot_freed_at: nil
             } = dispatch!(dispatch)

      assert {pool_id, key_id} == {ctx.pool.id, ctx.key.id}
      assert {organisation_id, workspace_id} == {ctx.key.organisation_id, ctx.key.workspace_id}

      assert DateTime.compare(
               dispatch.lease_until,
               DateTime.add(DateTime.truncate(now, :second), 600, :second)
             ) == :eq

      assert dispatch.lease_until == Dispatches.lease_until(now)
      assert Dispatch.public_id?(dispatch.public_id)
    end

    test "ends a waiting run whose work item's connection ended, and takes the next", ctx do
      gone = work_item_fixture(ctx.scope)
      gone_run = queue!(gone)
      next = queued!(ctx.scope)

      Repo.update_all(from(c in Connection, where: c.id == ^gone.connection_id),
        set: [state: :ended, ended_at: Dispatches.now(), ended_reason: :adapter_reported]
      )

      :ok = Dispatches.subscribe(ctx.scope.workspace.id)
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert id == next.id
      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(gone_run)
      refute Repo.exists?(from d in Dispatch, where: d.dispatch_run_id == ^gone_run.id)
      assert_received {Dispatches, :changed}
    end

    test "ends a waiting run whose work item moved to another workspace; with no other, takes none",
         ctx do
      moved = work_item_fixture(ctx.scope)
      run = queue!(moved)
      other = workspace_fixture(ctx.scope.organisation)

      Repo.update_all(from(w in WorkItem, where: w.id == ^moved.id),
        set: [workspace_id: other.id]
      )

      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)
      assert Repo.aggregate(Dispatch, :count) == 0
    end

    test "ends the waiting runs of work items closed, declined or undone, each with its cause",
         ctx do
      ended =
        for {state, cause} <- [closed: :closed, declined: :closed, undone: :undone] do
          work_item = work_item_fixture(ctx.scope)
          run = queue!(work_item)

          Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
            set: ended_state(state)
          )

          {run, cause}
        end

      next = queued!(ctx.scope)
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert id == next.id

      for {run, cause} <- ended,
          do: assert(%DispatchRun{state: :ended, end_cause: ^cause} = run!(run))
    end

    test "at the pool's limit ends nothing", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      queued!(ctx.scope)
      claimed!(key)

      gone = work_item_fixture(ctx.scope)
      run = queue!(gone)
      Repo.update_all(from(w in WorkItem, where: w.id == ^gone.id), set: ended_state(:closed))

      assert Dispatches.claim(key, Dispatches.now()) == {:ok, :none}
      assert run!(run).state == :waiting
    end

    test "takes no run of another workspace", ctx do
      other = workspace_fixture(ctx.scope.organisation)
      queued!(workspace_scope(ctx.scope.user, other))
      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
    end

    test "at the pool's limit takes nothing, and takes again once a slot is freed", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      queued!(ctx.scope)
      second = queued!(ctx.scope)

      dispatch = claimed!(key)
      assert Slots.held(pool.id) == 1
      assert Dispatches.claim(key, Dispatches.now()) == {:ok, :none}
      assert run!(second).state == :waiting

      {:ok, true} = Repo.transact(fn -> {:ok, Slots.free_slot(dispatch, Dispatches.now())} end)
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(key, Dispatches.now())
      assert id == second.id
    end

    test "counts the pool's live runs that were not dispatched against its limit", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      node_run_fixture(pool, "i_direct")
      queued!(ctx.scope)
      assert Dispatches.claim(key, Dispatches.now()) == {:ok, :none}
    end

    test "a key revoked or of an organisation out of use since is unauthorized, and takes nothing",
         ctx do
      run = queued!(ctx.scope)

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:error, :unauthorized}
      Process.put(:out_of_use, [])

      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:error, :unauthorized}
      assert run!(run).state == :waiting
    end

    test "a node's key is unauthorized", ctx do
      node = node_fixture(ctx.scope)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, node)
      queued!(ctx.scope)
      assert Dispatches.claim(key, Dispatches.now()) == {:error, :unauthorized}
    end

    test "dispatch.claim refused or not found is one answer, forbidden", ctx do
      queued!(ctx.scope)

      for stub <- [Apiary.EditionStubs.NoClaim, Apiary.EditionStubs.HidesClaim] do
        :ok = Apiary.Edition.put_test_stub(stub)
        assert Dispatches.claim(ctx.key, Dispatches.now()) == {:error, :forbidden}, inspect(stub)
      end

      assert Repo.aggregate(Dispatch, :count) == 0
    end

    test "a choice of gateway that leads to none is no_gateway, and takes nothing", ctx do
      run = queued!(ctx.scope)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
        set: [gateway_choice: :default]
      )

      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:error, :no_gateway}
      assert run!(run).state == :waiting

      gateway = gateway_fixture(ctx.scope)
      {:ok, _} = Nodes.make_default_gateway(ctx.scope, gateway)
      enrolled_key_fixture(ctx.scope, gateway)
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert id == run.id
    end
  end

  describe "the sweep and the slots" do
    @describetag needs: :factory

    test "a lease lapses at lease_until, not before, on the queue's clock", ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      before = DateTime.add(dispatch.lease_until, -1, :microsecond)

      assert Dispatches.sweep(before) == []
      assert %Dispatch{stale_at: nil, slot_freed_at: nil} = dispatch!(dispatch)

      assert Dispatches.sweep(dispatch.lease_until) == [ctx.scope.workspace.id]

      assert %Dispatch{stale_at: stale_at, slot_freed_at: stale_at} = dispatch!(dispatch)
      assert stale_at == dispatch.lease_until
      assert Slots.held(ctx.pool.id) == 0
    end

    test "a lapsed run waits again with its run_id and its place in the queue", ctx do
      first = queued!(ctx.scope)
      second = queued!(ctx.scope)
      dispatch = claimed!(ctx.key)

      Dispatches.sweep(dispatch.lease_until)

      again = run!(first)
      assert %DispatchRun{state: :waiting} = again
      assert again.run_id == first.run_id
      assert again.queued_at == first.queued_at

      # It is ahead of the run queued after it, under a new dispatch.
      assert {:ok, %{run: %{id: id}, dispatch: next}} =
               Dispatches.claim(ctx.key, dispatch.lease_until)

      assert id == first.id
      assert next.id != dispatch.id
      assert run!(second).state == :waiting
    end

    test "frees the slot whatever the pool or the key: deleted pool, revoked key", ctx do
      run = queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      {:ok, _} = Nodes.delete_node(ctx.scope, ctx.pool)

      Dispatches.sweep(dispatch.lease_until)

      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: %DateTime{}} = dispatch!(dispatch)

      # The run waits for the workspace's other pools.
      assert run!(run).state == :waiting
      other = pool_fixture(ctx.scope)
      %{access_key: other_key} = enrolled_key_fixture(ctx.scope, other)
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(other_key, dispatch.lease_until)
      assert id == run.id
    end

    test "a claim frees its pool's lapsed slots before it counts", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      first = queued!(ctx.scope)
      dispatch = claimed!(key)

      # No sweep ran: the claim at the lease's end frees the slot and takes the run back.
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(key, dispatch.lease_until)
      assert id == first.id
      assert %Dispatch{stale_at: %DateTime{}} = dispatch!(dispatch)
      assert Slots.held(pool.id) == 1
    end

    test "an ended dispatch's slot is freed once, at the first time", ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      ended_at = Dispatches.now()

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [ended_at: ended_at, end_cause: :closed]
      )

      later = DateTime.add(ended_at, 5, :second)
      assert Dispatches.sweep(later) == [ctx.scope.workspace.id]
      assert dispatch!(dispatch).slot_freed_at == later

      assert Dispatches.sweep(DateTime.add(later, 5, :second)) == []
      assert dispatch!(dispatch).slot_freed_at == later

      assert {:ok, false} =
               Repo.transact(fn -> {:ok, Slots.free_slot(dispatch, Dispatches.now())} end)

      assert dispatch!(dispatch).slot_freed_at == later
    end

    test "the sweep job frees what is due", ctx do
      run = queued!(ctx.scope)
      dispatch = claimed!(ctx.key)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [
          claimed_at: DateTime.add(dispatch.claimed_at, -700, :second),
          lease_until: DateTime.add(dispatch.lease_until, -700, :second)
        ]
      )

      assert :ok = perform_job(Apiary.Dispatches.Sweep, %{})
      assert %Dispatch{stale_at: %DateTime{}} = dispatch!(dispatch)
      assert run!(run).state == :waiting
    end

    test "a handed-over dispatch never lapses", ctx do
      run = queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      at = DateTime.add(dispatch.claimed_at, 1, :second)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [state: :handed_over]
      )

      assert Dispatches.sweep(DateTime.add(dispatch.lease_until, 60, :second)) == []
      assert %Dispatch{stale_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
      assert run!(run).state == :handed_over
    end
  end

  describe "the instance limit with dispatched runs" do
    @describetag needs: :factory

    test "a registration counts the slots claims hold", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      queued!(ctx.scope)
      claimed!(key)

      assert {:ok, {:error, :instance_limit}} =
               Repo.transact(fn ->
                 {:ok, Nodes.check_instance_limit(pool, "i_1", Dispatches.now())}
               end)
    end

    test "a dispatched run counts by its slot, not again by its instance", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 2)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      run = queued!(ctx.scope)
      claimed!(key)

      # The run registered for it, alive on the pool, as its handover makes it.
      node_run_fixture(pool, run.run_id, %{dispatch_run_id: run.id})

      assert Nodes.instances_in_use(pool, Dispatches.now()) == 1
      node_run_fixture(pool, "i_direct")
      assert Nodes.instances_in_use(pool, Dispatches.now()) == 2

      assert {:ok, {:error, :instance_limit}} =
               Repo.transact(fn ->
                 {:ok, Nodes.check_instance_limit(pool, "i_other", Dispatches.now())}
               end)
    end
  end
end
