defmodule Apiary.DispatchesTest do
  # The queue of a workspace and its claims (`Apiary.Dispatches`): a run queued in its
  # work item's workspace, the next runs of a take in up to its `of`, a prebuild held for
  # one pool and the claims that take it or never see it, an undo before, during and after
  # a claim, one try at a claim against the pool's limit, the slots freed once, the sweep
  # of lapsed leases on one clock, and the instance limit of a pool that counts both its
  # dispatched and its other runs. A claim asks `dispatch.claim`, of the `factory` feature.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Nodes}
  alias Apiary.Adapters.{Collection, Connection}
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
      assert_raise ArgumentError, fn -> Dispatches.queue_next(work_item, 1) end
      assert_raise ArgumentError, fn -> Dispatches.cancel_for_undo(work_item) end
    end
  end

  describe "queue_next/2" do
    defp queue_next(work_item, take_in \\ 1),
      do: Repo.transact(fn -> {:ok, Dispatches.queue_next(work_item, take_in)} end)

    defp queued_next!(work_item, take_in \\ 1) do
      {:ok, {:ok, run}} = queue_next(work_item, take_in)
      run
    end

    # The run as it stands in `state`, ended `lost` should that state be `:ended`.
    defp put_state!(run, :ended), do: set_run!(run, state: :ended, end_cause: :lost)
    defp put_state!(run, state), do: set_run!(run, state: state)

    defp set_run!(run, set) do
      {1, _rows} = Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: set)
      run!(run)
    end

    defp runs_of(work_item, take_in) do
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id and r.take_in == ^take_in,
          order_by: r.attempt,
          select: {r.attempt, r.of, r.state}
      )
    end

    test "once the take in's run ended, writes its next: attempt 2 of the same of, waiting, a new run",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      first = work_item |> queue!() |> put_state!(:ended)
      run = queued_next!(work_item)

      assert %DispatchRun{
               state: :waiting,
               step: "explore",
               take_in: 1,
               attempt: 2,
               of: 3,
               end_cause: nil
             } = run!(run)

      assert run.work_item_id == work_item.id
      assert run.workspace_id == ctx.scope.workspace.id
      assert run.organisation_id == ctx.scope.organisation.id
      assert run.run_id != first.run_id
      assert run!(first).state == :ended
    end

    test "writes attempt 3 after 2, and once the third ended answers used_up, writing none",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      work_item |> queue!() |> put_state!(:ended)
      work_item |> queued_next!() |> put_state!(:ended)
      third = queued_next!(work_item)
      assert %DispatchRun{attempt: 3, of: 3, state: :waiting} = run!(third)

      put_state!(third, :ended)
      assert {:ok, {:error, :used_up}} = queue_next(work_item)

      assert runs_of(work_item, 1) == [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :ended}]
    end

    test "counts up to the `of` of the take in's runs, not to of/0", ctx do
      work_item = work_item_fixture(ctx.scope)
      work_item |> queue!() |> set_run!(state: :ended, end_cause: :lost, of: 2)

      second = queued_next!(work_item)
      assert %DispatchRun{attempt: 2, of: 2} = run!(second)

      put_state!(second, :ended)
      assert {:ok, {:error, :used_up}} = queue_next(work_item)
    end

    test "while a run of the take in waits, is claimed or is handed over, answers running, writing none",
         ctx do
      for state <- [:waiting, :claimed, :handed_over] do
        work_item = work_item_fixture(ctx.scope)
        work_item |> queue!() |> put_state!(:ended)
        work_item |> queued_next!() |> put_state!(state)

        assert {:ok, {:error, :running}} = queue_next(work_item)
        assert runs_of(work_item, 1) == [{1, 3, :ended}, {2, 3, state}]
      end
    end

    test "while the take in's last run waits, answers running before used_up", ctx do
      work_item = work_item_fixture(ctx.scope)
      work_item |> queue!() |> put_state!(:ended)
      work_item |> queued_next!() |> put_state!(:ended)
      queued_next!(work_item)

      assert {:ok, {:error, :running}} = queue_next(work_item)
    end

    test "a take in with no run answers no_run, writing none", ctx do
      work_item = work_item_fixture(ctx.scope)
      assert {:ok, {:error, :no_run}} = queue_next(work_item)
      assert runs_of(work_item, 1) == []

      # Another take in's runs are not this take in's.
      work_item |> queue!(1) |> put_state!(:ended)
      assert {:ok, {:error, :no_run}} = queue_next(work_item, 2)
    end

    test "a take in again counts its runs from 1, apart from the earlier take in's", ctx do
      work_item = work_item_fixture(ctx.scope)
      work_item |> queue!(1) |> put_state!(:ended)
      work_item |> queued_next!(1) |> put_state!(:ended)
      work_item |> queued_next!(1) |> put_state!(:ended)
      assert {:ok, {:error, :used_up}} = queue_next(work_item, 1)

      again = queue!(work_item, 2)
      assert %DispatchRun{take_in: 2, attempt: 1, of: 3} = run!(again)
      put_state!(again, :ended)

      assert %DispatchRun{take_in: 2, attempt: 2, of: 3} = run!(queued_next!(work_item, 2))
      assert {:ok, {:error, :used_up}} = queue_next(work_item, 1)
      assert {:ok, {:error, :running}} = queue_next(work_item, 2)
    end

    test "queues in the workspace the work item is in now, and tells it", ctx do
      work_item = work_item_fixture(ctx.scope)
      work_item |> queue!() |> put_state!(:ended)
      other = workspace_fixture(ctx.scope.organisation)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      :ok = Dispatches.subscribe(other.id)
      run = queued_next!(work_item)
      assert run!(run).workspace_id == other.id
      assert_received {Dispatches, :changed}
    end
  end

  describe "queue_prebuild/3" do
    @describetag needs: :factory

    test "writes a waiting prebuild held for the pool, with no work item and no take in",
         ctx do
      collection = collection_fixture(ctx.scope)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      {:ok, run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert %DispatchRun{
               step: "prebuild",
               state: :waiting,
               work_item_id: nil,
               take_in: nil,
               attempt: nil,
               of: nil,
               environment_ref: "env-1"
             } = run!(run)

      assert run.source_collection_id == collection.id
      assert run.pool_id == ctx.pool.id
      assert run.workspace_id == ctx.scope.workspace.id
      assert {:ok, _uuid} = Ecto.UUID.cast(run.run_id)
      assert_receive {Dispatches, :changed}
    end

    test "while one waits for the collection and the pool, sets the newer environment_ref on it",
         ctx do
      collection = collection_fixture(ctx.scope)
      other = pool_fixture(ctx.scope)

      {:ok, first} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      {:ok, again} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      assert {again.id, again.run_id, again.queued_at} ==
               {first.id, first.run_id, first.queued_at}

      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} = run!(first)

      # Another pool gets a separate one.
      {:ok, theirs} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, other, "env-2") end)

      assert theirs.id != first.id

      # Claimed, it is left as it is, and the next waits beside it.
      assert {:ok, %{run: %{id: claimed_id}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert claimed_id == first.id

      {:ok, next} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-3") end)

      assert next.id != first.id
      assert %DispatchRun{state: :claimed, environment_ref: "env-2"} = run!(first)
      assert %DispatchRun{state: :waiting, environment_ref: "env-3"} = run!(next)

      # The database holds one waiting per collection and pool.
      assert_raise Postgrex.Error, ~r/dispatch_runs_waiting_prebuild_index/, fn ->
        Repo.update_all(from(r in DispatchRun, where: r.id == ^first.id), set: [state: :waiting])
      end
    end

    test "refuses a pool of another workspace, and runs only inside a transaction", ctx do
      collection = collection_fixture(ctx.scope)

      assert_raise ArgumentError, ~r/caller's transaction/, fn ->
        Dispatches.queue_prebuild(collection, ctx.pool, "env-1")
      end

      workspace = workspace_fixture(ctx.scope.organisation)
      theirs = pool_fixture(%{ctx.scope | workspace: workspace})

      assert_raise FunctionClauseError, fn ->
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, theirs, "env-1") end)
      end

      assert {:error, %Ecto.Changeset{errors: [environment_ref: _]}} =
               Repo.transact(fn ->
                 Dispatches.queue_prebuild(collection, ctx.pool, String.duplicate("é", 201))
               end)
    end
  end

  describe "claim/2 and a prebuild" do
    @describetag needs: :factory

    defp prebuild!(collection, pool, ref \\ "env-1") do
      {:ok, run} = Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, ref) end)
      run
    end

    test "only the pool it is held for takes it, in the queue's order with every other run",
         ctx do
      other = pool_fixture(ctx.scope)
      %{access_key: other_key} = enrolled_key_fixture(ctx.scope, other)
      collection = collection_fixture(ctx.scope)
      run = prebuild!(collection, ctx.pool)
      explore = queued!(ctx.scope)

      # Another pool of the workspace passes it and takes the next run.
      assert {:ok, %{run: %{id: id}, work_item: %{}, collection: nil}} =
               Dispatches.claim(other_key, Dispatches.now())

      assert id == explore.id
      assert Dispatches.claim(other_key, Dispatches.now()) == {:ok, :none}
      assert run!(run).state == :waiting

      # Its pool takes the oldest of the prebuilds held for it and the workspace's other
      # runs.
      later = queued!(ctx.scope)
      run_id = run.id
      assert {:ok, %{run: %{id: ^run_id}}} = Dispatches.claim(ctx.key, Dispatches.now())

      assert {:ok, %{run: %{id: later_id}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert later_id == later.id
    end

    test "ends collection_ended when its collection can no longer be built, and takes the next",
         ctx do
      workspace = workspace_fixture(ctx.scope.organisation)
      ended = collection_fixture(ctx.scope)
      unassigned = collection_fixture(ctx.scope)
      moved = collection_fixture(ctx.scope)
      bare = collection_fixture(ctx.scope)
      cut = collection_fixture(ctx.scope)

      runs =
        for collection <- [ended, unassigned, moved, bare, cut],
            do: prebuild!(collection, ctx.pool)

      kept = collection_fixture(ctx.scope)
      next = prebuild!(kept, ctx.pool)

      now = Dispatches.now()

      Repo.update_all(from(c in Collection, where: c.id == ^ended.id),
        set: [ended_at: now, ended_reason: :disconnected]
      )

      Repo.update_all(from(c in Collection, where: c.id == ^unassigned.id),
        set: [workspace_id: nil]
      )

      Repo.update_all(from(c in Collection, where: c.id == ^moved.id),
        set: [workspace_id: workspace.id]
      )

      Repo.update_all(from(c in Collection, where: c.id == ^bare.id),
        set: [target_system: nil, target_path: nil]
      )

      Repo.update_all(from(c in Connection, where: c.id == ^cut.connection_id),
        set: [state: :ended, ended_at: now, ended_reason: :adapter_reported]
      )

      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert {:ok, %{run: %{id: id}, collection: %{id: kept_id}}} =
               Dispatches.claim(ctx.key, Dispatches.now())

      assert {id, kept_id} == {next.id, kept.id}

      for run <- runs do
        assert %DispatchRun{state: :ended, end_cause: :collection_ended} = run!(run)
        refute Repo.exists?(from d in Dispatch, where: d.dispatch_run_id == ^run.id)
      end

      assert_received {Dispatches, :changed}
    end

    test "a deleted pool's waiting prebuild holds no slot, and holds back no other claim nor the queue's order",
         ctx do
      other = pool_fixture(ctx.scope)
      %{access_key: other_key} = enrolled_key_fixture(ctx.scope, other)
      deleted = pool_fixture(ctx.scope)
      collection = collection_fixture(ctx.scope)

      held = prebuild!(collection, deleted)
      explore = queued!(ctx.scope)
      mine = prebuild!(collection, ctx.pool)
      later = queued!(ctx.scope)
      {:ok, _deleted} = Nodes.delete_node(ctx.scope, deleted)

      # The other pools take the runs in the queue's order, the oldest held for none.
      assert {:ok, %{run: %{id: first}}} = Dispatches.claim(other_key, Dispatches.now())
      assert {:ok, %{run: %{id: second}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert {:ok, %{run: %{id: third}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert [first, second, third] == [explore.id, mine.id, later.id]

      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
      assert Dispatches.claim(other_key, Dispatches.now()) == {:ok, :none}

      # It still waits, and counts toward no pool's slots.
      assert run!(held).state == :waiting
      assert Slots.held(deleted.id) == 0
      assert Slots.held(ctx.pool.id) == 2
      assert Slots.held(other.id) == 1
    end

    test "a prebuild whose collection no longer names an environment_ref ends, collection_ended, and none is handed out",
         ctx do
      collection = collection_fixture(ctx.scope)
      run = prebuild!(collection, ctx.pool)

      Repo.update_all(from(c in Collection, where: c.id == ^collection.id),
        set: [environment_ref: nil]
      )

      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
      assert %DispatchRun{state: :ended, end_cause: :collection_ended} = run!(run)
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

    test "after a handed-over run ended, lost, run_ended or released, is still refused", ctx do
      for cause <- [:lost, :run_ended, :released] do
        work_item = work_item_fixture(ctx.scope)
        run = queue!(work_item)
        dispatch = claimed!(ctx.key)
        at = DateTime.add(dispatch.claimed_at, 1, :second)
        ended_at = DateTime.add(at, 1, :second)

        # As the run's end after its handover leaves them.
        Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
          set: [
            dispatched_at: at,
            handed_over_at: at,
            ended_at: ended_at,
            end_cause: cause,
            slot_freed_at: ended_at
          ]
        )

        Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
          set: [state: :ended, end_cause: cause]
        )

        assert {:ok, {:error, :claimed}} = undo(work_item)
        assert %DispatchRun{state: :ended, end_cause: ^cause} = run!(run)
        assert %Dispatch{end_cause: ^cause} = dispatch!(dispatch)
      end
    end

    test "after a handed-over run ended, with a later run of the take in waiting, is refused",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      first = queue!(work_item)
      dispatch = claimed!(ctx.key)
      at = DateTime.add(dispatch.claimed_at, 1, :second)
      ended_at = DateTime.add(at, 1, :second)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [
          dispatched_at: at,
          handed_over_at: at,
          ended_at: ended_at,
          end_cause: :lost,
          slot_freed_at: ended_at
        ]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^first.id),
        set: [state: :ended, end_cause: :lost]
      )

      second =
        Repo.insert!(%DispatchRun{
          organisation_id: first.organisation_id,
          workspace_id: first.workspace_id,
          work_item_id: work_item.id,
          run_id: Ecto.UUID.generate(),
          step: first.step,
          take_in: first.take_in,
          attempt: 2,
          of: first.of,
          queued_at: Dispatches.now()
        })

      assert {:ok, {:error, :claimed}} = undo(work_item)
      assert run!(second).state == :waiting
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

    test "takes a run whose work item has no target, in the queue's order", ctx do
      scope = with_domain(ctx.scope, "general")
      none = scope |> work_item_fixture(%{target_system: nil, target_path: nil}) |> queue!()
      next = queued!(scope)

      assert {:ok, %{run: %{id: id}, work_item: %WorkItem{target_system: nil}}} =
               Dispatches.claim(ctx.key, Dispatches.now())

      assert id == none.id
      assert {:ok, %{run: %{id: next_id}}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert next_id == next.id
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

    test "ends a waiting run back from a lapsed lease with its stale dispatch, run_ended",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)
      Dispatches.sweep(dispatch.lease_until)
      %Dispatch{slot_freed_at: freed_at} = dispatch!(dispatch)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: ended_state(:closed)
      )

      assert Dispatches.claim(ctx.key, dispatch.lease_until) == {:ok, :none}
      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)

      assert %Dispatch{ended_at: %DateTime{}, end_cause: :run_ended, slot_freed_at: ^freed_at} =
               dispatch!(dispatch)
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
