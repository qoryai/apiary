defmodule Apiary.Dispatches.RunEndRacesTest do
  # The ends of a run a workspace's queue handed over racing each other
  # (`Apiary.Dispatches.RunEnd`), each on a separate connection, outside the SQL sandbox,
  # so each commits and each waits on the other's locks as it would in production. Not
  # async: what these tests commit is visible to every other test while they run, and they
  # delete it again before they end; the adapters, which outlive an organisation, by what
  # they made.
  #
  # The rules under test: every end locks the run of the queue first, then the registered
  # run, then writes the dispatches. So the backstop and an outcome that come at once, a
  # release and an outcome, or any of the ends together, take turns: the first decides the
  # end cause, the outcome is taken whichever is first and never refused as given, the slot
  # is freed once, by the first end, and none of them deadlocks. For a prebuild handed
  # over, the lost-run check holds its environment record before the run of the queue, as
  # a release and a trigger of its collection hold it: so the check takes turns with them
  # at the record, the record keeps the end that decided, and none deadlocks. What a run
  # gave is stored by its end or by a settle (`Apiary.Dispatches.Settle`), which locks the
  # run of the queue alone: it takes turns with an outcome, a projection and the lost-run
  # check there, and what is stored is the same whichever comes first.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.RunEventsFixtures, only: [event_fixture: 4]
  import Apiary.WorkItemsFixtures, only: [result_event!: 3, understood_result: 0]

  alias Apiary.{Dispatches, Edition, Environments, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunEnd, Settle, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Liveness, Projector, Run}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @reason "The job could not start."

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

  defp release(%{dispatch_run: %DispatchRun{id: id}}),
    do: Repo.transact(fn -> Dispatches.end_run_released(id, Dispatches.now()) end)

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

  describe "the backstop and an outcome" do
    test "at once: the outcome is taken, one end decides, the slot is freed once", ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)
        at = past_backstop(handed)

        [_lost, outcome] =
          together([
            fn -> Liveness.check(at) end,
            fn -> give_outcome(ctx.key, handed.run, "failed", "crashed") end
          ])

        assert {:ok, %{repeated: false}} = outcome
        {cause, run} = ended!(ctx, handed)
        assert cause in [:lost, :run_ended]
        assert %Run{state: "failed", reason: "crashed", lost_at: nil} = run
      end
    end

    test "the backstop first: the outcome waits, is taken after it, and the end stays lost",
         ctx do
      handed = handed_over!(ctx)

      {first, first_pid} = hold(fn -> Liveness.check(past_backstop(handed)) end)
      assert [%Run{state: "lost"}] = first.result

      second = start(fn -> give_outcome(ctx.key, handed.run, "failed") end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %{repeated: false, run: %Run{state: "failed"}}} = Task.await(second.task)
      assert {:lost, %Run{state: "failed", outcome_state: "failed"}} = ended!(ctx, handed)
    end

    test "the outcome first: the backstop waits, and finds the run ended by it", ctx do
      handed = handed_over!(ctx)

      {first, first_pid} = hold(fn -> give_outcome(ctx.key, handed.run, "succeeded") end)
      assert {:ok, %{repeated: false}} = first.result

      second = start(fn -> Liveness.check(past_backstop(handed)) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == []
      assert {:run_ended, %Run{state: "completed", lost_at: nil}} = ended!(ctx, handed)
    end
  end

  describe "a release after the handover and an outcome" do
    test "at once: the outcome is taken, never as given, and one end decides", ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)

        [released, outcome] =
          together([
            fn -> release(handed) end,
            fn -> give_outcome(ctx.key, handed.run, "failed") end
          ])

        assert {:ok, %{repeated: false}} = outcome
        {cause, run} = ended!(ctx, handed)

        case cause do
          :released -> assert {:ok, %{run: %Run{}}} = released
          :run_ended -> assert released == {:error, :ended}
        end

        assert %Run{state: "failed", outcome_state: "failed"} = run
      end
    end

    test "the release first: the outcome waits, is taken after it, and the end stays released",
         ctx do
      handed = handed_over!(ctx)

      {first, first_pid} = hold(fn -> release(handed) end)
      assert {:ok, %{run: %Run{state: "cancelled", reason: "released"}}} = first.result

      second = start(fn -> give_outcome(ctx.key, handed.run, "failed", "crashed") end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %{repeated: false}} = Task.await(second.task)

      assert {:released, %Run{state: "failed", reason: "crashed", released_at: %DateTime{}}} =
               ended!(ctx, handed)
    end

    test "the outcome first: the release waits, and is :ended", ctx do
      handed = handed_over!(ctx)

      {first, first_pid} = hold(fn -> give_outcome(ctx.key, handed.run, "succeeded") end)
      assert {:ok, %{repeated: false}} = first.result

      second = start(fn -> release(handed) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :ended}
      assert {:run_ended, %Run{state: "completed", released_at: nil}} = ended!(ctx, handed)
    end
  end

  describe "a prebuild lost after its handover" do
    # A pool with a gateway, whose keys' public halves, and the adapters and entries its
    # collections leave, are deleted as the release's races delete them: the organisation
    # first, then what outlives it.
    setup ctx do
      started = DateTime.utc_now()
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
          queued_ref: "env-1",
          queued_at: DateTime.utc_now(),
          image: @image,
          size: 734_003_200,
          commit: "9c1e4a7b",
          built_at: DateTime.utc_now(),
          reported_ref: "env-1"
        })

      {:ok, queued} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.place.pool, "env-1") end)

      %{dispatch: dispatch} = dispatched!(ctx.place.key)
      assert dispatch.dispatch_run_id == queued.id

      {:ok, %{run: run}} =
        Dispatches.handover(ctx.place.key, dispatch.public_id, %{body: @body})

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
          reason: @reason,
          retry: false
        })
      end
    end

    # A new `environment_ref` of the prebuild's collection, triggered as a listing does.
    defp trigger(%{collection: %Collection{id: id}}, ref) do
      fn ->
        Repo.transact(fn ->
          {1, _rows} =
            Repo.update_all(from(c in Collection, where: c.id == ^id),
              set: [environment_ref: ref]
            )

          {:ok, Environments.trigger([Repo.get!(Collection, id)], Dispatches.now())}
        end)
      end
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
    # end queues none. A trigger queues one for each pool of the workspace.
    defp runs_of(handed) do
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id == ^handed.collection.id,
          where: r.pool_id == ^handed.dispatch_run.pool_id,
          order_by: [r.inserted_at, r.id]
      )
    end

    defp for_pool(runs, handed),
      do: Enum.filter(runs, &(&1.pool_id == handed.dispatch_run.pool_id))

    test "and a release at once: one decides, the record keeps its end, none deadlocks",
         ctx do
      for _round <- 1..4 do
        handed = prebuild_handed_over!(ctx)

        [lost, released] =
          together([lose_prebuild(handed), release_prebuild(ctx, handed)])

        case end_cause(handed) do
          :lost ->
            assert lost != []
            assert released == {:error, :gone}

            assert %Record{failure_cause: :lost, failure_reason: nil} = record_kept!(handed)

          :released ->
            assert lost == []
            assert released == :ok

            assert %Record{failure_cause: :released, failure_reason: @reason} =
                     record_kept!(handed)
        end

        assert [%DispatchRun{state: :ended}] = runs_of(handed)
        assert Slots.held(ctx.place.pool.id) == 0
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
      assert [%DispatchRun{state: :ended}] = runs_of(handed)
    end

    test "the release first: the check waits on the record, then finds the run ended", ctx do
      handed = prebuild_handed_over!(ctx)

      {first, first_pid} = hold(release_prebuild(ctx, handed))
      assert first.result == :ok

      second = start(lose_prebuild(handed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == []
      assert end_cause(handed) == :released
      assert %Record{failure_cause: :released, failure_reason: @reason} = record_kept!(handed)
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

    test "the trigger first: the check waits on the record, records the failure, and the trigger's prebuild waits",
         ctx do
      handed = prebuild_handed_over!(ctx)

      {first, first_pid} = hold(trigger(handed, "env-2"))
      assert {:ok, queued} = first.result
      assert [%DispatchRun{environment_ref: "env-2"}] = for_pool(queued, handed)

      second = start(lose_prebuild(handed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) != []
      assert end_cause(handed) == :lost

      assert %Record{failure_cause: :lost, failure_reason: nil, queued_ref: "env-2"} =
               record_kept!(handed)

      assert [
               %DispatchRun{state: :ended},
               %DispatchRun{state: :waiting, environment_ref: "env-2"}
             ] =
               runs_of(handed)
    end

    test "the check first: the trigger waits on the record, then queues its prebuild", ctx do
      handed = prebuild_handed_over!(ctx)

      {first, first_pid} = hold(lose_prebuild(handed))
      assert first.result != []

      second = start(trigger(handed, "env-2"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, queued} = Task.await(second.task)
      assert [%DispatchRun{environment_ref: "env-2"}] = for_pool(queued, handed)

      assert %Record{failure_cause: :lost, failure_reason: nil, queued_ref: "env-2"} =
               record_kept!(handed)

      assert [
               %DispatchRun{state: :ended},
               %DispatchRun{state: :waiting, environment_ref: "env-2"}
             ] =
               runs_of(handed)
    end

    test "and a trigger at once, with a release: none deadlocks, one prebuild waits", ctx do
      for _round <- 1..4 do
        handed = prebuild_handed_over!(ctx)

        [_lost, _triggered, _released] =
          together(
            Enum.take(
              [lose_prebuild(handed), trigger(handed, "env-2"), release_prebuild(ctx, handed)],
              sides(3)
            )
          )

        assert end_cause(handed) in [:lost, :released]
        assert %Record{failure_cause: cause, queued_ref: "env-2"} = record_kept!(handed)
        assert cause == end_cause(handed)

        assert [%DispatchRun{state: :ended}, %DispatchRun{state: :waiting}] = runs_of(handed)

        # The prebuild the trigger queued ends, so the next round claims the prebuild it queues.
        {:ok, _changed} =
          Repo.transact(fn ->
            {:ok, Dispatches.end_waiting_prebuilds([handed.collection.id], Dispatches.now())}
          end)
      end
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

    test "a settle and an outcome at once, its result folded: the outcome's end stores it",
         ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)
        result!(handed, 8)
        {:ok, _run} = Projector.project(handed.run)

        [settled, outcome] =
          together([
            fn -> Settle.settle(handed.dispatch_run.id) end,
            fn -> give_outcome(ctx.key, handed.run, "succeeded") end
          ])

        assert settled == []
        assert {:ok, %{repeated: false}} = outcome
        assert {:run_ended, _run} = ended!(ctx, handed)
        assert {:proposal, %{"verdict" => "understood"}} = stored(handed)
      end
    end

    test "a projection of the result and the exit, and an outcome at once: one end, stored",
         ctx do
      for _round <- 1..4 do
        handed = handed_over!(ctx)
        result!(handed, 8)

        event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

        [projected, outcome] =
          together([
            fn -> Projector.project(handed.run) end,
            fn -> give_outcome(ctx.key, handed.run, "succeeded") end
          ])

        assert {:ok, %Run{}} = projected
        assert {:ok, %{repeated: false}} = outcome
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

    test "the outcome first: a settle waits on the run of the queue, and finds it stored",
         ctx do
      handed = handed_over!(ctx)
      result!(handed, 8)
      {:ok, _run} = Projector.project(handed.run)

      {first, first_pid} = hold(fn -> give_outcome(ctx.key, handed.run, "succeeded") end)
      assert {:ok, %{repeated: false}} = first.result

      second = start(fn -> Settle.settle(handed.dispatch_run.id) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == []
      assert {:proposal, %{"verdict" => "understood"}} = stored(handed)
    end
  end

  test "every end at once: one decides, the slot is freed once, and none deadlocks", ctx do
    for _round <- 1..3 do
      handed = handed_over!(ctx)
      at = past_backstop(handed)

      ends = [
        fn -> {:check, Liveness.check(at)} end,
        fn -> {:lose, RunEnd.lose(at)} end,
        fn -> {:release, release(handed)} end,
        fn -> {:release, release(handed)} end,
        fn -> {:outcome, give_outcome(ctx.key, handed.run, "failed")} end
      ]

      answers = together(Enum.take(ends, sides(length(ends))))

      releases = for {:release, answer} <- answers, do: answer
      assert Enum.count(releases, &match?({:ok, _released}, &1)) <= 1
      assert Enum.all?(releases, &(match?({:ok, _released}, &1) or &1 == {:error, :ended}))
      assert Enum.all?(for({:outcome, answer} <- answers, do: answer), &match?({:ok, _}, &1))

      {cause, _run} = ended!(ctx, handed)
      assert cause in [:lost, :released, :run_ended]

      # A second round of every end changes nothing.
      before = Repo.get!(Dispatch, handed.dispatch.id)
      together(Enum.take(ends, sides(length(ends))))
      assert Repo.get!(Dispatch, handed.dispatch.id) == before
      assert {^cause, _run} = ended!(ctx, handed)
    end
  end
end
