defmodule Apiary.Dispatches.HandoverRacesTest do
  # The handover of a claimed run of the queue (`Apiary.Dispatches.Handover`) racing
  # another handover, the release, the lapse of the lease and the sweep, a close and an
  # undo of its work item, each on a separate connection, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they
  # delete it again before they end; the adapters and the keys' public halves, which
  # outlive an organisation, by what they made.
  #
  # The rules under test: a handover frees what lapsed of its run first, then locks the
  # run of the queue, then its dispatch, as every end and the sweep lock them; so a
  # handover and any of them take turns, whoever comes second finds what the first
  # wrote, one run is registered at most, the slot is held by a run handed over and freed
  # once by any other end, and none deadlocks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Edition, Repo, WorkItems}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    started = DateTime.utc_now()
    %{scope: scope} = sign_up()
    {:ok, made} = Agent.start(fn -> [] end)
    place = handover_place_fixture(scope)
    {gateway_key, _seed} = place.gateway_key

    # Before the clean up of `setup_races`: the organisation, then what outlives it, the
    # adapters the work items and collections came through, the keys' public halves and
    # the entries their adapters left in the instance's trail.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      adapters = Agent.get(made, & &1)
      Agent.stop(made)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)

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

      Sandbox.checkin(Repo)
    end)

    Map.merge(place, %{scope: scope, made: made})
  end

  defp made!(ctx, adapter_id), do: Agent.update(ctx.made, &[adapter_id | &1])

  # A run of the queue of a fresh work item, claimed and said started: committed.
  defp started!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    made!(ctx, work_item.adapter_id)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = dispatched!(ctx.key)
    assert dispatch.dispatch_run_id == queued.id
    %{work_item: work_item, dispatch_run: queued, dispatch: dispatch}
  end

  # A prebuild of a fresh collection, claimed and said started: committed.
  defp prebuild_started!(ctx) do
    collection = collection_fixture(ctx.scope)
    made!(ctx, collection.adapter_id)

    {:ok, queued} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    %{dispatch: dispatch} = dispatched!(ctx.key)
    assert dispatch.dispatch_run_id == queued.id
    %{collection: collection, dispatch_run: queued, dispatch: dispatch}
  end

  defp handover(ctx, %{dispatch: dispatch}),
    do: fn -> handover_now(ctx, dispatch) end

  defp handover_now(ctx, dispatch),
    do: Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})

  # The release after the handover, inside the transaction it is given or its own.
  defp release(%{dispatch_run: %DispatchRun{id: id}}),
    do: fn -> Dispatches.end_run_released(id, Dispatches.now()) end

  defp sweep(at), do: fn -> Dispatches.sweep(at) end

  # A person's close of the work item, as the page has it: the work item held, then
  # closed.
  defp close(ctx, %{work_item: %WorkItem{id: id}}) do
    fn ->
      Repo.transact(fn ->
        work_item = Repo.one!(from w in WorkItem, where: w.id == ^id, lock: "FOR UPDATE")
        WorkItems.close_locked([work_item], {:person, ctx.scope.user.id}, Dispatches.now())
      end)
    end
  end

  # The undo's part of the queue, inside the transaction it is given or its own.
  defp undo(%{work_item: work_item}), do: fn -> Dispatches.cancel_for_undo(work_item) end

  # Past the lease of the dispatch, as the clock would have it ten minutes and more after
  # its claim: committed.
  defp lapse!(%{dispatch: %Dispatch{id: id}}) do
    now = DateTime.utc_now()

    lease_until = %{
      DateTime.truncate(DateTime.add(now, -60, :second), :second)
      | microsecond: {0, 6}
    }

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [claimed_at: DateTime.add(now, -700, :second), lease_until: lease_until]
      )
  end

  defp after_lease(%{dispatch: %Dispatch{lease_until: lease_until}}),
    do: DateTime.add(lease_until, 1, :second)

  defp runs(%{dispatch_run: %DispatchRun{id: id}}),
    do: Repo.all(from r in Run, where: r.dispatch_run_id == ^id)

  defp entries(%{dispatch: %Dispatch{public_id: public_id}}) do
    Repo.all(
      from e in Entry,
        where: e.action == "dispatch.handover",
        where: fragment("?->>'dispatch_id'", e.details) == ^public_id
    )
  end

  # The run handed over once: one run registered, one entry, the slot held.
  defp handed_over!(ctx, claimed) do
    assert %DispatchRun{state: :handed_over, end_cause: nil} =
             Repo.get!(DispatchRun, claimed.dispatch_run.id)

    assert %Dispatch{handed_over_at: %DateTime{}, ended_at: nil, slot_freed_at: nil} =
             Repo.get!(Dispatch, claimed.dispatch.id)

    assert [%Run{}] = runs(claimed)
    assert Slots.held(ctx.pool.id) == 1
  end

  # The run of the queue and its dispatch ended with `cause`, never handed over, no run
  # registered, the slot freed once, at the dispatch's end.
  defp ended!(ctx, claimed, cause, dispatch_cause \\ nil) do
    assert %DispatchRun{state: :ended, end_cause: ^cause} =
             Repo.get!(DispatchRun, claimed.dispatch_run.id)

    dispatch_cause = dispatch_cause || cause

    assert %Dispatch{
             end_cause: ^dispatch_cause,
             handed_over_at: nil,
             ended_at: %DateTime{} = ended_at,
             slot_freed_at: freed_at
           } = Repo.get!(Dispatch, claimed.dispatch.id)

    assert freed_at && DateTime.compare(freed_at, ended_at) != :gt
    assert runs(claimed) == []
    assert Slots.held(ctx.pool.id) == 0
  end

  describe "two handovers" do
    test "at once: one hands the run over, the others are handed_over", ctx do
      for _round <- 1..3 do
        claimed = started!(ctx)
        answers = together(List.duplicate(handover(ctx, claimed), sides(3)))

        assert Enum.count(answers, &match?({:ok, _handed}, &1)) == 1
        assert Enum.all?(answers, &(match?({:ok, _handed}, &1) or &1 == {:error, :handed_over}))
        handed_over!(ctx, claimed)

        # The next round's claim finds the slot free again.
        {:ok, _released} = Repo.transact(release(claimed))
      end
    end

    test "the first holds the run: the second waits, then is handed_over", ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(handover(ctx, claimed))
      assert {:ok, %{run: %Run{}}} = first.result

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :handed_over}
      handed_over!(ctx, claimed)
      assert length(entries(claimed)) == 1
    end
  end

  describe "a handover and the release" do
    test "the handover first: the release waits, then ends the run it handed over, released",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(handover(ctx, claimed))
      assert {:ok, %{run: run}} = first.result

      second = start(fn -> Repo.transact(release(claimed)) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %{run: %Run{state: "cancelled"}}} = Task.await(second.task)

      assert %DispatchRun{state: :ended, end_cause: :released} =
               Repo.get!(DispatchRun, claimed.dispatch_run.id)

      assert %Dispatch{end_cause: :released, slot_freed_at: %DateTime{}} =
               Repo.get!(Dispatch, claimed.dispatch.id)

      assert [%Run{id: id, released_at: %DateTime{}}] = runs(claimed)
      assert id == run.id
      assert Slots.held(ctx.pool.id) == 0

      # A handover after the release finds the dispatch ended.
      assert handover_now(ctx, claimed.dispatch) == {:error, :gone}
    end

    test "the release first, before the handover: it is not_handed_over, and the handover waits, then hands the run over",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(release(claimed))
      assert first.result == {:error, :not_handed_over}

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %{run: %Run{}}} = Task.await(second.task)
      handed_over!(ctx, claimed)
    end
  end

  describe "a handover and the lapse of its lease" do
    test "the sweep first: the handover waits, then is lease_expired, the run waiting again",
         ctx do
      claimed = started!(ctx)
      lapse!(claimed)

      {first, first_pid} = hold(sweep(DateTime.utc_now()))
      assert ctx.scope.workspace.id in first.result

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :lease_expired}

      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, claimed.dispatch_run.id)

      assert %Dispatch{stale_at: %DateTime{}, handed_over_at: nil, slot_freed_at: %DateTime{}} =
               Repo.get!(Dispatch, claimed.dispatch.id)

      assert runs(claimed) == []
      assert Slots.held(ctx.pool.id) == 0
    end

    test "the handover first: the sweep after the lease waits, and leaves the run handed over",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(handover(ctx, claimed))
      assert {:ok, %{run: %Run{}}} = first.result

      second = start(sweep(after_lease(claimed)))
      await_blocked(second.backend, first_pid)
      commit(first)

      Task.await(second.task)
      handed_over!(ctx, claimed)
    end

    test "a lapsed prebuild superseded by the sweep: the handover waits, then is gone", ctx do
      claimed = prebuild_started!(ctx)

      # Another prebuild of the collection and pool waits while the first is claimed.
      {:ok, _waiting} =
        Repo.transact(fn ->
          Dispatches.queue_prebuild(claimed.collection, ctx.pool, "env-2")
        end)

      lapse!(claimed)

      {first, first_pid} = hold(sweep(DateTime.utc_now()))
      assert ctx.scope.workspace.id in first.result

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      ended!(ctx, claimed, :superseded, :run_ended)
    end

    test "a lapsed prebuild: the handover and the sweep at once, none deadlocks", ctx do
      for _round <- 1..3 do
        claimed = prebuild_started!(ctx)

        {:ok, _waiting} =
          Repo.transact(fn ->
            Dispatches.queue_prebuild(claimed.collection, ctx.pool, "env-2")
          end)

        lapse!(claimed)

        [handed, _swept] =
          together([handover(ctx, claimed), sweep(DateTime.utc_now())])

        assert handed == {:error, :gone}
        ended!(ctx, claimed, :superseded, :run_ended)

        # The prebuild that waits ends, so the next round's claim takes its own.
        {:ok, :ok} =
          Repo.transact(fn ->
            {:ok, Dispatches.end_waiting_prebuilds([claimed.collection.id], Dispatches.now())}
          end)
      end
    end
  end

  describe "a handover and a close of its work item" do
    test "the close first: the handover waits, then is gone, the run ended closed", ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(close(ctx, claimed))
      assert {:ok, _changed} = first.result

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      ended!(ctx, claimed, :closed)
    end

    test "the handover first: the close waits, then closes the work item and leaves the run handed over",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(handover(ctx, claimed))
      assert {:ok, %{run: %Run{}}} = first.result

      second = start(close(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _changed} = Task.await(second.task)
      assert %WorkItem{state: :closed} = Repo.get!(WorkItem, claimed.work_item.id)
      handed_over!(ctx, claimed)
    end
  end

  describe "a handover and an undo of its work item" do
    test "the handover first: the undo waits, then is refused, the run claimed", ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(handover(ctx, claimed))
      assert {:ok, %{run: %Run{}}} = first.result

      second = start(fn -> Repo.transaction(undo(claimed)) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:ok, {:error, :claimed}}
      handed_over!(ctx, claimed)
    end

    test "the undo first: it is refused, and the handover waits, then hands the run over",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(undo(claimed))
      assert first.result == {:error, :claimed}

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %{run: %Run{}}} = Task.await(second.task)
      handed_over!(ctx, claimed)
    end
  end

  test "everything at once: one end or the handover decides, the slot is freed or held once, and none deadlocks",
       ctx do
    for _round <- 1..3 do
      claimed = started!(ctx)

      sides = [
        fn -> {:handover, handover(ctx, claimed).()} end,
        fn -> {:handover, handover(ctx, claimed).()} end,
        fn -> {:close, close(ctx, claimed).()} end,
        fn -> {:sweep, sweep(DateTime.utc_now()).()} end,
        fn -> {:undo, Repo.transaction(undo(claimed))} end
      ]

      answers = together(Enum.take(sides, sides(length(sides))))
      handovers = for {:handover, answer} <- answers, do: answer
      assert Enum.count(handovers, &match?({:ok, _handed}, &1)) <= 1

      case Repo.get!(DispatchRun, claimed.dispatch_run.id) do
        %DispatchRun{state: :handed_over} ->
          assert Enum.count(handovers, &match?({:ok, _handed}, &1)) == 1

          assert Enum.all?(
                   handovers,
                   &(match?({:ok, _handed}, &1) or &1 == {:error, :handed_over})
                 )

          handed_over!(ctx, claimed)
          assert length(entries(claimed)) == 1
          {:ok, _released} = Repo.transact(release(claimed))

        %DispatchRun{state: :ended} ->
          assert Enum.all?(handovers, &(&1 == {:error, :gone}))
          ended!(ctx, claimed, :closed)
      end

      assert Slots.held(ctx.pool.id) == 0
    end
  end
end
