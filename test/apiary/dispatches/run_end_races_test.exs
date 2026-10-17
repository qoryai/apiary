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
  # is freed once, by the first end, and none of them deadlocks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Dispatches, Repo}
  alias Apiary.AccessKeys.PublicKey
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunEnd, Slots}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Liveness, Run}
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
