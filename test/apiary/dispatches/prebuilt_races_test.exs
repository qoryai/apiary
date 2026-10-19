defmodule Apiary.Dispatches.PrebuiltRacesTest do
  # The prebuilt of a prebuild handed over (`Apiary.Dispatches.Prebuilt`) racing a release
  # of its dispatch, the lapse of its lease and the sweep, a second prebuilt, the
  # collection's `environment_ref` going absent and the collection ending, each on a
  # separate connection, outside the SQL sandbox, so each commits and each waits on the
  # other's locks as it would in production. Not async: what these tests commit is
  # visible to every other test while they run, and they delete it again before they end;
  # the adapters and the keys' public halves, which outlive an organisation, by what they
  # made.
  #
  # The rules under test: a prebuilt holds its prebuild's environment record first, then
  # frees what lapsed of its run, then locks the run of the queue, then its dispatch, as a
  # release, the handover, the sweep and the trigger lock them; so a prebuilt and any of
  # them take turns, whoever comes second finds what the first wrote, one prebuilt or
  # release acts, the build is recorded at most once, the slot is freed once, and none
  # deadlocks. A prebuilt or a release of a prebuild queued before the one that made the
  # recorded image, after that one's prebuilt, leaves the record as it is.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.RunEventsFixtures

  alias Apiary.{Dispatches, Edition, Environments, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Projector, Run}
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
    # adapters the collections came through, the keys' public halves and the entries
    # their adapters left in the instance's trail.
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

  # A prebuild of a fresh collection, queued by the trigger with the pool's environment
  # record of it, claimed and said started: committed.
  defp started!(ctx) do
    collection = collection_fixture(ctx.scope)
    Agent.update(ctx.made, &[collection.adapter_id | &1])

    {:ok, [queued]} =
      Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

    %{dispatch: dispatch} = dispatched!(ctx.key)
    assert dispatch.dispatch_run_id == queued.id
    %{collection: collection, dispatch_run: queued, dispatch: dispatch}
  end

  # The same, handed over: committed, with the registered run.
  defp handed_over!(ctx) do
    claimed = started!(ctx)
    {:ok, %{run: run}} = handover(ctx, claimed).()
    Map.put(claimed, :run, run)
  end

  defp handover(ctx, %{dispatch: dispatch}) do
    fn -> Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body}) end
  end

  defp prebuilt(ctx, %{dispatch: dispatch, dispatch_run: queued}, attrs \\ %{}) do
    fn -> Dispatches.prebuilt(ctx.key, dispatch.public_id, prebuilt_meta(queued, attrs)) end
  end

  defp release(ctx, %{dispatch: dispatch}) do
    fn ->
      Dispatches.release(ctx.key, dispatch.public_id, %{
        reason: "The build failed.",
        retry: false
      })
    end
  end

  defp sweep(at), do: fn -> Dispatches.sweep(at) end

  # The collection's `environment_ref` gone, triggered as a listing does.
  defp absent(%{collection: %Collection{id: id}}) do
    fn ->
      Repo.transact(fn ->
        {1, _rows} =
          Repo.update_all(from(c in Collection, where: c.id == ^id),
            set: [environment_ref: nil]
          )

        {:ok, Environments.trigger([Repo.get!(Collection, id)], Dispatches.now())}
      end)
    end
  end

  # The collection ended, as its adapter's disconnect ends it: its row held, then ended.
  defp ended(%{collection: %Collection{id: id}}) do
    fn ->
      Repo.transact(fn ->
        _held = Repo.one!(from c in Collection, where: c.id == ^id, lock: "FOR UPDATE")
        now = DateTime.utc_now()

        {1, _rows} =
          Repo.update_all(from(c in Collection, where: c.id == ^id),
            set: [ended_at: now, ended_reason: :disconnected, updated_at: now]
          )

        {:ok, :ended}
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

  defp entries(%{dispatch: %Dispatch{public_id: public_id}}, action) do
    Repo.all(
      from e in Entry,
        where: e.action == ^action,
        where: fragment("?->>'dispatch_id'", e.details) == ^public_id
    )
  end

  defp queue_run!(claimed), do: Repo.get!(DispatchRun, claimed.dispatch_run.id)
  defp dispatch!(claimed), do: Repo.get!(Dispatch, claimed.dispatch.id)
  defp record!(ctx, claimed), do: Environments.fetch(ctx.pool.id, claimed.collection.id)

  # The run of the queue ended once, its slot freed once: `released` by the release that
  # acted, the registered run cancelled; else `prebuilt` by the prebuilt that acted, the
  # registered run not cancelled and with no released_at.
  defp ended_once!(ctx, claimed) do
    released? = entries(claimed, "dispatch.release") != []
    cause = if released?, do: :released, else: :prebuilt

    assert %DispatchRun{state: :ended, end_cause: ^cause} = queue_run!(claimed)

    assert %Dispatch{end_cause: ^cause, ended_at: %DateTime{}, slot_freed_at: %DateTime{}} =
             dispatch!(claimed)

    assert Slots.held(ctx.pool.id) == 0
    run = Repo.get!(Run, claimed.run.id)

    if released?,
      do: assert(%Run{state: "cancelled", released_at: %DateTime{}} = run),
      else: assert(%Run{released_at: nil, outcome_state: nil} = run)
  end

  # The build recorded, once, with no failure.
  defp recorded!(ctx, claimed) do
    assert %Record{image: image, failure_cause: nil, reported_ref: "env-1"} =
             record!(ctx, claimed)

    assert is_binary(image)
    assert length(entries(claimed, "dispatch.prebuilt")) == 1
    assert entries(claimed, "dispatch.release") == []
  end

  describe "a prebuilt and a release" do
    test "the release first: the prebuilt waits on the record, then is gone, and the failure stays",
         ctx do
      claimed = handed_over!(ctx)

      {first, first_pid} = hold(release(ctx, claimed))
      assert first.result == :ok

      second = start(prebuilt(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      ended_once!(ctx, claimed)

      assert %Record{image: nil, failure_cause: :released, failure_reason: "The build failed."} =
               record!(ctx, claimed)

      assert entries(claimed, "dispatch.prebuilt") == []
    end

    test "the prebuilt first: the release waits on the record, then is gone, and the build stays",
         ctx do
      claimed = handed_over!(ctx)

      {first, first_pid} = hold(prebuilt(ctx, claimed))
      assert first.result == :ok

      second = start(release(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :gone}
      ended_once!(ctx, claimed)
      recorded!(ctx, claimed)
    end
  end

  describe "a prebuild whose ref is older than the recorded image's" do
    defp commit!(ctx, claimed), do: record!(ctx, claimed).commit

    test "the newer prebuilt first: the older one's waits on the record, then ends its run and leaves the image",
         ctx do
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      {first, first_pid} = hold(prebuilt(ctx, newer, commit: "b2"))
      assert first.result == :ok

      second = start(prebuilt(ctx, older, commit: "a1"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert commit!(ctx, older) == "b2"

      assert DateTime.compare(
               record!(ctx, older).built_queued_at,
               newer.dispatch_run.environment_ref_at
             ) ==
               :eq

      ended_once!(ctx, older)
      ended_once!(ctx, newer)
      assert entries(older, "dispatch.prebuilt") == []
      assert length(entries(newer, "dispatch.prebuilt")) == 1
    end

    test "the older prebuilt first: the newer one's waits on the record, then replaces the image",
         ctx do
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      {first, first_pid} = hold(prebuilt(ctx, older, commit: "a1"))
      assert first.result == :ok

      second = start(prebuilt(ctx, newer, commit: "b2"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert commit!(ctx, older) == "b2"

      assert DateTime.compare(
               record!(ctx, older).built_queued_at,
               newer.dispatch_run.environment_ref_at
             ) ==
               :eq

      ended_once!(ctx, older)
      ended_once!(ctx, newer)
      assert length(entries(older, "dispatch.prebuilt")) == 1
      assert length(entries(newer, "dispatch.prebuilt")) == 1
    end

    test "the newer prebuilt first: the older one's release waits on the record, then ends its run and records no failure",
         ctx do
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      {first, first_pid} = hold(prebuilt(ctx, newer, commit: "b2"))
      assert first.result == :ok

      second = start(release(ctx, older))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert %Record{commit: "b2", failure_cause: nil} = record!(ctx, older)
      ended_once!(ctx, older)
      ended_once!(ctx, newer)
    end

    test "the older one's release first: the newer prebuilt waits on the record, then records its build and clears the failure",
         ctx do
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      {first, first_pid} = hold(release(ctx, older))
      assert first.result == :ok

      second = start(prebuilt(ctx, newer, commit: "b2"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      assert %Record{commit: "b2", failure_cause: nil} = record!(ctx, older)
      ended_once!(ctx, older)
      ended_once!(ctx, newer)
    end
  end

  describe "a prebuilt and the run's end" do
    test "the projection of its exit at once: the prebuilt records the build, and the run of the queue ends prebuilt",
         ctx do
      for _round <- 1..3 do
        claimed = handed_over!(ctx)

        event_fixture(claimed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

        [recorded, projected] =
          together([prebuilt(ctx, claimed), fn -> Projector.project(claimed.run) end])

        assert recorded == :ok
        assert {:ok, %Run{exited_at: %DateTime{}}} = projected
        ended_once!(ctx, claimed)
        recorded!(ctx, claimed)
      end
    end

    test "its starter's outcome at once: one ends the run of the queue, and the build is recorded or failed lost, never both",
         ctx do
      for _round <- 1..3 do
        claimed = handed_over!(ctx)

        [recorded, given] =
          together([
            prebuilt(ctx, claimed),
            fn -> give_outcome(ctx.key, claimed.run, "failed") end
          ])

        assert {:ok, %{repeated: false}} = given
        assert Slots.held(ctx.pool.id) == 0
        record = record!(ctx, claimed)

        case recorded do
          :ok ->
            assert %DispatchRun{end_cause: :prebuilt} = queue_run!(claimed)
            assert is_binary(record.image) and is_nil(record.failure_cause)
            assert length(entries(claimed, "dispatch.prebuilt")) == 1

          {:error, :gone} ->
            assert %DispatchRun{end_cause: :run_ended} = queue_run!(claimed)
            assert is_nil(record.image) and record.failure_cause == :lost
            assert entries(claimed, "dispatch.prebuilt") == []
        end

        assert %Run{outcome_state: "failed", released_at: nil} = Repo.get!(Run, claimed.run.id)
      end
    end
  end

  describe "two prebuilts" do
    test "at once: one acts and records the build once, the others are gone", ctx do
      for round <- 1..3 do
        claimed = handed_over!(ctx)

        answers =
          together(
            for side <- 1..sides(3),
                do: prebuilt(ctx, claimed, commit: "commit-#{round}-#{side}")
          )

        assert Enum.count(answers, &(&1 == :ok)) == 1
        assert Enum.all?(answers, &(&1 == :ok or &1 == {:error, :gone}))
        ended_once!(ctx, claimed)
        recorded!(ctx, claimed)

        # The commit kept is the one of the prebuilt that acted.
        [entry] = entries(claimed, "dispatch.prebuilt")
        assert record!(ctx, claimed).commit == entry.details["commit"]
      end
    end
  end

  describe "a prebuilt and the lapse of its lease" do
    test "the sweep first, before the handover: the prebuilt waits, then is lease_expired",
         ctx do
      claimed = started!(ctx)
      lapse!(claimed)

      {first, first_pid} = hold(sweep(DateTime.utc_now()))
      assert ctx.scope.workspace.id in first.result

      second = start(prebuilt(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :lease_expired}
      assert queue_run!(claimed).state == :waiting
      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} = dispatch!(claimed)
      assert %Record{image: nil} = record!(ctx, claimed)
      assert entries(claimed, "dispatch.prebuilt") == []
    end

    test "the prebuilt first, before the handover: the sweep past the lease waits on the record, then lapses it",
         ctx do
      claimed = started!(ctx)

      {first, first_pid} = hold(prebuilt(ctx, claimed))
      assert first.result == {:error, :not_handed_over}

      second = start(sweep(DateTime.add(claimed.dispatch.lease_until, 1, :second)))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert ctx.scope.workspace.id in Task.await(second.task)
      assert queue_run!(claimed).state == :waiting
      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: %DateTime{}} = dispatch!(claimed)
      assert %Record{image: nil} = record!(ctx, claimed)
      assert entries(claimed, "dispatch.prebuilt") == []
    end

    test "the prebuilt first, after the handover: the sweep past the lease frees nothing again",
         ctx do
      claimed = handed_over!(ctx)
      assert prebuilt(ctx, claimed).() == :ok

      sweep(DateTime.add(claimed.dispatch.lease_until, 1, :second)).()
      ended_once!(ctx, claimed)
      assert %Dispatch{stale_at: nil} = dispatch!(claimed)
      recorded!(ctx, claimed)
    end
  end

  describe "a prebuilt and its collection" do
    test "the environment_ref gone first: the prebuilt waits on the record, then stores the build, retired",
         ctx do
      claimed = handed_over!(ctx)

      {first, first_pid} = hold(absent(claimed))
      assert {:ok, []} = first.result

      second = start(prebuilt(ctx, claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == :ok
      ended_once!(ctx, claimed)
      recorded!(ctx, claimed)
      assert %Record{retired_at: %DateTime{}} = record!(ctx, claimed)
    end

    test "the prebuilt first: the environment_ref gone waits on the record, then retires the build",
         ctx do
      claimed = handed_over!(ctx)

      {first, first_pid} = hold(prebuilt(ctx, claimed))
      assert first.result == :ok

      second = start(absent(claimed))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, []} = Task.await(second.task)
      ended_once!(ctx, claimed)
      recorded!(ctx, claimed)
      record = record!(ctx, claimed)
      assert DateTime.compare(record.retired_at, record.built_at) == :gt
    end

    test "the collection ended at once: both act, and the build is stored", ctx do
      for _round <- 1..3 do
        claimed = handed_over!(ctx)
        [recorded, ended] = together([prebuilt(ctx, claimed), ended(claimed)])

        assert recorded == :ok
        assert ended == {:ok, :ended}
        ended_once!(ctx, claimed)
        recorded!(ctx, claimed)
        assert %Collection{ended_at: %DateTime{}} = Repo.get!(Collection, claimed.collection.id)
      end
    end
  end

  test "everything at once: one prebuilt or release acts, the build at most once, and none deadlocks",
       ctx do
    for _round <- 1..3 do
      claimed = handed_over!(ctx)

      sides = [
        fn -> {:prebuilt, prebuilt(ctx, claimed).()} end,
        fn -> {:prebuilt, prebuilt(ctx, claimed, commit: "another").()} end,
        fn -> {:release, release(ctx, claimed).()} end,
        fn -> {:absent, absent(claimed).()} end,
        fn -> {:sweep, sweep(DateTime.utc_now()).()} end
      ]

      answers = together(Enum.take(sides, sides(length(sides))))
      acted = for {kind, :ok} <- answers, kind in [:prebuilt, :release], do: kind

      assert length(acted) == 1
      ended_once!(ctx, claimed)

      assert length(entries(claimed, "dispatch.prebuilt")) ==
               Enum.count(acted, &(&1 == :prebuilt))

      assert length(entries(claimed, "dispatch.release")) == Enum.count(acted, &(&1 == :release))

      record = record!(ctx, claimed)

      case acted do
        [:prebuilt] -> assert is_binary(record.image) and is_nil(record.failure_cause)
        [:release] -> assert is_nil(record.image) and record.failure_cause == :released
      end
    end
  end
end
