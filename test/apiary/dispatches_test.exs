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
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Nodes}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.WorkItems.WorkItem

  setup do
    %{scope: scope} = sign_up_fixture()
    gateway = workspace_gateway!(scope)
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{scope: scope, gateway: gateway, pool: pool, key: key}
  end

  defp queue!(work_item, take_in \\ 1) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, take_in) end)
    run
  end

  defp queued!(scope), do: scope |> work_item_fixture() |> queue!()

  defp claimed!(key, now \\ Dispatches.now()) do
    {:ok, %{dispatch: dispatch}} = Apiary.DispatchedRunsFixtures.walked_claim(key, now)
    dispatch
  end

  # A work item's columns as it stands in an ended `state`, with the time it ended.
  defp ended_state(:closed), do: [state: :closed, closed_at: Dispatches.now()]
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

      # With the workflow model, the stage runner counts the runs of a work item it placed
      # by the rounds of the stage's loop; this work item is one it did not place.
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: nil, stage_id: nil, stage_state: nil]
      )

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

    test "while one of the ref waits for the collection and the pool, gives it back; another ref waits beside it",
         ctx do
      collection = collection_fixture(ctx.scope)
      other = pool_fixture(ctx.scope)

      {:ok, first} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      {:ok, again} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert {again.id, again.run_id, again.queued_at} ==
               {first.id, first.run_id, first.queued_at}

      {:ok, beside} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      assert beside.id != first.id
      assert %DispatchRun{state: :waiting, environment_ref: "env-1"} = run!(first)
      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} = run!(beside)

      # Another pool gets a separate one.
      {:ok, theirs} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, other, "env-1") end)

      assert theirs.id != first.id

      # The database holds one waiting per collection, pool and ref.
      assert_raise Postgrex.Error, ~r/dispatch_runs_waiting_prebuild_ref_index/, fn ->
        Repo.update_all(from(r in DispatchRun, where: r.id == ^beside.id),
          set: [environment_ref: "env-1"]
        )
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
               Apiary.DispatchedRunsFixtures.walked_claim(other_key, Dispatches.now())

      assert id == explore.id

      assert Apiary.DispatchedRunsFixtures.walked_claim(other_key, Dispatches.now()) ==
               {:ok, :none}

      assert run!(run).state == :waiting

      # Its pool takes the oldest of the prebuilds held for it and the workspace's other
      # runs.
      later = queued!(ctx.scope)
      run_id = run.id

      assert {:ok, %{run: %{id: ^run_id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      assert {:ok, %{run: %{id: later_id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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
      assert {:ok, %{run: %{id: first}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(other_key, Dispatches.now())

      assert {:ok, %{run: %{id: second}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      assert {:ok, %{run: %{id: third}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      assert [first, second, third] == [explore.id, mine.id, later.id]

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) == {:ok, :none}

      assert Apiary.DispatchedRunsFixtures.walked_claim(other_key, Dispatches.now()) ==
               {:ok, :none}

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

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) == {:ok, :none}
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
      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) == {:ok, :none}
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

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, dispatch.lease_until) ==
               {:ok, :none}
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
        Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, now)

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
      scope = with_domain(ctx.scope, "example")
      none = scope |> work_item_fixture(%{target_system: nil, target_path: nil}) |> queue!()
      next = queued!(scope)

      assert {:ok, %{run: %{id: id}, work_item: %WorkItem{target_system: nil}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      assert id == none.id

      assert {:ok, %{run: %{id: next_id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) == {:ok, :none}
      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)
      assert Repo.aggregate(Dispatch, :count) == 0
    end

    test "ends the waiting runs of work items closed or undone, each with its cause", ctx do
      ended =
        for {state, cause} <- [closed: :closed, undone: :undone] do
          work_item = work_item_fixture(ctx.scope)
          run = queue!(work_item)

          Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
            set: ended_state(state)
          )

          {run, cause}
        end

      next = queued!(ctx.scope)

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, dispatch.lease_until) ==
               {:ok, :none}

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

      assert Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now()) == {:ok, :none}
      assert run!(run).state == :waiting
    end

    test "takes no run of another workspace", ctx do
      other = workspace_fixture(ctx.scope.organisation)
      queued!(workspace_scope(ctx.scope.user, other))
      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) == {:ok, :none}
    end

    test "at the pool's limit takes nothing, and takes again once a slot is freed", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      queued!(ctx.scope)
      second = queued!(ctx.scope)

      dispatch = claimed!(key)
      assert Slots.held(pool.id) == 1
      assert Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now()) == {:ok, :none}
      assert run!(second).state == :waiting

      # A slot is freed only once its dispatch is done.
      {:ok, false} = Repo.transact(fn -> {:ok, Slots.free_slot(dispatch, Dispatches.now())} end)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [ended_at: Dispatches.now(), end_cause: :closed]
      )

      {:ok, true} = Repo.transact(fn -> {:ok, Slots.free_slot(dispatch, Dispatches.now())} end)

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

      assert id == second.id
    end

    test "counts the pool's live runs that were not dispatched against its limit", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      node_run_fixture(pool, "i_direct")
      queued!(ctx.scope)
      assert Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now()) == {:ok, :none}
    end

    test "a key revoked or of an organisation out of use since is unauthorized, and takes nothing",
         ctx do
      run = queued!(ctx.scope)

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) ==
               {:error, :unauthorized}

      Process.put(:out_of_use, [])

      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) ==
               {:error, :unauthorized}

      assert run!(run).state == :waiting
    end

    test "a node's key is unauthorized", ctx do
      node = node_fixture(ctx.scope)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, node)
      queued!(ctx.scope)

      assert Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now()) ==
               {:error, :unauthorized}
    end

    test "dispatch.claim refused or not found is one answer, forbidden", ctx do
      queued!(ctx.scope)

      for stub <- [Apiary.EditionStubs.NoClaim, Apiary.EditionStubs.HidesClaim] do
        :ok = Apiary.Edition.put_test_stub(stub)

        assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) ==
                 {:error, :forbidden},
               inspect(stub)
      end

      assert Repo.aggregate(Dispatch, :count) == 0
    end

    test "a choice of gateway that leads to none is no_gateway, and takes nothing", ctx do
      run = queued!(ctx.scope)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
        set: [gateway_choice: :direct]
      )

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) ==
               {:error, :no_gateway}

      assert run!(run).state == :waiting

      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
        set: [gateway_choice: :named, gateway_id: nil]
      )

      assert Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) ==
               {:error, :no_gateway}

      assert run!(run).state == :waiting
      assert Repo.aggregate(Apiary.RunEventsFixtures.registered_runs(), :count) == 0

      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
        set: [gateway_choice: :default]
      )

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, dispatch.lease_until)

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

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(other_key, dispatch.lease_until)

      assert id == run.id
    end

    test "a claim frees its pool's lapsed slots before it counts", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      first = queued!(ctx.scope)
      dispatch = claimed!(key)

      # No sweep ran: the claim at the lease's end frees the slot and takes the run back.
      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(key, dispatch.lease_until)

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

  describe "the slots of the machines made" do
    @describetag needs: :factory

    # The dispatch handed over at `at`, by its `dispatched`, and its run of the queue.
    defp hand_over!(dispatch, at) do
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^dispatch.dispatch_run_id),
        set: [state: :handed_over]
      )
    end

    defp end!(dispatch) do
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [ended_at: Dispatches.now(), end_cause: :run_ended]
      )
    end

    defp report!(key, dispatch, state),
      do: :ok = Dispatches.report_machine_end(key, dispatch.public_id, %{state: state})

    defp dispatched(key, dispatch),
      do: Dispatches.dispatched(key, dispatch.public_id, %{external: nil})

    # The time the safety net frees the slot of a dispatch of a run that is not a
    # prebuild, whose last sign of a machine was at `at`: 1470 + 60 minutes later.
    defp net(at), do: DateTime.add(at, (1470 + 60) * 60, :second)

    test "a dispatch handed over holds its slot after its end; deleting and delete_failed keep it, gone frees it",
         ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      hand_over!(dispatch, dispatch.claimed_at)
      end!(dispatch)

      assert Dispatches.sweep(Dispatches.now()) == []
      assert %Dispatch{slot_freed_at: nil} = dispatch!(dispatch)

      for state <- [:deleting, :delete_failed, :deleting] do
        report!(ctx.key, dispatch, state)
        Dispatches.sweep(Dispatches.now())
        assert Slots.held(ctx.pool.id) == 1, inspect(state)
      end

      report!(ctx.key, dispatch, :gone)
      assert %Dispatch{slot_freed_at: %DateTime{}, machine_end_state: :gone} = dispatch!(dispatch)
      assert Slots.held(ctx.pool.id) == 0
    end

    test "a dispatch with no machine frees its slot at its end", ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      end!(dispatch)

      assert Dispatches.sweep(Dispatches.now()) == [ctx.scope.workspace.id]
      assert %Dispatch{slot_freed_at: %DateTime{}} = dispatch!(dispatch)
    end

    test "a lapse frees the slot; a late dispatched takes it back, and the pool's claims wait until gone",
         ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      first = queued!(ctx.scope)
      dispatch = claimed!(key)

      Dispatches.sweep(dispatch.lease_until)
      assert Slots.held(pool.id) == 0
      assert run!(first).state == :waiting

      assert dispatched(key, dispatch) == {:error, :lease_expired}
      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: nil} = dispatch!(dispatch)
      assert Slots.held(pool.id) == 1

      # Past the pool's limit: the run waits, and the next claim takes nothing.
      assert Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now()) == {:ok, :none}
      assert run!(first).state == :waiting

      report!(key, dispatch, :deleting)
      Dispatches.sweep(Dispatches.now())
      assert Slots.held(pool.id) == 1

      report!(key, dispatch, :gone)
      assert Slots.held(pool.id) == 0

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

      assert id == first.id
    end

    test "a report after a lapse takes the slot back; a gone first leaves it freed", ctx do
      queued!(ctx.scope)
      reported = claimed!(ctx.key)
      queued!(ctx.scope)
      gone_first = claimed!(ctx.key)

      Dispatches.sweep(gone_first.lease_until)
      assert Slots.held(ctx.pool.id) == 0

      report!(ctx.key, reported, :delete_failed)
      assert %Dispatch{slot_freed_at: nil} = dispatch!(reported)

      report!(ctx.key, gone_first, :gone)
      %Dispatch{slot_freed_at: freed_at} = dispatch!(gone_first)
      assert %DateTime{} = freed_at

      assert dispatched(ctx.key, gone_first) == {:error, :lease_expired}
      report!(ctx.key, gone_first, :deleting)

      assert %Dispatch{machine_end_state: :gone, slot_freed_at: ^freed_at} =
               dispatch!(gone_first)

      assert Slots.held(ctx.pool.id) == 1
    end

    test "a lapse keeps the slot of a machine already reported, and its run waits again", ctx do
      run = queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      report!(ctx.key, dispatch, :deleting)

      Dispatches.sweep(dispatch.lease_until)

      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: nil} = dispatch!(dispatch)
      assert run!(run).state == :waiting
      assert Slots.held(ctx.pool.id) == 1
    end

    test "a pool with no limit claims whatever slots its machines hold", ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      hand_over!(dispatch, dispatch.claimed_at)
      end!(dispatch)
      Dispatches.sweep(Dispatches.now())
      assert Slots.held(ctx.pool.id) == 1

      next = queued!(ctx.scope)

      assert {:ok, %{run: %{id: id}}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      assert id == next.id
      assert Slots.held(ctx.pool.id) == 2
    end

    test "the safety net frees the slot at the machine's lifetime and 60 minutes, not before; a late gone frees nothing more",
         ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      at = DateTime.add(dispatch.claimed_at, 1, :second)
      hand_over!(dispatch, at)
      end!(dispatch)

      Dispatches.sweep(DateTime.add(net(at), -1, :microsecond))
      assert %Dispatch{slot_freed_at: nil} = dispatch!(dispatch)

      assert Dispatches.sweep(net(at)) == [ctx.scope.workspace.id]
      assert %Dispatch{slot_freed_at: freed_at} = dispatch!(dispatch)
      assert freed_at == net(at)

      report!(ctx.key, dispatch, :gone)

      assert %Dispatch{machine_end_state: :gone, slot_freed_at: ^freed_at} =
               dispatch!(dispatch)
    end

    test "the safety net frees a dispatch handed over by its run code's redemption alone",
         ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      at = DateTime.add(dispatch.claimed_at, 2, :second)

      # No dispatched and no report: the redemption alone handed it over.
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [handed_over_at: at]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^dispatch.dispatch_run_id),
        set: [state: :handed_over]
      )

      end!(dispatch)
      Dispatches.sweep(Dispatches.now())

      assert %Dispatch{dispatched_at: nil, machine_end_state: nil, slot_freed_at: nil} =
               dispatch!(dispatch)

      Dispatches.sweep(DateTime.add(net(at), -1, :microsecond))
      assert Slots.held(ctx.pool.id) == 1

      Dispatches.sweep(net(at))
      assert dispatch!(dispatch).slot_freed_at == net(at)
      assert Slots.held(ctx.pool.id) == 0
    end

    test "the safety net counts from the last report; a deleting after it takes the slot back",
         ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      hand_over!(dispatch, dispatch.claimed_at)
      end!(dispatch)

      Dispatches.sweep(net(dispatch.claimed_at))
      assert Slots.held(ctx.pool.id) == 0

      report!(ctx.key, dispatch, :deleting)
      assert %Dispatch{slot_freed_at: nil, machine_end_at: reported_at} = dispatch!(dispatch)
      assert DateTime.compare(reported_at, dispatch.claimed_at) == :gt

      # The net counts from the report now, not from the dispatched.
      Dispatches.sweep(net(dispatch.claimed_at))
      Dispatches.sweep(DateTime.add(net(reported_at), -1, :microsecond))
      assert Slots.held(ctx.pool.id) == 1

      Dispatches.sweep(net(reported_at))
      assert Slots.held(ctx.pool.id) == 0
    end

    test "the safety net frees a stale dispatch held again, counted from its late machine",
         ctx do
      queued!(ctx.scope)
      dispatch = claimed!(ctx.key)
      Dispatches.sweep(dispatch.lease_until)

      assert dispatched(ctx.key, dispatch) == {:error, :lease_expired}
      assert %Dispatch{late_machine_at: late, slot_freed_at: nil} = dispatch!(dispatch)
      assert DateTime.compare(late, dispatch.claimed_at) == :gt

      Dispatches.sweep(net(dispatch.claimed_at))
      Dispatches.sweep(DateTime.add(net(late), -1, :microsecond))
      assert Slots.held(ctx.pool.id) == 1

      Dispatches.sweep(net(late))
      assert dispatch!(dispatch).slot_freed_at == net(late)
      assert Slots.held(ctx.pool.id) == 0
    end
  end

  describe "the sweep and a deleted pool's prebuilds" do
    @describetag needs: :factory

    setup ctx do
      %{collection: collection_fixture(ctx.scope), deleted: pool_fixture(ctx.scope)}
    end

    defp queue_prebuild!(collection, pool) do
      {:ok, run} = Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-1") end)
      run
    end

    # A waiting run of a fresh work item in Explore with the collection's target.
    defp held!(ctx) do
      ctx.scope
      |> work_item_fixture(%{
        target_system: ctx.collection.target_system,
        target_path: ctx.collection.target_path
      })
      |> queue!()
    end

    defp record!(collection, pool),
      do: Repo.get_by!(Record, source_collection_id: collection.id, pool_id: pool.id)

    test "ends its waiting prebuild lost, records the build failed, lost, and ends the held runs build_failed",
         ctx do
      prebuild = queue_prebuild!(ctx.collection, ctx.deleted)
      mine = queue_prebuild!(ctx.collection, ctx.pool)
      held = held!(ctx)
      unheld = queued!(ctx.scope)
      {:ok, _deleted} = Nodes.delete_node(ctx.scope, ctx.deleted)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert ctx.scope.workspace.id in Dispatches.sweep(Dispatches.now())

      assert %DispatchRun{state: :ended, end_cause: :lost} = run!(prebuild)

      assert %Record{failure_cause: :lost, failure_reason: nil, failed_at: %DateTime{}} =
               record!(ctx.collection, ctx.deleted)

      assert %DispatchRun{state: :ended, end_cause: :build_failed, result_outcome: :error} =
               run!(held)

      # The live pool's prebuild and a run of another target wait.
      assert run!(mine).state == :waiting
      assert run!(unheld).state == :waiting
      assert_received {Dispatches, :changed}

      # A second sweep ends nothing more.
      assert Dispatches.sweep(Dispatches.now()) == []
    end

    @tag needs: [:factory, :workflow_model]
    test "with the workflow model, a held run's end escalates its stage run_stopped", ctx do
      queue_prebuild!(ctx.collection, ctx.deleted)
      held = held!(ctx)
      {:ok, _deleted} = Nodes.delete_node(ctx.scope, ctx.deleted)

      assert {:work_item, ctx.scope.workspace.id,
              Repo.get!(WorkItem, held.work_item_id).public_id} in Dispatches.sweep(
               Dispatches.now()
             )

      assert %WorkItem{stage_state: :escalated} = Repo.get!(WorkItem, held.work_item_id)

      target = Repo.get!(WorkItem, held.work_item_id).target_path

      assert %Apiary.Stages.Escalation{cause: :run_stopped, gaps: gaps} =
               Repo.get_by!(Apiary.Stages.Escalation, work_item_id: held.work_item_id)

      assert gaps ==
               "The run did not start, because the build of the environment for target #{target} failed.\n" <>
                 "Read why on the page of target #{target}, under Targets, then choose Rebuild there."
    end

    # The stage runner cannot read the held run's questions: the run still ends with the
    # build's failure, and the stage sweep of the lost-run check moves the stage once they
    # can be read.
    @tag needs: [:factory, :workflow_model]
    test "with the workflow model, a held run with unreadable questions still ends", ctx do
      queue_prebuild!(ctx.collection, ctx.deleted)
      held = held!(ctx)
      work_item = Repo.get!(WorkItem, held.work_item_id)
      asked_run = Apiary.StagesFixtures.asked_before!(held)
      path = Apiary.StagesFixtures.unreadable_questions!(ctx.scope, work_item, asked_run)
      {:ok, _deleted} = Nodes.delete_node(ctx.scope, ctx.deleted)

      {_changed, log} = ExUnit.CaptureLog.with_log(fn -> Dispatches.sweep(Dispatches.now()) end)

      assert log =~
               "stage end left for later, newest questions unreadable dispatch_run=#{held.id}"

      assert %DispatchRun{state: :ended, end_cause: :build_failed} = run!(held)
      assert %WorkItem{stage_state: :running} = Repo.get!(WorkItem, held.work_item_id)

      File.rename!(path <> ".away", path)
      assert {[_], nil} = Apiary.Stages.sweep(Dispatches.now(), nil)
      assert %WorkItem{stage_state: :waiting_answers} = Repo.get!(WorkItem, held.work_item_id)
    end

    test "ends no held run while a live pool has the image for the target", ctx do
      prebuild = queue_prebuild!(ctx.collection, ctx.deleted)
      held = held!(ctx)

      Repo.insert!(%Record{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        pool_id: ctx.pool.id,
        source_collection_id: ctx.collection.id,
        image: "registry.example.com/acme/env@sha256:" <> String.duplicate("3b9d", 16),
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1",
        built_ref: "env-1",
        built_target_system: ctx.collection.target_system,
        built_target_path: ctx.collection.target_path
      })

      {:ok, _deleted} = Nodes.delete_node(ctx.scope, ctx.deleted)
      Dispatches.sweep(Dispatches.now())

      assert %DispatchRun{state: :ended, end_cause: :lost} = run!(prebuild)
      assert %Record{failure_cause: :lost} = record!(ctx.collection, ctx.deleted)
      assert run!(held).state == :waiting
    end

    test "ends a prebuild claimed before the deletion once its lease lapses, with its dispatch",
         ctx do
      %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.deleted)
      prebuild = queue_prebuild!(ctx.collection, ctx.deleted)

      assert {:ok, %{run: %{id: id}, dispatch: dispatch}} =
               Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

      assert id == prebuild.id
      {:ok, _deleted} = Nodes.delete_node(ctx.scope, ctx.deleted)

      # Before its lease lapses, the claimed prebuild is left as it is.
      Dispatches.sweep(DateTime.add(dispatch.lease_until, -1, :second))
      assert run!(prebuild).state == :claimed

      Dispatches.sweep(dispatch.lease_until)

      assert %DispatchRun{state: :ended, end_cause: :lost} = run!(prebuild)

      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: %DateTime{}} =
               ended = dispatch!(dispatch)

      assert {ended.end_cause, ended.ended_at} == {:run_ended, dispatch.lease_until}
      assert Slots.held(ctx.deleted.id) == 0
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

    test "a registration counts the slot of a dispatch that ended while its machine is not gone",
         ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      queued!(ctx.scope)
      dispatch = claimed!(key)
      at = dispatch.claimed_at

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at, ended_at: at, end_cause: :run_ended]
      )

      check = fn ->
        Repo.transact(fn -> {:ok, Nodes.check_instance_limit(pool, "i_1", Dispatches.now())} end)
      end

      Dispatches.sweep(Dispatches.now())
      assert check.() == {:ok, {:error, :instance_limit}}

      :ok = Dispatches.report_machine_end(key, dispatch.public_id, %{state: :gone})
      assert check.() == {:ok, :ok}
    end

    test "a dispatched run counts by its slot, not again by its instance", ctx do
      pool = pool_fixture(ctx.scope, instance_limit: 2)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      queued!(ctx.scope)
      claimed!(key)

      # The run its claim registered, alive on the pool.
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
