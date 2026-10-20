defmodule Apiary.Dispatches.ReleaseRacesTest do
  # The release of a claimed run of the queue (`Apiary.Dispatches.Release`) racing
  # another release, the handover, the starter's outcome, the lapse of the lease and the
  # sweep, a close of its work item and a trigger of its collection, each on a separate
  # connection, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end; the
  # adapters and the keys' public halves, which outlive an organisation, by what they
  # made.
  #
  # The rules under test: a release holds its run's work item or environment record
  # first, then frees what lapsed of its run, then locks the run of the queue, then its
  # dispatch, as every end, the handover and the sweep lock them; so a release and any of
  # them take turns, whoever comes second finds what the first wrote, one release acts,
  # one next run is queued at most, the slot is freed once, and none deadlocks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Edition, Environments, Repo, WorkItems}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
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

  # A prebuild of a fresh collection, with the pool's environment record of it, claimed
  # and said started: committed.
  defp prebuild_started!(ctx) do
    collection = collection_fixture(ctx.scope)
    made!(ctx, collection.adapter_id)

    record =
      Repo.insert!(%Record{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        pool_id: ctx.pool.id,
        source_collection_id: collection.id,
        queued_ref: "env-1",
        queued_at: DateTime.utc_now()
      })

    {:ok, queued} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    %{dispatch: dispatch} = dispatched!(ctx.key)
    assert dispatch.dispatch_run_id == queued.id
    %{collection: collection, record: record, dispatch_run: queued, dispatch: dispatch}
  end

  defp release(ctx, claimed, retry),
    do: fn -> release_now(ctx, claimed, retry) end

  defp release_now(ctx, %{dispatch: dispatch}, retry) do
    Dispatches.release(ctx.key, dispatch.public_id, %{
      reason: "The job could not start.",
      retry: retry
    })
  end

  defp handover(ctx, %{dispatch: dispatch}) do
    fn ->
      Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})
    end
  end

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

  defp entries(%{dispatch: %Dispatch{public_id: public_id}}) do
    Repo.all(
      from e in Entry,
        where: e.action == "dispatch.release",
        where: fragment("?->>'dispatch_id'", e.details) == ^public_id
    )
  end

  defp runs_of(%{work_item: %WorkItem{id: id}}),
    do: Repo.all(from r in DispatchRun, where: r.work_item_id == ^id, order_by: r.attempt)

  defp queue_run!(claimed), do: Repo.get!(DispatchRun, claimed.dispatch_run.id)
  defp dispatch!(claimed), do: Repo.get!(Dispatch, claimed.dispatch.id)

  # The dispatch released once: ended `released`, the slot freed once, one entry.
  defp released!(ctx, claimed) do
    assert %Dispatch{end_cause: :released, ended_at: %DateTime{}, slot_freed_at: %DateTime{}} =
             dispatch!(claimed)

    assert length(entries(claimed)) == 1
    assert Slots.held(ctx.pool.id) == 0
  end

  # Ends what waits of the work item's take in, so the next round's claim takes the run
  # that round queues.
  defp end_waiting!(claimed) do
    {_count, _rows} =
      Repo.update_all(
        from(r in DispatchRun,
          where: r.work_item_id == ^claimed.work_item.id,
          where: fragment("? = 'waiting'", r.state)
        ),
        set: [state: :ended, end_cause: :undone]
      )
  end

  describe "two releases" do
    test "before the handover, at once: one acts, the others are gone", ctx do
      for _round <- 1..3 do
        claimed = started!(ctx)
        answers = together(List.duplicate(release(ctx, claimed, true), sides(3)))

        assert Enum.count(answers, &(&1 == :ok)) == 1
        assert Enum.all?(answers, &(&1 == :ok or &1 == {:error, :gone}))
        assert queue_run!(claimed).state == :waiting
        released!(ctx, claimed)
        end_waiting!(claimed)
      end
    end

    test "after the handover, at once, with retry: one acts and one next run is queued",
         ctx do
      for _round <- 1..3 do
        claimed = started!(ctx)
        {:ok, _handed} = handover(ctx, claimed).()
        answers = together(List.duplicate(release(ctx, claimed, true), sides(3)))

        assert Enum.count(answers, &(&1 == :ok)) == 1
        assert Enum.all?(answers, &(&1 == :ok or &1 == {:error, :gone}))
        assert [%{state: :ended}, %{attempt: 2, state: :waiting}] = runs_of(claimed)
        released!(ctx, claimed)
        end_waiting!(claimed)
      end
    end
  end

  describe "a release and the handover" do
    test "the handover first: the release waits, then ends the run handed over and queues the next",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(handover(ctx, claimed))
      assert {:ok, %{run: run}} = first.result

      second = start(release(ctx, claimed, true))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(claimed)
      assert %Run{state: "cancelled", released_at: %DateTime{}} = Repo.get!(Run, run.id)
      assert [_first, %{attempt: 2, state: :waiting}] = runs_of(claimed)
      released!(ctx, claimed)
      assert [%Entry{subject_kind: "run"}] = entries(claimed)
    end

    test "the release first: the handover waits, then is gone", ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(release(ctx, claimed, true))
      assert first.result == :ok

      second = start(handover(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      assert queue_run!(claimed).state == :waiting
      assert Repo.all(from r in Run, where: r.dispatch_run_id == ^claimed.dispatch_run.id) == []
      released!(ctx, claimed)
    end
  end

  describe "a release and the starter's outcome" do
    test "the outcome first: the release waits, then is gone, and writes nothing", ctx do
      claimed = started!(ctx)
      {:ok, %{run: run}} = handover(ctx, claimed).()
      run = Repo.get!(Run, run.id)

      {first, first_pid} =
        hold(fn ->
          Repo.transact(fn -> {:ok, give_outcome(ctx.key, run, "succeeded")} end)
        end)

      assert {:ok, {:ok, _given}} = first.result

      second = start(release(ctx, claimed, true))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      assert %DispatchRun{end_cause: :run_ended} = queue_run!(claimed)
      assert [_only] = runs_of(claimed)
      assert entries(claimed) == []
    end
  end

  describe "a release and the lapse of its lease" do
    test "the sweep first: the release waits, then is lease_expired, the run waiting again",
         ctx do
      claimed = started!(ctx)
      lapse!(claimed)

      {first, first_pid} = hold(sweep(DateTime.utc_now()))
      assert ctx.scope.workspace.id in first.result

      second = start(release(ctx, claimed, false))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :lease_expired}
      assert queue_run!(claimed).state == :waiting
      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} = dispatch!(claimed)
      assert entries(claimed) == []
    end

    test "the release first: the sweep after the lease waits, and frees nothing again", ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(release(ctx, claimed, false))
      assert first.result == :ok

      second = start(sweep(DateTime.add(claimed.dispatch.lease_until, 1, :second)))
      await_blocked(second.backend, first_pid)
      commit(first)

      Task.await(second.task)
      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(claimed)
      assert %Dispatch{stale_at: nil} = dispatch!(claimed)
      released!(ctx, claimed)
    end
  end

  describe "a release and a close of its work item" do
    test "the close first: the release waits on the work item, then is gone", ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(close(ctx, claimed))
      assert {:ok, _changed} = first.result

      second = start(release(ctx, claimed, true))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      assert %DispatchRun{state: :ended, end_cause: :closed} = queue_run!(claimed)
      assert entries(claimed) == []
    end

    test "the release first, with retry: the close waits, then ends the run waiting again",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(release(ctx, claimed, true))
      assert first.result == :ok

      second = start(close(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _changed} = Task.await(second.task)
      assert %DispatchRun{state: :ended, end_cause: :closed} = queue_run!(claimed)
      released!(ctx, claimed)
    end

    test "after the handover, the close first: the release waits, then queues nothing", ctx do
      claimed = started!(ctx)
      {:ok, _handed} = handover(ctx, claimed).()

      {first, first_pid} = hold(close(ctx, claimed))
      assert {:ok, _changed} = first.result

      second = start(release(ctx, claimed, true))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert [%{end_cause: :released}] = runs_of(claimed)
      released!(ctx, claimed)
    end
  end

  describe "a release of a prebuild and a trigger of its collection" do
    test "the trigger first: the release waits on the record, then is superseded by the run the trigger queued",
         ctx do
      claimed = prebuild_started!(ctx)

      {first, first_pid} = hold(trigger(claimed, "env-2"))
      assert {:ok, [%DispatchRun{} = queued]} = first.result

      second = start(release(ctx, claimed, true))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert %DispatchRun{state: :ended, end_cause: :superseded} = queue_run!(claimed)

      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} =
               Repo.get!(DispatchRun, queued.id)

      released!(ctx, claimed)
    end

    test "the release first: the trigger waits on the record, then sets its ref on the run that waits again",
         ctx do
      claimed = prebuild_started!(ctx)

      {first, first_pid} = hold(release(ctx, claimed, true))
      assert first.result == :ok

      second = start(trigger(claimed, "env-2"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, [%DispatchRun{id: id}]} = Task.await(second.task)
      assert id == claimed.dispatch_run.id

      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} = queue_run!(claimed)
      released!(ctx, claimed)
    end

    test "at once, with the sweep, none deadlocks", ctx do
      for round <- 1..3 do
        claimed = prebuild_started!(ctx)

        [released, _triggered, _swept] =
          together([
            release(ctx, claimed, true),
            trigger(claimed, "env-#{round + 1}"),
            sweep(DateTime.utc_now())
          ])

        assert released == :ok
        released!(ctx, claimed)

        assert [%DispatchRun{environment_ref: ref}] =
                 Repo.all(
                   from r in DispatchRun,
                     where: r.source_collection_id == ^claimed.collection.id,
                     where: fragment("? = 'waiting'", r.state)
                 )

        assert ref == "env-#{round + 1}"

        {:ok, :ok} =
          Repo.transact(fn ->
            {:ok, Dispatches.end_waiting_prebuilds([claimed.collection.id], Dispatches.now())}
          end)
      end
    end
  end

  test "everything at once: one release or end decides, one next run at most, and none deadlocks",
       ctx do
    for _round <- 1..3 do
      claimed = started!(ctx)

      sides = [
        fn -> {:release, release(ctx, claimed, true).()} end,
        fn -> {:release, release(ctx, claimed, false).()} end,
        fn -> {:handover, handover(ctx, claimed).()} end,
        fn -> {:close, close(ctx, claimed).()} end,
        fn -> {:sweep, sweep(DateTime.utc_now()).()} end
      ]

      answers = together(Enum.take(sides, sides(length(sides))))
      releases = for {:release, answer} <- answers, do: answer

      assert Enum.count(releases, &(&1 == :ok)) <= 1
      assert length(entries(claimed)) == Enum.count(releases, &(&1 == :ok))
      assert Enum.count(runs_of(claimed), &(&1.attempt == 2)) <= 1

      # Whatever came first, nothing is left holding the slot, but a run handed over.
      case queue_run!(claimed) do
        %DispatchRun{state: :handed_over} ->
          {:ok, _released} =
            Repo.transact(fn ->
              Dispatches.end_run_released(claimed.dispatch_run.id, Dispatches.now())
            end)

        _waiting_or_ended ->
          :ok
      end

      end_waiting!(claimed)
      assert Slots.held(ctx.pool.id) == 0
    end
  end
end
