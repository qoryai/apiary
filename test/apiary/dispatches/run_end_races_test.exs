defmodule Apiary.Dispatches.RunEndRacesTest do
  # The ends of a run a workspace's queue handed over racing each other
  # (`Apiary.Dispatches.RunEnd`), each on a separate connection, outside the SQL sandbox,
  # so each commits and each waits on the other's locks as it would in production. Not
  # async: what these tests commit is visible to every other test while they run, and they
  # delete it again before they end; the adapters, which outlive an organisation, by what
  # they made.
  #
  # The rules under test: an end of a run that is not a prebuild holds its work item
  # `FOR KEY SHARE` first, as a release holds it `FOR UPDATE` first; then every end locks
  # the run of the queue, then the registered run, then writes the dispatches. So the ends
  # these tests start together take turns: the backstop with an exit's projection; the
  # lost-run check with the liveness check and two releases; two releases with an exit's
  # projection, whose end writes the run of the queue twice; and all of them at once. The
  # first decides the end cause, the slot is freed once, by the first end, and none of
  # them deadlocks: the tests of a release and an exit's end also assert that no
  # statement on any connection fails with `deadlock_detected` (40P01). A release after
  # the handover is refused `machine_exists`, or `gone` once the run ended, and ends
  # nothing. For a prebuild handed over, the lost-run check holds its target's collections
  # `FOR SHARE`, then the work items whose runs wait for its build `FOR KEY SHARE`, then
  # its environment record, before the run of the queue, as a release holds the record:
  # so the check takes turns with a release at the record, and with a claim, which never
  # takes a run held for the build; the record keeps the end that decided, and none of
  # them deadlocks. What a run gave is stored by its end or by a settle
  # (`Apiary.Dispatches.Settle`), which locks the run of the queue alone: it takes turns
  # with a projection and the lost-run check there, and what is stored is the same
  # whichever comes first.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.RunEventsFixtures, only: [event_fixture: 4]
  import Apiary.WorkItemsFixtures, only: [result_event!: 3, understood_result: 0]

  alias Apiary.{Dispatches, Edition, Environments, Repo, Targets}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunEnd, Settle, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Liveness, Projector, Run, Target}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @reason "The job could not start."
  @missing_exit %{"state" => "failed", "reason" => "image_missing", "exit_code" => -1}
  # The target of a work item of `work_item_fixture/2`.
  @missing_target %{system: "forge.example.com", path: "acme/shop"}

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    {:ok, made} = Agent.start(fn -> %{public_keys: [], adapters: []} end)

    # Before the clean up of `setup_races`: the organisation, then what outlives it.
    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      %{public_keys: public_keys, adapters: adapters} = Agent.get(made, & &1)
      Agent.stop(made)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      Repo.delete_all(from n in Node, where: n.id in ^adapters)
      Repo.delete_all(from p in PublicKey, where: p.public_key in ^public_keys)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    pool = pool_fixture(scope)
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, pool)
    Agent.update(made, &%{&1 | public_keys: [pair.public_key | &1.public_keys]})
    %{scope: scope, made: made, pool: pool, key: key}
  end

  # A run handed over, with its registered run, committed.
  defp handed_over!(ctx) do
    handed = handed_over_fixture(ctx.scope, ctx.key)

    adapter_id =
      Repo.one!(
        from w in WorkItem, where: w.id == ^handed.dispatch_run.work_item_id, select: w.adapter_id
      )

    Agent.update(ctx.made, &%{&1 | adapters: [adapter_id | &1.adapters]})
    handed
  end

  # The moment after its backstop.
  defp past_backstop(%{run: run}), do: DateTime.add(run.backstop_at, 1, :second)

  defp release(ctx, %{dispatch: dispatch}),
    do: Dispatches.release(ctx.key, dispatch.public_id, %{reason: @reason})

  # The run of the queue, its dispatch and its registered run as the ends left them, held
  # to one end: the cause on both, the dispatch's slot freed by that end, at its end.
  defp ended!(ctx, handed) do
    dispatch_run = Repo.get!(DispatchRun, handed.dispatch_run.id)
    dispatch = Repo.get!(Dispatch, handed.dispatch.id)

    assert dispatch_run.state == :ended
    assert dispatch.end_cause == dispatch_run.end_cause
    assert %DateTime{} = dispatch.ended_at
    assert dispatch.slot_freed_at == dispatch.ended_at
    assert Slots.held(ctx.pool.id) == 0

    {dispatch_run.end_cause, Repo.get!(Run, handed.run.id)}
  end

  describe "the backstop and an exit" do
    test "at once: one end decides, the slot is freed once", ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)
        at = past_backstop(handed)
        event_fixture(handed.run, 9, "run.exited", %{"state" => "failed", "exit_code" => 1})

        [_lost, projected] =
          together([
            fn -> Liveness.check(at) end,
            fn -> Projector.project(handed.run) end
          ])

        assert {:ok, %Run{}} = projected
        {cause, _run} = ended!(ctx, handed)
        assert cause in [:lost, :run_ended]
      end
    end
  end

  # Each statement that fails with a deadlock (40P01), on any connection, sent to the
  # test as `{:deadlock, query}`.
  defp attach_deadlocks(_context) do
    handler = "run-end-races-deadlocks-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn
        _event, _measurements, %{result: {:error, %Postgrex.Error{postgres: pg}}} = meta, _
        when pg.code == :deadlock_detected ->
          send(test, {:deadlock, meta.query})

        _event, _measurements, _meta, _config ->
          :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "a release and an exit's end" do
    setup :attach_deadlocks

    defp exited!(handed),
      do: event_fixture(handed.run, 9, "run.exited", %{"state" => "failed", "exit_code" => 1})

    # The run of the queue ended once, `run_ended`, by the exit, and no release acted or
    # failed: each is `machine_exists`, or `gone` once the run ended.
    defp ended_by_exit!(ctx, handed, releases) do
      assert Enum.all?(releases, &(&1 in [{:error, :machine_exists}, {:error, :gone}]))
      assert {:run_ended, %Run{}} = ended!(ctx, handed)
      refute_received {:deadlock, _query}
    end

    test "the work item held as a release holds it: the exit's end waits there, before the run of the queue",
         ctx do
      handed = handed_over!(ctx)
      exited!(handed)
      work_item_id = handed.dispatch_run.work_item_id

      {first, first_pid} =
        hold(fn ->
          Repo.one!(from w in WorkItem, where: w.id == ^work_item_id, lock: "FOR UPDATE")
        end)

      second = start(fn -> Projector.project(handed.run) end)
      await_blocked(second.backend, first_pid)

      # Waiting on the work item, the end holds nothing of the run of the queue yet.
      assert %DispatchRun{state: :handed_over} =
               continue(first, fn ->
                 Repo.one(
                   from d in DispatchRun,
                     where: d.id == ^handed.dispatch_run.id,
                     lock: "FOR UPDATE NOWAIT"
                 )
               end)

      commit(first)

      assert {:ok, %Run{}} = Task.await(second.task)
      ended_by_exit!(ctx, handed, [])
    end

    test "two releases and the exit's projection at once: one end, none deadlocks", ctx do
      for _round <- 1..8 do
        handed = handed_over!(ctx)
        exited!(handed)

        sides = [
          fn -> {:projection, Projector.project(handed.run)} end,
          fn -> {:release, release(ctx, handed)} end,
          fn -> {:release, release(ctx, handed)} end
        ]

        answers = together(Enum.take(sides, sides(length(sides))))

        assert {:projection, {:ok, %Run{}}} = List.keyfind(answers, :projection, 0)
        ended_by_exit!(ctx, handed, for({:release, answer} <- answers, do: answer))
      end
    end

    test "every end at once, with the exit's projection: one end, none deadlocks", ctx do
      for _round <- 1..8 do
        handed = handed_over!(ctx)
        exited!(handed)
        at = past_backstop(handed)

        # The projection first, so a pool too small for every side still runs it.
        sides = [
          fn -> {:projection, Projector.project(handed.run)} end,
          fn -> {:check, Liveness.check(at)} end,
          fn -> {:lose, RunEnd.lose(at)} end,
          fn -> {:release, release(ctx, handed)} end,
          fn -> {:release, release(ctx, handed)} end
        ]

        answers = together(Enum.take(sides, sides(length(sides))))
        assert {:projection, {:ok, %Run{}}} = List.keyfind(answers, :projection, 0)
        ended_by_exit!(ctx, handed, for({:release, answer} <- answers, do: answer))
      end
    end
  end

  describe "a prebuild lost after its handover" do
    # A pool with a gateway, whose keys' public halves, and the adapters and entries its
    # collections leave, are deleted as the release's races delete them: the organisation
    # first, then what outlives it.
    setup ctx do
      started = database_now()
      place = handover_place_fixture(ctx.scope)
      {gateway_key, _seed} = place.gateway_key
      {:ok, made} = Agent.start(fn -> [] end)

      on_exit(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        adapters = Agent.get(made, & &1)
        Agent.stop(made)
        Repo.delete_all(from o in Organisation, where: o.id == ^ctx.scope.organisation.id)

        adapter_keys =
          Repo.all(from k in AccessKey, where: k.node_id in ^adapters, select: k.key_id)

        Repo.delete_all(
          from p in PublicKey,
            where: p.key_id in ^[place.key.key_id, gateway_key.key_id | adapter_keys]
        )

        Repo.delete_all(from c in Connection, where: c.adapter_id in ^adapters)
        Repo.delete_all(from k in AccessKey, where: k.node_id in ^adapters)
        Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^adapters)
        Repo.delete_all(from n in Node, where: n.id in ^adapters)

        Repo.delete_all(
          from e in Entry,
            where: e.organisation_id == ^Edition.instance_organisation_id(),
            where: e.inserted_at >= ^started
        )

        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end)

      %{place: place, collections_made: made}
    end

    # A collection, the pool's environment record of it, `env-1` queued and a good build
    # kept, and a prebuild of it claimed, said started and handed over, its gateway not
    # yet attached: committed.
    defp prebuild_handed_over!(ctx) do
      collection = collection_fixture(ctx.scope)
      Agent.update(ctx.collections_made, &[collection.adapter_id | &1])

      record =
        Repo.insert!(%Record{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          pool_id: ctx.place.pool.id,
          source_collection_id: collection.id,
          image: @image,
          size: 734_003_200,
          commit: "9c1e4a7b",
          built_at: DateTime.utc_now(),
          reported_ref: "env-1",
          built_ref: "env-1"
        })

      {:ok, queued} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.place.pool, "env-1") end)

      %{dispatch: dispatch, registered: run} = dispatched!(ctx.place.key)
      assert dispatch.dispatch_run_id == queued.id

      %{
        collection: collection,
        record: record,
        dispatch_run: queued,
        dispatch: dispatch,
        run: run
      }
    end

    # The lost-run check past the prebuild's attach_by.
    defp lose_prebuild(handed),
      do: fn -> RunEnd.lose(DateTime.add(handed.run.attach_by, 1, :second)) end

    defp release_prebuild(ctx, handed) do
      fn ->
        Dispatches.release(ctx.place.key, handed.dispatch.public_id, %{
          reason: @reason
        })
      end
    end

    # A waiting run of a fresh work item in Explore whose target is the prebuild's
    # collection's: held for the pool's build of it.
    defp held!(ctx, handed) do
      work_item =
        Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope, %{
          target_system: handed.collection.target_system,
          target_path: handed.collection.target_path
        })

      Agent.update(ctx.made, &%{&1 | adapters: [work_item.adapter_id | &1.adapters]})
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      run
    end

    # The prebuilds of the collection that wait end, so the next round's claim takes the
    # prebuild that round queues.
    defp end_waiting!(handed) do
      {_count, _rows} =
        Repo.update_all(
          from(r in DispatchRun,
            where: r.source_collection_id == ^handed.collection.id,
            where: fragment("? = 'waiting'", r.state)
          ),
          set: [state: :ended, end_cause: :collection_ended]
        )
    end

    defp end_cause(handed), do: Repo.get!(DispatchRun, handed.dispatch_run.id).end_cause

    # The record as the end left it, its last good build kept.
    defp record_kept!(handed) do
      record = Repo.get!(Record, handed.record.id)
      kept = [:image, :size, :commit, :built_at, :reported_ref]
      assert Map.take(record, kept) == Map.take(handed.record, kept)
      record
    end

    # The runs of the queue of the prebuild's collection for its pool, oldest first: the
    # end of a first loss of the collection's ref queues one more.
    defp runs_of(handed) do
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id == ^handed.collection.id,
          where: r.pool_id == ^handed.dispatch_run.pool_id,
          order_by: [r.inserted_at, r.id]
      )
    end

    test "and a release at once: the check decides, the release ends nothing, none deadlocks",
         ctx do
      for _round <- 1..4 do
        handed = prebuild_handed_over!(ctx)

        [lost, released] =
          together([lose_prebuild(handed), release_prebuild(ctx, handed)])

        assert lost != []
        assert released in [{:error, :machine_exists}, {:error, :gone}]
        assert end_cause(handed) == :lost

        assert %Record{failure_cause: :lost, failure_reason: nil, lost_ref: "env-1"} =
                 record_kept!(handed)

        assert [
                 %DispatchRun{state: :ended},
                 %DispatchRun{state: :waiting, environment_ref: "env-1"}
               ] =
                 runs_of(handed)

        assert Slots.held(ctx.place.pool.id) == 0
        end_waiting!(handed)
      end
    end

    test "the check first: the release waits on the record, then is gone", ctx do
      handed = prebuild_handed_over!(ctx)

      {first, first_pid} = hold(lose_prebuild(handed))
      assert first.result != []

      second = start(release_prebuild(ctx, handed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      assert end_cause(handed) == :lost
      assert %Record{failure_cause: :lost, failure_reason: nil} = record_kept!(handed)
      assert [%DispatchRun{state: :ended}, %DispatchRun{state: :waiting}] = runs_of(handed)
    end

    test "the release first: the check waits on the record, then loses the run", ctx do
      handed = prebuild_handed_over!(ctx)

      {first, first_pid} = hold(release_prebuild(ctx, handed))
      assert first.result == {:error, :machine_exists}

      second = start(lose_prebuild(handed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) != []
      assert end_cause(handed) == :lost
      assert %Record{failure_cause: :lost, failure_reason: nil} = record_kept!(handed)
    end

    test "the check holds the record before the run of the queue", ctx do
      handed = prebuild_handed_over!(ctx)

      {first, first_pid} =
        hold(fn -> Environments.lock_record(ctx.place.pool.id, handed.collection.id) end)

      second = start(lose_prebuild(handed))
      await_blocked(second.backend, first_pid)

      # Waiting on the record, the check holds nothing of the run of the queue yet.
      assert %DispatchRun{state: :handed_over} =
               continue(first, fn ->
                 Repo.one(
                   from d in DispatchRun,
                     where: d.id == ^handed.dispatch_run.id,
                     lock: "FOR UPDATE NOWAIT"
                 )
               end)

      commit(first)

      assert Task.await(second.task) != []
      assert end_cause(handed) == :lost
      assert %Record{failure_cause: :lost} = record_kept!(handed)
    end

    test "a second loss and a claim at once: the held runs end build_failed once, and the claim takes none",
         ctx do
      for _round <- 1..4 do
        handed = prebuild_handed_over!(ctx)

        {1, _rows} =
          Repo.update_all(from(r in Record, where: r.id == ^handed.record.id),
            set: [lost_ref: "env-1"]
          )

        held = for _ <- 1..2, do: held!(ctx, handed)

        sides = [
          fn -> {:lost, lose_prebuild(handed).()} end,
          fn -> {:claim, Dispatches.claim(ctx.place.key, Dispatches.now())} end
        ]

        answers = together(Enum.take(sides, sides(length(sides))))
        assert {:lost, [_ | _]} = List.keyfind(answers, :lost, 0)
        assert {:claim, {:ok, :none}} = List.keyfind(answers, :claim, 0)

        assert end_cause(handed) == :lost
        assert %Record{failure_cause: :lost, lost_ref: nil} = record_kept!(handed)
        assert [%DispatchRun{state: :ended}] = runs_of(handed)

        for run <- held do
          assert %DispatchRun{state: :ended, end_cause: :build_failed, result_outcome: :error} =
                   Repo.get!(DispatchRun, run.id)

          assert Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^run.id) == []
        end

        refute_received {:deadlock, _query}
      end
    end

    test "the check of a second loss holds the work items of the held runs before the record",
         ctx do
      handed = prebuild_handed_over!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.id == ^handed.record.id),
          set: [lost_ref: "env-1"]
        )

      run = held!(ctx, handed)

      # A close holds the work item `FOR UPDATE`: the check waits there, before the record.
      {first, first_pid} =
        hold(fn ->
          Repo.one!(from w in WorkItem, where: w.id == ^run.work_item_id, lock: "FOR UPDATE")
        end)

      second = start(lose_prebuild(handed))
      await_blocked(second.backend, first_pid)

      assert %Record{} =
               continue(first, fn ->
                 Repo.one(
                   from r in Record, where: r.id == ^handed.record.id, lock: "FOR UPDATE NOWAIT"
                 )
               end)

      commit(first)

      assert Task.await(second.task) != []
      assert %DispatchRun{end_cause: :build_failed} = Repo.get!(DispatchRun, run.id)
    end
  end

  describe "what a run gave, settled as it ends" do
    # The settle locks the run of the queue first and nothing after it, so it takes turns
    # with an end there: the end stores what the run gave when it is decided, a settle
    # after it finds it stored and writes nothing, and none deadlocks.
    defp stored(handed) do
      %DispatchRun{result_outcome: outcome, result: result} =
        Repo.get!(DispatchRun, handed.dispatch_run.id)

      {outcome, result}
    end

    defp result!(handed, sequence) do
      result_event!(handed.run, sequence, %{
        "is_error" => false,
        "result" => Jason.encode!(understood_result())
      })
    end

    test "a projection of the result and the exit, and a settle at once: one end, stored",
         ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)
        result!(handed, 8)

        event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

        [projected, _settled] =
          together([
            fn -> Projector.project(handed.run) end,
            fn -> Settle.settle(handed.dispatch_run.id) end
          ])

        assert {:ok, %Run{}} = projected
        assert {:run_ended, _run} = ended!(ctx, handed)
        assert {:proposal, %{"verdict" => "understood"}} = stored(handed)
      end
    end

    test "the lost-run check ending a run whose exit came, a settle and a sweep at once",
         ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)

        # The projection folded the exit and stopped before its end.
        Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
          set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
        )

        now = Dispatches.now()

        together([
          fn -> RunEnd.lose(now) end,
          fn -> Settle.settle(handed.dispatch_run.id) end,
          fn -> Settle.sweep(now) end
        ])

        assert {:run_ended, _run} = ended!(ctx, handed)
        assert stored(handed) == {:none, nil}
      end
    end
  end

  describe "the end of a run whose image was missing" do
    # The end holds the connections and the collections of the records of the image
    # `FOR SHARE`, then the work item `FOR UPDATE`, then the records `FOR UPDATE`, before
    # the run of the queue; it clears the image, queues a prebuild of each collection,
    # unless one of its ref waits, and queues the next run of the take in with one more
    # attempt. A listing's part, which holds its connection and its collections
    # `FOR UPDATE`, a Rebuild, which holds the same rows as the end in the same order, a
    # release and a close, which hold the work item `FOR UPDATE`, and a second end of the
    # run take turns with it: none deadlocks, the run of the queue ends once, `run_ended`,
    # the image is cleared, one prebuild waits for the pool, and one run of the work item
    # waits, unless the work item was closed.
    setup :attach_deadlocks

    setup ctx do
      started = database_now()
      {:ok, made} = Agent.start(fn -> [] end)

      on_exit(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        adapters = Agent.get(made, & &1)
        Agent.stop(made)
        Repo.delete_all(from o in Organisation, where: o.id == ^ctx.scope.organisation.id)

        adapter_keys =
          Repo.all(from k in AccessKey, where: k.node_id in ^adapters, select: k.key_id)

        Repo.delete_all(from p in PublicKey, where: p.key_id in ^adapter_keys)
        Repo.delete_all(from c in Connection, where: c.adapter_id in ^adapters)
        Repo.delete_all(from k in AccessKey, where: k.node_id in ^adapters)
        Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^adapters)
        Repo.delete_all(from n in Node, where: n.id in ^adapters)

        Repo.delete_all(
          from e in Entry,
            where: e.organisation_id == ^Edition.instance_organisation_id(),
            where: e.inserted_at >= ^started
        )

        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end)

      :ok =
        Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [@missing_target])

      %{
        collections_made: made,
        target: Targets.get(ctx.scope, @missing_target.system, @missing_target.path)
      }
    end

    # A collection of the work items' target with `env-1`, the pool's record of it with a
    # build of `@image` for that target, and a run of a work item handed over that started
    # in `@image`: committed.
    defp missing_handed_over!(ctx) do
      collection =
        collection_fixture(ctx.scope,
          target_system: @missing_target.system,
          target_path: @missing_target.path,
          environment_ref: "env-1"
        )

      Agent.update(ctx.collections_made, &[collection.adapter_id | &1])
      now = DateTime.utc_now()

      record =
        Repo.insert!(%Record{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          pool_id: ctx.pool.id,
          source_collection_id: collection.id,
          image: @image,
          size: 734_003_200,
          commit: "9c1e4a7b",
          built_at: now,
          reported_ref: "env-1",
          built_ref: "env-1",
          built_target_system: @missing_target.system,
          built_target_path: @missing_target.path,
          built_queued_at: now
        })

      handed =
        handed_over_fixture(ctx.scope, ctx.key, %{
          configured_image: @image,
          registration_labels: %{"forge" => "forge.example.com", "repository" => "acme/shop"}
        })

      adapter_id =
        Repo.one!(
          from w in WorkItem,
            where: w.id == ^handed.dispatch_run.work_item_id,
            select: w.adapter_id
        )

      Agent.update(ctx.made, &%{&1 | adapters: [adapter_id | &1.adapters]})
      Map.merge(handed, %{collection: collection, record: record})
    end

    defp missing_exit!(handed),
      do: event_fixture(handed.run, 9, "run.exited", @missing_exit)

    # The exit folded, as a projection that stopped before the end of the run of the
    # queue leaves it.
    defp missing_folded!(handed) do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
          set: [
            state: "failed",
            exit_state: "failed",
            exit_reason: "image_missing",
            exited_at: DateTime.utc_now()
          ]
        )
    end

    # A listing's part that changes the collection's `environment_ref`: its connection and
    # its collection `FOR UPDATE`, then the change.
    defp part(%{collection: %Collection{id: id, connection_id: connection_id}}, ref) do
      fn ->
        Repo.transact(fn ->
          Repo.one!(from k in Connection, where: k.id == ^connection_id, lock: "FOR UPDATE")
          Repo.one!(from c in Collection, where: c.id == ^id, lock: "FOR UPDATE")

          {1, _rows} =
            Repo.update_all(from(c in Collection, where: c.id == ^id),
              set: [environment_ref: ref]
            )

          {:ok, :changed}
        end)
      end
    end

    # The `environment_ref` of each prebuild of the collection that waits for the pool.
    defp waiting_prebuilds(ctx, handed) do
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id == ^handed.collection.id,
          where: r.pool_id == ^ctx.pool.id and r.state == :waiting,
          select: r.environment_ref
      )
    end

    # The run of the queue ended once, `run_ended`, the image cleared, one prebuild
    # waiting for one of `refs`, the next run of the work item waiting, attempt 2 of 4,
    # unless `requeued` is false, and no deadlock on any connection. The collection then
    # has no `environment_ref`, and what waits of it and of the work item ends, so the
    # next round's claim takes its explore run and its Rebuild queues nothing for this
    # collection.
    defp missing_ended!(ctx, handed, refs, requeued \\ true) do
      assert {:run_ended, %Run{}} = ended!(ctx, handed)
      assert %Record{image: nil, built_queued_at: nil} = Repo.get!(Record, handed.record.id)
      assert [ref] = waiting_prebuilds(ctx, handed)
      assert ref in List.wrap(refs)
      refute_received {:deadlock, _query}

      waiting =
        Repo.all(
          from r in DispatchRun,
            where: r.work_item_id == ^handed.dispatch_run.work_item_id,
            where: fragment("? = 'waiting'", r.state)
        )

      if requeued,
        do: assert([%DispatchRun{attempt: 2, of: 4, image_requeue: true}] = waiting),
        else: assert(waiting == [])

      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^handed.collection.id),
          set: [environment_ref: nil]
        )

      {_count, _rows} =
        Repo.update_all(
          from(r in DispatchRun,
            where:
              r.source_collection_id == ^handed.collection.id or
                r.work_item_id == ^handed.dispatch_run.work_item_id,
            where: fragment("? = 'waiting'", r.state)
          ),
          set: [state: :ended, end_cause: :collection_ended]
        )
    end

    test "a part holds the collection: the end waits there, before the work item and the records",
         ctx do
      handed = missing_handed_over!(ctx)
      missing_exit!(handed)
      %{id: id, connection_id: connection_id} = handed.collection

      {first, first_pid} =
        hold(fn ->
          Repo.one!(from k in Connection, where: k.id == ^connection_id, lock: "FOR UPDATE")
          Repo.one!(from c in Collection, where: c.id == ^id, lock: "FOR UPDATE")
        end)

      second = start(fn -> Projector.project(handed.run) end)
      await_blocked(second.backend, first_pid)

      # Waiting on the connection, the end holds neither the work item nor the record:
      # the part locks both without waiting, then changes the collection's ref.
      continue(first, fn ->
        Repo.one!(
          from w in WorkItem,
            where: w.id == ^handed.dispatch_run.work_item_id,
            lock: "FOR UPDATE NOWAIT"
        )

        Repo.one!(from r in Record, where: r.id == ^handed.record.id, lock: "FOR UPDATE NOWAIT")

        {1, _rows} =
          Repo.update_all(from(c in Collection, where: c.id == ^id),
            set: [environment_ref: "env-2"]
          )
      end)

      commit(first)

      assert {:ok, %Run{}} = Task.await(second.task)
      missing_ended!(ctx, handed, "env-2")
    end

    test "and a part at once: none deadlocks, one prebuild waits", ctx do
      for _round <- 1..4 do
        handed = missing_handed_over!(ctx)
        missing_exit!(handed)

        [projected, {:ok, :changed}] =
          together([fn -> Projector.project(handed.run) end, part(handed, "env-2")])

        assert {:ok, %Run{}} = projected
        missing_ended!(ctx, handed, ~w(env-1 env-2))
      end
    end

    test "and a Rebuild at once: none deadlocks, one prebuild waits", ctx do
      for _round <- 1..4 do
        handed = missing_handed_over!(ctx)
        missing_exit!(handed)

        [projected, rebuilt] =
          together([
            fn -> Projector.project(handed.run) end,
            fn -> Environments.rebuild(ctx.scope, ctx.target) end
          ])

        assert {:ok, %Run{}} = projected
        assert rebuilt in [{:ok, 0}, {:ok, 1}]
        missing_ended!(ctx, handed, "env-1")
      end
    end

    test "and two releases at once: the end decides, none deadlocks", ctx do
      for _round <- 1..4 do
        handed = missing_handed_over!(ctx)
        missing_exit!(handed)

        sides = [
          fn -> {:projection, Projector.project(handed.run)} end,
          fn -> {:release, release(ctx, handed)} end,
          fn -> {:release, release(ctx, handed)} end
        ]

        answers = together(Enum.take(sides, sides(length(sides))))
        assert {:projection, {:ok, %Run{}}} = List.keyfind(answers, :projection, 0)

        assert Enum.all?(
                 for({:release, answer} <- answers, do: answer),
                 &(&1 in [{:error, :machine_exists}, {:error, :gone}])
               )

        missing_ended!(ctx, handed, "env-1")
      end
    end

    test "and a close at once: the end decides, none deadlocks", ctx do
      for _round <- 1..4 do
        handed = missing_handed_over!(ctx)
        missing_exit!(handed)
        work_item = Repo.get!(WorkItem, handed.dispatch_run.work_item_id)

        [projected, closed] =
          together([
            fn -> Projector.project(handed.run) end,
            fn -> Apiary.WorkItems.close(ctx.scope, work_item) end
          ])

        assert {:ok, %Run{}} = projected
        assert {:ok, %WorkItem{state: :closed}} = closed
        missing_ended!(ctx, handed, "env-1", false)
      end
    end

    test "the projection's end and the checks at once: one end", ctx do
      for _round <- 1..4 do
        handed = missing_handed_over!(ctx)
        missing_exit!(handed)
        now = Dispatches.now()

        sides = [
          fn -> {:projection, Projector.project(handed.run)} end,
          fn -> {:check, Liveness.check(now)} end,
          fn -> {:lose, RunEnd.lose(now)} end
        ]

        answers = together(Enum.take(sides, sides(length(sides))))
        assert {:projection, {:ok, %Run{}}} = List.keyfind(answers, :projection, 0)
        missing_ended!(ctx, handed, "env-1")
      end
    end

    test "two lost-run checks of a folded exit at once: one end", ctx do
      for _round <- 1..4 do
        handed = missing_handed_over!(ctx)
        missing_folded!(handed)
        now = Dispatches.now()

        together([fn -> RunEnd.lose(now) end, fn -> RunEnd.lose(now) end])
        missing_ended!(ctx, handed, "env-1")
      end
    end
  end

  test "the checks and two releases at once: one decides, the slot is freed once",
       ctx do
    for _round <- 1..3 do
      handed = handed_over!(ctx)
      at = past_backstop(handed)

      ends = [
        fn -> {:check, Liveness.check(at)} end,
        fn -> {:lose, RunEnd.lose(at)} end,
        fn -> {:release, release(ctx, handed)} end,
        fn -> {:release, release(ctx, handed)} end
      ]

      answers = together(Enum.take(ends, sides(length(ends))))

      releases = for {:release, answer} <- answers, do: answer
      assert Enum.all?(releases, &(&1 in [{:error, :machine_exists}, {:error, :gone}]))

      {cause, _run} = ended!(ctx, handed)
      assert cause in [:lost, :run_ended]

      # A second round of the same ends changes nothing.
      before = Repo.get!(Dispatch, handed.dispatch.id)
      together(Enum.take(ends, sides(length(ends))))
      assert Repo.get!(Dispatch, handed.dispatch.id) == before
      assert {^cause, _run} = ended!(ctx, handed)
    end
  end
end
