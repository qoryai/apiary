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
  # One prebuild waits per collection, node pool and `environment_ref`: two queues at once
  # take turns on the index of the waiting ones, and a lapse that would make a claimed
  # prebuild wait again waits for a build queued under the record. A run held for its
  # pool's build of its target (`Apiary.Environments.held/2`) is never taken while it is
  # held, and the claim that queues its build holds the target's collections first, with
  # the collections of the pool's lapsed prebuilds, so a key change, an assign or a
  # Backlog switch waits for it. Every path takes its locks in the one order
  # `Apiary.Dispatches.Slots` names, so none of them, let go together, waits on another
  # for good.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.AccessKeys.{AccessKey, PublicKey}
  alias Apiary.Adapters.{Collection, Collections, Connection}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    # The workspace's default gateway, which the pools' claims resolve to, and its key's
    # public half, which outlives the organisation.
    gateway = workspace_gateway!(scope)

    gateway_key =
      Repo.one!(from k in AccessKey, where: k.node_id == ^gateway.id, select: k.public_key)

    {:ok, made} = Agent.start(fn -> %{public_keys: [gateway_key], adapters: []} end)

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

  # A live collection of the scope's workspace, with the target `acme/shop` or `path` on
  # `code.example.com`, under a fresh connection of an adapter remembered for `on_exit`,
  # or under the connection `opts[:connection]`; its id `opts[:id]` when given, and its
  # `environment_ref` `opts[:environment_ref]`, else `env-0`.
  defp collection!(ctx, ref \\ "SHOP", path \\ "acme/shop", opts \\ []) do
    connection =
      Keyword.get_lazy(opts, :connection, fn ->
        connection = ticket_connection_fixture(ctx.scope)
        Agent.update(ctx.made, &%{&1 | adapters: [connection.adapter_id | &1.adapters]})
        connection
      end)

    Repo.insert!(%Collection{
      id: opts[:id],
      public_id: Apiary.PublicId.generate(Collection.prefix()),
      organisation_id: ctx.scope.organisation.id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      workspace_id: ctx.scope.workspace.id,
      external_ref: ref,
      url: "https://code.example.com/acme/shop",
      title: "shop",
      target_system: "code.example.com",
      target_path: path,
      environment_ref: Keyword.get(opts, :environment_ref, "env-0"),
      last_listed_at: DateTime.utc_now(:second)
    })
  end

  # Two collections of one connection with the target `path`, and a run held for that
  # target: `lapsed`, the lower id, whose `environment_ref` `env-1` has a prebuild
  # claimed by `key` for `pool` whose lease lapsed, so no build of it is due, and `due`,
  # whose `env-0` has none, so a claim of the pool queues one. The claim's free sets the
  # lapsed prebuild waiting again and its take writes it again, which takes a
  # `FOR KEY SHARE` lock on `lapsed`. With the target's row, for a Backlog switch.
  defp lapsed_pair!(ctx, key, pool, path) do
    connection = ticket_connection_fixture(ctx.scope)
    Agent.update(ctx.made, &%{&1 | adapters: [connection.adapter_id | &1.adapters]})
    [low, high] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()])
    on = [connection: connection]
    lapsed = collection!(ctx, "L-" <> path, path, [id: low, environment_ref: "env-1"] ++ on)
    due = collection!(ctx, "D-" <> path, path, [id: high] ++ on)
    :ok = claimed_prebuilds!(ctx, key, pool, [{lapsed, Ecto.UUID.generate()}])
    _held = held!(ctx, path)
    target = %{system: "code.example.com", path: path}
    :ok = Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [target])

    %{
      connection: connection,
      lapsed: lapsed,
      due: due,
      target: Repo.get_by!(Target, workspace_id: ctx.scope.workspace.id, path: path)
    }
  end

  # A listing's part that gives `collections` the `environment_ref` `ref`: their
  # connections held `FOR UPDATE` by id, then each collection `FOR UPDATE` by id, as a
  # part holds them, then changed, in one transaction: what it answered, or what it
  # raised.
  defp part(collections, ref) do
    rescued(fn ->
      Repo.transact(fn ->
        ids = collections |> Enum.map(& &1.id) |> Enum.sort()
        connection_ids = collections |> Enum.map(& &1.connection_id) |> Enum.uniq()

        _connections =
          Repo.all(
            from k in Apiary.Adapters.Connection,
              where: k.id in ^connection_ids,
              order_by: k.id,
              lock: "FOR UPDATE",
              select: k.id
          )

        _held =
          Repo.all(from c in Collection, where: c.id in ^ids, order_by: c.id, lock: "FOR UPDATE")

        {_count, _rows} =
          Repo.update_all(from(c in Collection, where: c.id in ^ids),
            set: [environment_ref: ref]
          )

        {:ok, :changed}
      end)
    end)
  end

  # A Rebuild of `collections` for `pools`: each held `FOR SHARE` by id, then their
  # records `FOR UPDATE`, by collection and then pool, in one statement, then a prebuild
  # of each with an `environment_ref` queued for each pool, in one transaction: what it
  # answered, or what it raised.
  defp rebuild(collections, pools) do
    rescued(fn ->
      Repo.transact(fn -> {:ok, collections |> hold_rebuild() |> queue_rebuild(pools)} end)
    end)
  end

  # The first half of `rebuild/2`, inside the caller's transaction: `collections` held
  # `FOR SHARE` by id, then their records `FOR UPDATE`; the collections held.
  defp hold_rebuild(collections) do
    ids = collections |> Enum.map(& &1.id) |> Enum.sort()

    held =
      Repo.all(from c in Collection, where: c.id in ^ids, order_by: c.id, lock: "FOR SHARE")

    _records =
      Repo.all(
        from e in Record,
          where: e.source_collection_id in ^ids,
          order_by: [e.source_collection_id, e.pool_id],
          lock: "FOR UPDATE",
          select: e.id
      )

    held
  end

  # The second half of `rebuild/2`: a prebuild of each of the collections `held` queued
  # for each pool; the prebuilds queued.
  defp queue_rebuild(held, pools) do
    for %Collection{environment_ref: ref} = collection <- held, is_binary(ref), pool <- pools do
      {:ok, run} = Dispatches.queue_prebuild(collection, pool, ref)
      run
    end
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

  # Locks the environment records of `collection` `FOR UPDATE`, as a Rebuild or a lapse
  # does.
  defp lock_records(collection) do
    Repo.all(
      from e in Record,
        where: e.source_collection_id == ^collection.id,
        lock: "FOR UPDATE",
        select: e.id
    )
  end

  # The `environment_ref` of each prebuild of `collection` that waits for `pool`, sorted.
  defp waiting(collection, pool) do
    Repo.all(
      from r in DispatchRun,
        where: r.source_collection_id == ^collection.id and r.pool_id == ^pool.id,
        where: r.state == :waiting,
        order_by: r.environment_ref,
        select: r.environment_ref
    )
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

  # A waiting run of a fresh work item in Explore whose target is `acme/shop` or `path` on
  # `code.example.com`, as a collection's of `collection!/3`: held for its pool's build of
  # that target.
  defp held!(ctx, path \\ "acme/shop") do
    work_item =
      work_item_fixture(ctx.scope, %{target_system: "code.example.com", target_path: path})

    Agent.update(ctx.made, &%{&1 | adapters: [work_item.adapter_id | &1.adapters]})
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
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

  describe "one prebuild waits per collection, node pool and environment_ref" do
    test "of two queues at once for one ref, the second waits on the index and finds the first",
         ctx do
      pool = pool_fixture(ctx.scope)
      collection = collection!(ctx)

      {first, holder} = hold(fn -> Dispatches.queue_prebuild(collection, pool, "env-1") end)
      assert {:ok, run} = first.result

      second =
        start(fn ->
          Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-1") end)
        end)

      await_blocked(second.backend, holder)
      commit(first)

      assert {:ok, %DispatchRun{id: id, environment_ref: "env-1"}} = Task.await(second.task)
      assert id == run.id
      assert prebuilds(collection) == [{:waiting, "env-1"}]

      # Another ref waits beside it.
      {:ok, _other} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-2") end)

      assert waiting(collection, pool) == ~w(env-1 env-2)
    end

    test "a lapse waits for a build of its ref queued under the record, then ends the claimed one superseded",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)
      collection = collection!(ctx)

      {:ok, run} = Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-0") end)
      {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now())

      {first, holder} =
        hold(fn ->
          _locked = lock_records(collection)
          Dispatches.queue_prebuild(collection, pool, "env-0")
        end)

      assert {:ok, %DispatchRun{environment_ref: "env-0"}} = first.result

      sweep = start(fn -> Dispatches.sweep(dispatch.lease_until) end)
      await_blocked(sweep.backend, holder)
      commit(first)
      Task.await(sweep.task)

      assert %DispatchRun{state: :ended, end_cause: :superseded} = Repo.get!(DispatchRun, run.id)
      assert prebuilds(collection) == [{:ended, "env-0"}, {:waiting, "env-0"}]
      assert %Dispatch{end_cause: :run_ended} = Repo.get!(Dispatch, dispatch.id)
    end

    # A Rebuild that holds a later batch's record and then asks for an earlier one's never
    # waits on the sweep for good.
    test "a sweep of more than one batch locks the records of every batch before its first",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)
      [low, high] = Enum.sort_by([collection!(ctx, "A"), collection!(ctx, "B")], & &1.id)
      {:ok, :changed} = part([low, high], "env-1").()
      {:ok, _queued} = rebuild([low, high], [pool]).()

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

      # A Rebuild part way: the lower collection's record locked.
      {first, holder} = hold(fn -> lock_records(low) end)

      sweep = start(rescued(fn -> Dispatches.sweep(Dispatches.now()) end))
      await_waited(sweep.backend, holder)

      # The Rebuild goes on to the higher one's record, which the sweep took no lock on
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
          do: assert(waiting(collection, pool) == ["env-1"])

      assert Repo.aggregate(
               from(d in Dispatch,
                 where: d.dispatch_run_id in ^superseded and d.end_cause == :run_ended,
                 where: not is_nil(d.stale_at) and not is_nil(d.slot_freed_at)
               ),
               :count
             ) == 501
    end

    test "key changes of two collections, a Rebuild, sweeps, lapses and claims of held runs together: no error, one prebuild waits per ref at most",
         ctx do
      pool = pool_fixture(ctx.scope)
      keys = [key!(ctx, pool), key!(ctx, pool)]
      collections = [collection!(ctx, "A"), collection!(ctx, "B")]
      {:ok, _queued} = rebuild(collections, [pool]).()

      raised =
        for round <- 1..15, reduce: [] do
          raised ->
            # A run held for the collections' target each round, whose claim queues its
            # build; a claim at a time long gone lapses at once, so the sweep of the same
            # round, or the next, finds claimed prebuilds of one collection and pool.
            _held = held!(ctx)
            back = DateTime.add(Dispatches.now(), -700, :second)
            dropped = if rem(round, 4) == 0, do: nil, else: "env-#{round}c"

            answers =
              [
                part: part(Enum.shuffle(collections), "env-#{round}a"),
                part: part(Enum.shuffle(collections), dropped),
                rebuild: rebuild(Enum.shuffle(collections), [pool]),
                sweep: rescued(fn -> Dispatches.sweep(Dispatches.now()) end),
                lapsing_claim: rescued(fn -> Dispatches.claim(Enum.at(keys, 0), back) end),
                claim: rescued(fn -> Dispatches.claim(Enum.at(keys, 1), Dispatches.now()) end)
              ]
              |> Enum.take(sides(6))
              |> Enum.map(fn {name, fun} -> fn -> {name, fun.()} end end)
              |> together()

            for collection <- collections do
              waiting = waiting(collection, pool)
              assert waiting == Enum.uniq(waiting), "round #{round}: #{inspect(waiting)}"
            end

            raised ++ for({name, {:raised, message}} <- answers, do: {round, name, message})
        end

      assert raised == []
    end
  end

  describe "a claim that queues a build" do
    # A claim of `key`, each answer one of: a run taken, nothing, or `:unavailable`; what
    # it raised otherwise. A claim answers `:unavailable` for any error of the database,
    # a deadlock included, and logs that it could not be made: that log line is the
    # answer then, `{:failed, line}`.
    defp claim_answer(key) do
      rescued(fn ->
        {answer, log} =
          ExUnit.CaptureLog.with_log(fn -> Dispatches.claim(key, Dispatches.now()) end)

        case {answer, Regex.run(~r/a claim could not be made[^\n]*/, log)} do
          {_answer, [line]} -> {:failed, line}
          {{:ok, _claimed}, nil} -> answer
          {{:error, :unavailable}, nil} -> answer
        end
      end)
    end

    # The environment records of `collection` for `pool`.
    defp records(collection, pool) do
      Repo.aggregate(
        from(e in Record,
          where: e.source_collection_id == ^collection.id and e.pool_id == ^pool.id
        ),
        :count
      )
    end

    test "and a Rebuild at once, with lapsed prebuilds to free: no deadlock, one record, one build per ref",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      raised =
        for round <- 1..15, reduce: [] do
          raised ->
            # A run held for a fresh target with no record for the pool, and a lapsed
            # claimed prebuild of another collection of that target, whose record the
            # claim's free locks before its runs.
            path = "acme/rebuild-#{round}"
            collection = collection!(ctx, "R#{round}", path)
            lapsed = collection!(ctx, "L#{round}", path)
            {:ok, _queued} = rebuild([lapsed], [pool]).()
            :ok = claimed_prebuilds!(ctx, key, pool, [{lapsed, Ecto.UUID.generate()}])
            _held = held!(ctx, path)
            both = Enum.shuffle([collection, lapsed])

            answers =
              if rem(round, 2) == 1 do
                # The Rebuild paused once it holds the records, the claim's free waiting
                # for them, then the Rebuild's prebuilds queued, before it commits.
                {rebuild, rebuild_backend} = hold(fn -> hold_rebuild(both) end)
                claim = start(claim_answer(key))
                await_blocked(claim.backend, rebuild_backend)

                queued =
                  continue(
                    rebuild,
                    rescued(fn -> {:ok, queue_rebuild(rebuild.result, [pool])} end)
                  )

                commit(rebuild)
                [claim: Task.await(claim.task, 15_000), rebuild: queued]
              else
                [claim: claim_answer(key), rebuild: rebuild(both, [pool])]
                |> Enum.map(fn {name, fun} -> fn -> {name, fun.()} end end)
                |> together()
              end

            assert records(collection, pool) == 1

            for c <- [collection, lapsed] do
              waiting = waiting(c, pool)
              assert waiting == Enum.uniq(waiting), "round #{round}: #{inspect(waiting)}"
            end

            raised ++
              for {name, answer} <- answers,
                  not match?({:ok, _}, answer),
                  answer != {:error, :unavailable},
                  do: {round, name, answer}
        end

      assert raised == []
    end

    test "and a listing's part at once, with a lapsed prebuild of a lower collection of the connection: no deadlock, the keys change, one build per ref",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      raised =
        for round <- 1..6, reduce: [] do
          raised ->
            path = "acme/part-#{round}"
            %{lapsed: lapsed, due: due} = lapsed_pair!(ctx, key, pool, path)
            changed = "part-#{round}"

            answers =
              [
                claim: claim_answer(key),
                part: part([lapsed, due], changed)
              ]
              |> Enum.map(fn {name, fun} -> fn -> {name, fun.()} end end)
              |> together()

            assert {:part, {:ok, :changed}} in answers

            for collection <- [lapsed, due] do
              assert %Collection{environment_ref: ^changed} = Repo.get!(Collection, collection.id)
              waiting = waiting(collection, pool)
              assert waiting == Enum.uniq(waiting), "round #{round}: #{inspect(waiting)}"
            end

            raised ++
              for {name, answer} <- answers,
                  not match?({:ok, _}, answer),
                  answer != {:error, :unavailable},
                  do: {round, name, answer}
        end

      assert raised == []
    end
  end

  describe "a claim that frees a lapsed prebuild of a lower collection of a connection" do
    # A Backlog switch of the pair's target off, or an unassign of the pair from the
    # workspace: each holds the connection `FOR SHARE`, then both collections
    # `FOR UPDATE`, by id, and writes them. What it answered, or what it raised.
    defp change_pair(ctx, :switch, pair),
      do: rescued(fn -> Collections.set_backlog(ctx.scope, pair.target, false) end)

    defp change_pair(ctx, :assign, pair) do
      ids = [pair.lapsed.id, pair.due.id]
      rescued(fn -> Collections.assign_collections(ctx.scope, pair.connection, ids, nil) end)
    end

    # The first steps of `change_pair/3`, inside the caller's transaction, up to the lower
    # collection: the connection `FOR SHARE`, the workspace `FOR SHARE` for a switch, and
    # `lapsed` `FOR UPDATE`, the first row its one statement holds.
    defp hold_lower(ctx, change, pair) do
      _connection =
        Repo.one!(from k in Connection, where: k.id == ^pair.connection.id, lock: "FOR SHARE")

      if change == :switch do
        _workspace =
          Repo.one!(
            from w in Apiary.Organisations.Workspace,
              where: w.id == ^ctx.scope.workspace.id,
              lock: "FOR SHARE",
              select: w.id
          )
      end

      Repo.one!(from c in Collection, where: c.id == ^pair.lapsed.id, lock: "FOR UPDATE")
    end

    # Whether `change` wrote both collections of `pair`.
    defp written?(:switch, pair),
      do: Enum.all?([pair.lapsed, pair.due], &(Repo.get!(Collection, &1.id).backlog == false))

    defp written?(:assign, pair),
      do: Enum.all?([pair.lapsed, pair.due], &is_nil(Repo.get!(Collection, &1.id).workspace_id))

    for {change, name} <- [switch: "a Backlog switch", assign: "an assign"] do
      test "and #{name} of the pair, paused once it holds the lower one: no deadlock, both written",
           ctx do
        pool = pool_fixture(ctx.scope)
        key = key!(ctx, pool)

        for round <- 1..3 do
          pair = lapsed_pair!(ctx, key, pool, "acme/#{unquote(change)}-paused-#{round}")

          # The change waits on the claim, or the claim on the change, past half the
          # deadlock timeout, before the change goes on: should they wait on each other,
          # Postgres aborts the claim.
          {held, held_backend} = hold(fn -> hold_lower(ctx, unquote(change), pair) end)
          claim = start(claim_answer(key))
          await_waited(claim.backend, held_backend)
          changed = continue(held, change_pair(ctx, unquote(change), pair))
          commit(held)
          answer = Task.await(claim.task, 15_000)

          assert changed == {:ok, 2}, "round #{round}: #{inspect(changed)}"

          assert match?({:ok, _}, answer) or answer == {:error, :unavailable},
                 "round #{round}: #{inspect(answer)}"

          assert written?(unquote(change), pair)
        end
      end
    end

    test "and switches and assigns of the pair at once: no deadlock, both written", ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      raised =
        for round <- 1..12, reduce: [] do
          raised ->
            change = Enum.at([:switch, :assign], rem(round, 2))
            pair = lapsed_pair!(ctx, key, pool, "acme/#{change}-#{round}")

            answers =
              [claim: claim_answer(key), change: change_pair(ctx, change, pair)]
              |> Enum.map(fn {name, fun} -> fn -> {name, fun.()} end end)
              |> together()

            assert {:change, {:ok, 2}} in answers, "round #{round}: #{inspect(answers)}"
            assert written?(change, pair)

            raised ++
              for {name, answer} <- answers,
                  not match?({:ok, _}, answer),
                  answer != {:error, :unavailable},
                  do: {round, name, answer}
        end

      assert raised == []
    end
  end

  describe "a claim of a run held for its build" do
    @built "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("5e", 32)

    # A collection of the round's target `path` with `env-0`, a run held for its build,
    # and the build claimed by `key`: committed.
    defp build_claimed!(ctx, key, path) do
      collection = collection!(ctx, path, path)
      run = held!(ctx, path)

      assert {:ok, %{run: %DispatchRun{step: "prebuild"} = build}} =
               Dispatches.claim(key, Dispatches.now())

      assert build.source_collection_id == collection.id
      %{collection: collection, run: run, build: build}
    end

    # The build of `round` recorded, as `Apiary.Dispatches.Built` records it: the record
    # `FOR UPDATE`, then the image.
    defp record_build(round) do
      fn ->
        Repo.transact(fn ->
          build = Repo.get!(DispatchRun, round.build.id)
          _record = Apiary.Environments.lock_record(build.pool_id, build.source_collection_id)

          :ok =
            Apiary.Environments.record_build(
              build,
              %{image: @built, size: 1_048_576, commit: "4b7d0a3f", environment_ref: "env-0"},
              %{system: "code.example.com", path: round.collection.target_path},
              Dispatches.now()
            )

          {:ok, :recorded}
        end)
      end
    end

    # What a claim of `key` took: the held run with `@built`, nothing, or, for `allowed`,
    # a prebuild; never the held run in the pool's default image.
    defp assert_claim(answer, round, allowed \\ []) do
      case answer do
        {:ok, :none} ->
          :none

        {:ok, %{run: %DispatchRun{id: id}, registered: registered}} ->
          if id == round.run.id do
            assert registered.configured_image == @built
            :held_run
          else
            assert %DispatchRun{step: "prebuild"} = Repo.get!(DispatchRun, id)
            assert :prebuild in allowed
            :prebuild
          end
      end
    end

    # Ends what waits of the round, so the next round's claim takes the next build.
    defp end_round!(round) do
      {_count, _rows} =
        Repo.update_all(
          from(r in DispatchRun,
            where: r.source_collection_id == ^round.collection.id or r.id == ^round.run.id,
            where: fragment("? = 'waiting'", r.state)
          ),
          set: [state: :ended, end_cause: :collection_ended]
        )
    end

    test "and the build's record at once: the claim takes the run in the built image, or nothing",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      for n <- 1..4 do
        round = build_claimed!(ctx, key, "acme/built-#{n}")

        [recorded, claimed] =
          together([record_build(round), fn -> Dispatches.claim(key, Dispatches.now()) end])

        assert recorded == {:ok, :recorded}

        case assert_claim(claimed, round) do
          :held_run -> :ok
          :none -> assert_claim(Dispatches.claim(key, Dispatches.now()), round)
        end

        assert %DispatchRun{state: :claimed} = Repo.get!(DispatchRun, round.run.id)
        end_round!(round)
      end
    end

    test "and a key change at once: the run stays held, and one build waits per ref", ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      for n <- 1..4 do
        round = build_claimed!(ctx, key, "acme/key-#{n}")

        [changed, claimed] =
          together([
            part([round.collection], "env-#{n}"),
            fn -> Dispatches.claim(key, Dispatches.now()) end
          ])

        assert changed == {:ok, :changed}
        assert_claim(claimed, round, [:prebuild])
        assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, round.run.id)

        waiting = waiting(round.collection, pool)
        assert waiting == Enum.uniq(waiting)

        # The next claim queues the new ref's build, if the first did not, and the run
        # stays held.
        assert_claim(Dispatches.claim(key, Dispatches.now()), round, [:prebuild])
        assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, round.run.id)
        end_round!(round)
      end
    end

    test "and a release of its build at once: one release, the run stays held, one build waits",
         ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      for n <- 1..4 do
        round = build_claimed!(ctx, key, "acme/release-#{n}")
        dispatch = Repo.one!(from d in Dispatch, where: d.dispatch_run_id == ^round.build.id)

        [released, claimed] =
          together([
            fn -> Dispatches.release(key, dispatch.public_id, %{reason: "No machine."}) end,
            fn -> Dispatches.claim(key, Dispatches.now()) end
          ])

        assert released == :ok
        assert_claim(claimed, round, [:prebuild])
        assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, round.run.id)
        assert %Dispatch{end_cause: :released} = Repo.get!(Dispatch, dispatch.id)

        live =
          Repo.all(
            from r in DispatchRun,
              where: r.source_collection_id == ^round.collection.id,
              where: r.state in [:waiting, :claimed],
              select: r.environment_ref
          )

        assert live == ["env-0"]
        end_round!(round)
      end
    end

    test "and a close of its work item at once: the run ends closed once, never taken", ctx do
      pool = pool_fixture(ctx.scope)
      key = key!(ctx, pool)

      for n <- 1..4 do
        round = build_claimed!(ctx, key, "acme/close-#{n}")
        work_item = Repo.get!(WorkItem, round.run.work_item_id)

        [closed, claimed] =
          together([
            fn -> Apiary.WorkItems.close(ctx.scope, work_item) end,
            fn -> Dispatches.claim(key, Dispatches.now()) end
          ])

        assert {:ok, %WorkItem{state: :closed}} = closed
        assert {:ok, :none} = claimed

        assert %DispatchRun{state: :ended, end_cause: :closed} =
                 Repo.get!(DispatchRun, round.run.id)

        end_round!(round)
      end
    end
  end
end
