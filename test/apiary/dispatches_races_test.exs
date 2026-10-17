defmodule Apiary.DispatchesRacesTest do
  # Claims racing each other (`Apiary.Dispatches.claim/3`), each on a separate
  # connection, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to every other
  # test while they run, and they delete it again before they end; the ledger and the
  # adapters, which outlive an organisation, by what they made.
  #
  # The rules under test: a claim locks its pool's row `FOR UPDATE` before it counts the
  # pool's slots, so two claims of one pool take turns and the second counts the first;
  # and it takes the oldest waiting run `FOR UPDATE SKIP LOCKED`, so two claims, of one
  # pool or of two, never take one run. One prebuild waits per collection and node pool:
  # two triggers at once take turns on the environment record, two queues at once on the
  # index of the waiting ones, and a lapse that would make a claimed prebuild wait again
  # waits for a trigger that holds the record.
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
  defp collection!(ctx) do
    connection = ticket_connection_fixture(ctx.scope)
    Agent.update(ctx.made, &%{&1 | adapters: [connection.adapter_id | &1.adapters]})

    Repo.insert!(%Collection{
      public_id: Apiary.PublicId.generate(Collection.prefix()),
      organisation_id: ctx.scope.organisation.id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      workspace_id: ctx.scope.workspace.id,
      external_ref: "SHOP",
      url: "https://code.example.com/acme/shop",
      title: "shop",
      target_system: "code.example.com",
      target_path: "acme/shop",
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

  # The prebuilds of `collection`, `{state, environment_ref}`, the oldest first.
  defp prebuilds(collection) do
    Repo.all(
      from r in DispatchRun,
        where: r.source_collection_id == ^collection.id,
        order_by: [asc: r.queued_at, asc: r.id],
        select: {r.state, r.environment_ref}
    )
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
      {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now(), 2)

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
  end
end
