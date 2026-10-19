defmodule Apiary.DispatchesRacesTest do
  # Claims racing each other (`Apiary.Dispatches.claim/2`), each on a separate
  # connection, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to every other
  # test while they run, and they delete it again before they end; the ledger and the
  # adapters, which outlive an organisation, by what they made.
  #
  # The rules under test: a claim locks its pool's row `FOR NO KEY UPDATE` before it
  # counts the pool's slots, so two claims of one pool take turns and the second counts
  # the first; and it takes the oldest waiting run `FOR UPDATE SKIP LOCKED`, so two
  # claims, of one pool or of two, never take one run. Two next runs of one take in
  # (`Apiary.Dispatches.queue_next/2`) take turns on the work item's row, so one is
  # written and the other finds it waiting, as nothing here claims, undoes or closes it.
  # One prebuild waits per collection and node pool: two triggers at once take turns on
  # the environment record, two queues at once on the index of the waiting ones, and a
  # lapse that would make a claimed prebuild wait again waits for a trigger that holds
  # the record. Every path takes its locks in the one order `Apiary.Dispatches.Slots`
  # names, so none of them, let go together, waits on another for good.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Environments, Repo}
  alias Apiary.AccessKeys.PublicKey
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

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

    %{scope: scope, made: made}
  end

  defp key!(ctx, pool) do
    %{access_key: key, pair: pair} = enrolled_key_fixture(ctx.scope, pool)
    Agent.update(ctx.made, &%{&1 | public_keys: [pair.public_key | &1.public_keys]})
    key
  end

  defp queued!(ctx, count) do
    for _ <- 1..count do
      work_item = work_item_fixture(ctx.scope)
      Agent.update(ctx.made, &%{&1 | adapters: [work_item.adapter_id | &1.adapters]})
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      run
    end
  end

  # A live collection of the scope's workspace, with a target, under a connection of
  # an adapter remembered for `on_exit`.
  defp collection!(ctx, ref \\ "SHOP") do
    connection = ticket_connection_fixture(ctx.scope)
    Agent.update(ctx.made, &%{&1 | adapters: [connection.adapter_id | &1.adapters]})

    Repo.insert!(%Collection{
      public_id: Apiary.PublicId.generate(Collection.prefix()),
      organisation_id: ctx.scope.organisation.id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      workspace_id: ctx.scope.workspace.id,
      external_ref: ref,
      url: "https://code.example.com/acme/shop",
      title: "shop",
      target_system: "code.example.com",
      target_path: "acme/shop",
      environment_ref: "env-0",
      last_listed_at: DateTime.utc_now(:second)
    })
  end

  # The trigger for `collection` named with `ref`, in a separate transaction.
  defp trigger(collection, ref) do
    fn ->
      Repo.transact(fn ->
        {:ok, Environments.trigger([%{collection | environment_ref: ref}], Dispatches.now())}
      end)
    end
  end

  # The trigger for `collections`, in the order given, each named with `ref` (nil for
  # none), in one transaction: what it answered, or what it raised.
  defp listing(collections, ref) do
    rescued(fn ->
      Repo.transact(fn ->
        {:ok,
         Environments.trigger(
           Enum.map(collections, &%{&1 | environment_ref: ref}),
           Dispatches.now()
         )}
      end)
    end)
  end

  # `fun`, its exception's message for what it answered should it raise one.
  defp rescued(fun) do
    fn ->
      try do
        fun.()
      rescue
        error -> {:raised, Exception.message(error)}
      end
    end
  end

  # Locks the environment records of `collection` `FOR UPDATE`, as a trigger or a lapse
  # does.
  defp lock_records(collection) do
    Repo.all(
      from e in Record,
        where: e.source_collection_id == ^collection.id,
        lock: "FOR UPDATE",
        select: e.id
    )
  end

  # The `environment_ref` of each prebuild of `collection` that waits for `pool`, and the
  # record's `queued_ref`.
  defp waiting_and_queued(collection, pool) do
    waiting =
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id == ^collection.id and r.pool_id == ^pool.id,
          where: r.state == :waiting,
          select: r.environment_ref
      )

    {waiting, Environments.fetch(pool.id, collection.id).queued_ref}
  end

  # The prebuilds of `collection`, `{state, environment_ref}`, the oldest first.
  defp prebuilds(collection) do
    Repo.all(
      from r in DispatchRun,
        where: r.source_collection_id == ^collection.id,
        order_by: [asc: r.queued_at, asc: r.id],
        select: {r.state, r.environment_ref}
    )
  end

  # Prebuilds of `pool` claimed by `key` long ago, their leases lapsed, one per
  # `{collection, id}`, the run of that id: written in two statements, as a sweep of
  # more than one batch needs hundreds of them.
  defp claimed_prebuilds!(ctx, key, pool, pairs) do
    back = DateTime.add(Dispatches.now(), -700, :second)
    lease_until = Dispatches.lease_until(back)
    %{organisation: %{id: organisation_id}, workspace: %{id: workspace_id}} = ctx.scope

    runs =
      for {collection, id} <- pairs do
        %{
          id: id,
          run_id: Ecto.UUID.generate(),
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          step: DispatchRun.prebuild(),
          state: :claimed,
          source_collection_id: collection.id,
          pool_id: pool.id,
          environment_ref: "env-1",
          queued_at: back,
          environment_ref_at: back,
          inserted_at: back,
          updated_at: back
        }
      end

    dispatches =
      for {_collection, id} <- pairs do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          dispatch_run_id: id,
          pool_id: pool.id,
          access_key_id: key.id,
          claimed_at: back,
          lease_until: lease_until,
          inserted_at: back,
          updated_at: back
        }
      end

    count = length(pairs)
    {^count, _rows} = Repo.insert_all(DispatchRun, runs)
    {^count, _rows} = Repo.insert_all(Dispatch, dispatches)
    :ok
  end

  # The claims of `keys`, all let go at once.
  defp claims(keys) do
    keys
    |> Enum.map(fn key -> fn -> Dispatches.claim(key, Dispatches.now()) end end)
    |> together()
  end

  defp taken(answers), do: for({:ok, %{run: run}} <- answers, do: run.id)

  test "of many claims of one waiting run, by two pools, one takes it", ctx do
    first = pool_fixture(ctx.scope)
    second = pool_fixture(ctx.scope)
    keys = [key!(ctx, first), key!(ctx, first), key!(ctx, second)]

    for _round <- 1..3 do
      [run] = queued!(ctx, 1)
      answers = claims(Enum.take(Stream.cycle(keys), sides(6)))

      assert taken(answers) == [run.id]
      assert Enum.count(answers, &(&1 == {:ok, :none})) == length(answers) - 1
    end

    assert Repo.aggregate(Dispatch, :count) == 3
  end

  test "of many claims of a few runs, no run is taken twice", ctx do
    first = pool_fixture(ctx.scope)
    second = pool_fixture(ctx.scope)
    keys = [key!(ctx, first), key!(ctx, second)]
    runs = queued!(ctx, 3)

    answers = claims(Enum.take(Stream.cycle(keys), sides(6)))
    taken = taken(answers)

    assert Enum.sort(taken) == Enum.sort(Enum.map(runs, & &1.id))
    assert Repo.aggregate(from(d in Dispatch, select: d.dispatch_run_id), :count) == 3
  end

  test "parallel claims of one pool never take more slots than its limit", ctx do
    pool = pool_fixture(ctx.scope, instance_limit: 2)
    keys = [key!(ctx, pool), key!(ctx, pool), key!(ctx, pool)]
    queued!(ctx, 5)

    answers = claims(Enum.take(Stream.cycle(keys), sides(6)))

    assert length(taken(answers)) == 2
    assert Slots.held(pool.id) == 2
    assert Repo.aggregate(from(d in Dispatch, where: d.pool_id == ^pool.id), :count) == 2

    # Another round, still at the limit, takes nothing more.
    assert taken(claims(Enum.take(Stream.cycle(keys), sides(4)))) == []
    assert Slots.held(pool.id) == 2
  end

  test "a move of a work item waits for its run's queueing, which writes the run where the work item was",
       ctx do
    # The queue locks the work item first, so the move waits for it, and the run is
    # written in the workspace the work item was in when it was locked.
    work_item = work_item_fixture(ctx.scope)
    Agent.update(ctx.made, &%{&1 | adapters: [work_item.adapter_id | &1.adapters]})
    other = Apiary.OrganisationsFixtures.workspace_fixture(ctx.scope.organisation)

    {first, first_pid} = hold(fn -> Dispatches.queue(work_item, 1) end)
    assert {:ok, run} = first.result

    mover =
      start(fn ->
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [workspace_id: other.id]
        )
      end)

    await_blocked(mover.backend, first_pid)
    commit(first)
    assert {1, _} = Task.await(mover.task)

    assert run.workspace_id == ctx.scope.workspace.id
  end

  test "of two next runs at once for one take in, the second waits on the work item, finds the first's run waiting and writes none",
       ctx do
    # queue_next/2 locks the work item before it reads the take in's runs, so the second
    # reads them once the first committed its run.
    work_item = work_item_fixture(ctx.scope)
    Agent.update(ctx.made, &%{&1 | adapters: [work_item.adapter_id | &1.adapters]})
    {:ok, first_run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    Repo.update_all(from(r in DispatchRun, where: r.id == ^first_run.id),
      set: [state: :ended, end_cause: :lost]
    )

    {first, first_pid} = hold(fn -> Dispatches.queue_next(work_item, 1) end)
    assert {:ok, %DispatchRun{attempt: 2}} = first.result

    second = start(fn -> Repo.transact(fn -> {:ok, Dispatches.queue_next(work_item, 1)} end) end)

    await_blocked(second.backend, first_pid)
    commit(first)
    assert {:ok, {:error, :running}} = Task.await(second.task)

    assert Repo.all(
             from r in DispatchRun,
               where: r.work_item_id == ^work_item.id,
               order_by: r.attempt,
               select: {r.attempt, r.state}
           ) == [{1, :ended}, {2, :waiting}]
  end

  describe "one prebuild waits per collection and node pool" do
    test "of two triggers at once, the second waits on the record and sets its environment_ref on the waiting one",
         ctx do
      pool = pool_fixture(ctx.scope)
      collection = collection!(ctx)

      {first, holder} =
        hold(fn ->
          Environments.trigger([%{collection | environment_ref: "env-1"}], Dispatches.now())
        end)

      assert [%DispatchRun{environment_ref: "env-1"}] = first.result

      second = start(trigger(collection, "env-2"))
      await_blocked(second.backend, holder)
      commit(first)

      assert {:ok, [%DispatchRun{id: id, environment_ref: "env-2"}]} = Task.await(second.task)
      assert id == hd(first.result).id
      assert prebuilds(collection) == [{:waiting, "env-2"}]
      assert %Record{queued_ref: "env-2"} = Environments.fetch(pool.id, collection.id)
    end

    test "of many triggers let go at once, with two environment_refs, one prebuild waits",
         ctx do
      pool = pool_fixture(ctx.scope)
      collection = collection!(ctx)

      answers =
        ~w(env-1 env-2)
        |> Stream.cycle()
        |> Enum.take(sides(6))
        |> Enum.map(&trigger(collection, &1))
        |> together()

      assert Enum.all?(answers, &match?({:ok, _queued}, &1))
      assert [{:waiting, ref}] = prebuilds(collection)
      assert %Record{queued_ref: ^ref} = Environments.fetch(pool.id, collection.id)
    end

    test "of two queues at once, the second waits on the index and sets its environment_ref on the first",
         ctx do
      pool = pool_fixture(ctx.scope)
      collection = collection!(ctx)

      {first, holder} = hold(fn -> Dispatches.queue_prebuild(collection, pool, "env-1") end)
      assert {:ok, run} = first.result

      second =
        start(fn ->
          Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-2") end)
        end)

      await_blocked(second.backend, holder)
      commit(first)

      assert {:ok, %DispatchRun{id: id, environment_ref: "env-2"}} = Task.await(second.task)
      assert id == run.id
      assert prebuilds(collection) == [{:waiting, "env-2"}]
    end

    test "a lapse waits for the trigger that holds the record, then ends the claimed one superseded",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)
      collection = collection!(ctx)

      {:ok, [run]} = trigger(collection, "env-1").()
      {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now())

      {first, holder} =
        hold(fn ->
          Environments.trigger([%{collection | environment_ref: "env-2"}], Dispatches.now())
        end)

      assert [%DispatchRun{environment_ref: "env-2"}] = first.result

      sweep = start(fn -> Dispatches.sweep(dispatch.lease_until) end)
      await_blocked(sweep.backend, holder)
      commit(first)
      Task.await(sweep.task)

      assert %DispatchRun{state: :ended, end_cause: :superseded} = Repo.get!(DispatchRun, run.id)
      assert prebuilds(collection) == [{:ended, "env-1"}, {:waiting, "env-2"}]
      assert %Dispatch{end_cause: :run_ended} = Repo.get!(Dispatch, dispatch.id)
    end

    test "a claim waits for a trigger paused between its record and its prebuild, which never waits on the claim's pool",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)
      collection = collection!(ctx)

      {:ok, [run]} = trigger(collection, "env-1").()

      {:ok, %{dispatch: dispatch}} =
        Dispatches.claim(key, DateTime.add(Dispatches.now(), -700, :second))

      # The trigger's first half: its record locked, as its upsert locks it.
      {first, holder} = hold(fn -> lock_records(collection) end)

      # The claim locks the pool, then waits on the record of its lapsed prebuild.
      claim = start(fn -> Dispatches.claim(key, Dispatches.now()) end)
      await_waited(claim.backend, holder)

      # The trigger's second half: the record's queued_ref, then the prebuild, whose
      # foreign key to the pool takes its row FOR KEY SHARE beside the claim's lock.
      assert {:ok, %DispatchRun{id: queued, environment_ref: "env-2"}} =
               continue(first, fn ->
                 Repo.update_all(
                   from(e in Record, where: e.source_collection_id == ^collection.id),
                   set: [queued_ref: "env-2"]
                 )

                 Dispatches.queue_prebuild(collection, pool, "env-2")
               end)

      commit(first)

      # The claim then finds it waiting: the lapsed one gives way, and it takes the new one.
      assert {:ok, %{run: %DispatchRun{id: ^queued, environment_ref: "env-2"}}} =
               Task.await(claim.task)

      assert %DispatchRun{state: :ended, end_cause: :superseded} = Repo.get!(DispatchRun, run.id)
      assert %Dispatch{end_cause: :run_ended} = Repo.get!(Dispatch, dispatch.id)
    end

    test "a trigger locks its records by collection, whatever order the listing names them in",
         ctx do
      pool = pool_fixture(ctx.scope)
      [low, high] = Enum.sort_by([collection!(ctx, "A"), collection!(ctx, "B")], & &1.id)
      {:ok, _queued} = listing([low, high], "env-1").()

      # A lapse part way: the lower collection's record locked.
      {first, holder} = hold(fn -> lock_records(low) end)

      # The listing names the higher one first, without an environment_ref, so it retires
      # it, and the lower one with a new one: it waits on the lower one's record first.
      changed =
        start(
          rescued(fn ->
            Repo.transact(fn ->
              {:ok,
               Environments.trigger(
                 [%{high | environment_ref: nil}, %{low | environment_ref: "env-2"}],
                 Dispatches.now()
               )}
            end)
          end)
        )

      await_waited(changed.backend, holder)

      # The lapse goes on to the higher one's record, which the listing has not locked.
      assert [_id] = continue(first, fn -> lock_records(high) end)
      commit(first)

      assert {:ok, [%DispatchRun{environment_ref: "env-2"}]} = Task.await(changed.task)
      assert waiting_and_queued(low, pool) == {["env-2"], "env-2"}
      assert waiting_and_queued(high, pool) == {[], "env-1"}
    end

    test "a sweep waits for a listing that holds the records of two collections, and each lapsed one gives way",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)
      [low, high] = Enum.sort_by([collection!(ctx, "A"), collection!(ctx, "B")], & &1.id)
      {:ok, _queued} = listing([low, high], "env-1").()
      back = DateTime.add(Dispatches.now(), -700, :second)
      {:ok, %{run: one}} = Dispatches.claim(key, back)
      {:ok, %{run: two}} = Dispatches.claim(key, back)

      {first, holder} =
        hold(fn ->
          Environments.trigger(
            [%{high | environment_ref: "env-2"}, %{low | environment_ref: "env-2"}],
            Dispatches.now()
          )
        end)

      sweep = start(rescued(fn -> Dispatches.sweep(Dispatches.now()) end))
      await_waited(sweep.backend, holder)
      commit(first)

      assert [_workspace] = Task.await(sweep.task)

      for run <- [one, two],
          do: assert(%DispatchRun{end_cause: :superseded} = Repo.get!(DispatchRun, run.id))

      for collection <- [low, high],
          do: assert(waiting_and_queued(collection, pool) == {["env-2"], "env-2"})
    end

    test "a sweep of more than one batch locks the records of every batch before its first, so a listing that holds a later batch's record and then asks for an earlier one's never waits on it for good",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)
      [low, high] = Enum.sort_by([collection!(ctx, "A"), collection!(ctx, "B")], & &1.id)
      {:ok, _queued} = listing([low, high], "env-1").()

      # None waits for the higher one, so one of its lapsed ones waits again.
      {1, _rows} =
        Repo.update_all(
          from(r in DispatchRun, where: r.source_collection_id == ^high.id),
          set: [state: :ended, end_cause: :superseded]
        )

      # A free takes 500 lapsed dispatches a batch, by run id: the first batch holds
      # prebuilds of the higher collection only, the second one of the lower and one more
      # of the higher.
      ids = Enum.sort(for _ <- 1..502, do: Ecto.UUID.generate())
      {first_batch, [lower, last]} = Enum.split(ids, 500)
      highs = first_batch ++ [last]
      claimed_prebuilds!(ctx, key, pool, [{low, lower} | Enum.map(highs, &{high, &1})])

      # A listing part way: the lower collection's record locked.
      {first, holder} = hold(fn -> lock_records(low) end)

      sweep = start(rescued(fn -> Dispatches.sweep(Dispatches.now()) end))
      await_waited(sweep.backend, holder)

      # The listing goes on to the higher one's record, which the sweep took no lock on
      # before the lower one's.
      assert [_id] = continue(first, fn -> lock_records(high) end)
      commit(first)

      assert Task.await(sweep.task) == [ctx.scope.workspace.id]

      superseded =
        Repo.all(
          from r in DispatchRun,
            where: r.id in ^[lower | highs] and r.end_cause == :superseded,
            select: r.id
        )

      assert length(superseded) == 501
      assert lower in superseded
      # One of the first batch waits again; the second batch finds it waiting.
      assert [again] = [lower | highs] -- superseded
      assert again in first_batch

      assert %DispatchRun{state: :waiting, environment_ref: "env-1"} =
               Repo.get!(DispatchRun, again)

      for collection <- [low, high],
          do: assert(waiting_and_queued(collection, pool) == {["env-1"], "env-1"})

      assert Repo.aggregate(
               from(d in Dispatch,
                 where: d.dispatch_run_id in ^superseded and d.end_cause == :run_ended,
                 where: not is_nil(d.stale_at) and not is_nil(d.slot_freed_at)
               ),
               :count
             ) == 501
    end

    test "flips of two collections in any order, sweeps, lapses and claims together: no error, and what waits carries the record's queued_ref",
         ctx do
      pool = pool_fixture(ctx.scope)
      keys = [key!(ctx, pool), key!(ctx, pool)]
      collections = [collection!(ctx, "A"), collection!(ctx, "B")]
      {:ok, _queued} = listing(collections, "env-0").()

      raised =
        for round <- 1..15, reduce: [] do
          raised ->
            # A claim at a time long gone lapses at once, so the sweep of the same round, or
            # the next, finds two claimed prebuilds of one collection and pool.
            back = DateTime.add(Dispatches.now(), -700, :second)
            dropped = if rem(round, 4) == 0, do: nil, else: "env-#{round}c"

            answers =
              [
                listing: listing(Enum.shuffle(collections), "env-#{round}a"),
                listing: listing(Enum.shuffle(collections), "env-#{round}b"),
                listing: listing(Enum.shuffle(collections), dropped),
                sweep: rescued(fn -> Dispatches.sweep(Dispatches.now()) end),
                lapsing_claim: rescued(fn -> Dispatches.claim(Enum.at(keys, 0), back) end),
                claim: rescued(fn -> Dispatches.claim(Enum.at(keys, 1), Dispatches.now()) end)
              ]
              |> Enum.take(sides(6))
              |> Enum.map(fn {name, fun} -> fn -> {name, fun.()} end end)
              |> together()

            for collection <- collections do
              {waiting, queued_ref} = waiting_and_queued(collection, pool)
              assert waiting in [[], [queued_ref]], "round #{round}: #{inspect(waiting)}"
            end

            raised ++ for({name, {:raised, message}} <- answers, do: {round, name, message})
        end

      assert raised == []
    end
  end
end
