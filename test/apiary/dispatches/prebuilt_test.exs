defmodule Apiary.Dispatches.PrebuiltTest do
  # A node pool's starter reports the image a prebuild its pool claimed built
  # (`Apiary.Dispatches.Prebuilt`): each refusal in the contract's order, the lapse judged
  # and committed, nothing written on any refusal; on success the build recorded on the
  # claiming pool's record with the target the registered run was handed over for, the
  # reported ref as it is, the last failure cleared and the record kept retired by a
  # prebuild that took its ref before the retirement, the run ended as
  # a release after its handover with retry false ends it, nothing queued; a second
  # prebuilt and one after the run's outcome or exit, gone; a failure that writes nothing;
  # the one audit entry, about the registered run; and a prebuild queued before the one
  # that made the recorded image, whose prebuilt or release leaves the record as it is.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Environments, Repo}
  alias Apiary.Adapters.Collection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Runs.Run

  @moduletag needs: :factory

  @old_image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("0a1b", 16)

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  defp prebuilt(key, dispatch, meta), do: Dispatches.prebuilt(key, id(dispatch), meta)

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id), do: public_id

  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp record!(collection, pool), do: Environments.fetch(pool.id, collection.id)
  defp entries, do: Repo.all(from e in Entry, where: e.action == "dispatch.prebuilt")

  defp prebuilds(%Collection{id: id}),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id == ^id,
          order_by: r.queued_at,
          select: r.id
      )

  # A prebuild queued by the trigger, claimed and started, not handed over.
  defp started!(ctx, attrs \\ %{}) do
    collection = collection_fixture(ctx.scope, attrs)

    {:ok, _queued} =
      Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

    %{dispatch: dispatch, run: queued} = dispatched!(ctx.key)
    {collection, dispatch, queued}
  end

  defp handed_over!(ctx, attrs \\ %{}), do: prebuild_handed_over!(ctx.scope, ctx.key, attrs)

  # Past its lease, as the clock would have it ten minutes and more after the claim.
  defp lapse!(%Dispatch{id: id}) do
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

  defp unchanged(collection, dispatch, queued),
    do:
      {Environments.fetch(queued.pool_id, collection.id), dispatch!(dispatch), queue_run!(queued)}

  describe "on success" do
    test "records the build for the claiming pool, ends the run of the queue prebuilt, leaves the registered run to its outcome, and queues nothing",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued, run: run} =
        handed_over!(ctx)

      meta = prebuilt_meta(queued)
      assert prebuilt(ctx.key, dispatch, meta) == :ok

      record = record!(collection, ctx.pool)

      assert %Record{
               size: 734_003_200,
               commit: "9c1e4a7b2d5f8e0a3c6b9d2f5a8c1e4b7d0a3f6c",
               reported_ref: "env-1",
               queued_ref: "env-1",
               failure_cause: nil,
               retired_at: nil
             } = record

      assert record.image == meta.image

      assert {record.built_target_system, record.built_target_path} ==
               {collection.target_system, collection.target_path}

      assert {record.queued_target_system, record.queued_target_path} ==
               {collection.target_system, collection.target_path}

      # The run of the queue and its dispatch end, prebuilt, and the slot is freed.
      assert %DispatchRun{state: :ended, end_cause: :prebuilt} = queue_run!(queued)

      assert %Dispatch{end_cause: :prebuilt, ended_at: %DateTime{} = at, slot_freed_at: at} =
               dispatch!(dispatch)

      assert DateTime.compare(record.built_at, at) == :eq
      assert DateTime.compare(record.built_queued_at, queued.environment_ref_at) == :eq
      assert Slots.held(ctx.pool.id) == 0
      # The registered run is left as it was: not cancelled, no released_at, no outcome.
      assert %Run{released_at: nil, outcome_state: nil, reason: nil} =
               left = Repo.get!(Run, run.id)

      assert left.state == run.state
      refute left.state == "cancelled"

      # Nothing queued after it.
      assert prebuilds(collection) == [queued.id]

      assert [entry] = entries()
      assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
      assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}

      assert entry.details == %{
               "dispatch_id" => dispatch.public_id,
               "size" => 734_003_200,
               "commit" => "9c1e4a7b2d5f8e0a3c6b9d2f5a8c1e4b7d0a3f6c",
               "environment_ref" => "env-1"
             }
    end

    test "records another pool's build on that pool's record alone", ctx do
      other = pool_fixture(ctx.scope)
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      assert queued.pool_id == ctx.pool.id

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == :ok
      assert %Record{image: image} = record!(collection, ctx.pool)
      assert is_binary(image)
      assert %Record{image: nil, built_target_path: nil} = record!(collection, other)
    end

    test "clears the last failure, and replaces the last good build", ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      Repo.update_all(from(r in Record, where: r.source_collection_id == ^collection.id),
        set: [
          image: @old_image,
          size: 1,
          commit: "old",
          built_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          reported_ref: "env-0",
          failure_cause: :released,
          failure_reason: "no space",
          failed_at: DateTime.utc_now()
        ]
      )

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == :ok

      assert %Record{
               size: 734_003_200,
               reported_ref: "env-1",
               failure_cause: nil,
               failure_reason: nil,
               failed_at: nil
             } = record = record!(collection, ctx.pool)

      refute record.image == @old_image
    end

    test "records a reported ref that differs from the queued one as it is, and queues nothing",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued, environment_ref: "env-7")) == :ok

      assert %Record{reported_ref: "env-7", queued_ref: "env-1"} =
               record!(collection, ctx.pool)

      assert prebuilds(collection) == [queued.id]

      # The collection's ref named again queues nothing: the record was queued for it.
      {:ok, _} =
        Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

      assert prebuilds(collection) == [queued.id]
    end

    test "after the ref went absent, stores the build of a prebuild that took its ref before and keeps it retired",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^collection.id),
          set: [environment_ref: nil]
        )

      absent = Repo.get!(Collection, collection.id)
      {:ok, _} = Repo.transact(fn -> {:ok, Environments.trigger([absent], Dispatches.now())} end)
      %Record{retired_at: %DateTime{} = retired_at} = record!(collection, ctx.pool)

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == :ok

      assert %Record{retired_at: kept, image: image} = record!(collection, ctx.pool)
      assert is_binary(image)
      assert DateTime.compare(kept, retired_at) == :eq
      assert prebuilds(collection) == [queued.id]

      assert Environments.image_for(ctx.pool, %{
               system: "code.example.com",
               path: collection.target_path
             }) == nil
    end

    test "records the target the run was handed over for, not the collection's target now",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^collection.id),
          set: [target_path: "acme/elsewhere"]
        )

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == :ok

      assert %Record{built_target_system: "code.example.com", built_target_path: path} =
               record!(collection, ctx.pool)

      assert path == collection.target_path
      refute path == "acme/elsewhere"
    end
  end

  describe "a prebuild whose ref is older than the recorded image's" do
    # The run of `claimed` ended as a release after its handover ends it, its slot freed.
    defp released!(claimed, cause \\ :prebuilt)

    defp released!(%{dispatch: dispatch, dispatch_run: queued, run: run}, cause) do
      assert %DispatchRun{state: :ended, end_cause: ^cause} = queue_run!(queued)
      assert %Dispatch{end_cause: ^cause, slot_freed_at: %DateTime{}} = dispatch!(dispatch)

      if cause == :released,
        do: assert(%Run{released_at: %DateTime{}} = Repo.get!(Run, run.id)),
        else: assert(%Run{released_at: nil} = Repo.get!(Run, run.id))
    end

    defp release(key, %{dispatch: dispatch}),
      do:
        Dispatches.release(key, id(dispatch), %{
          reason: "The build failed.",
          retry: false
        })

    test "its prebuilt after the newer one's leaves the image and the record as they are, ends its run, and writes no entry",
         ctx do
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      assert prebuilt(ctx.key, newer.dispatch, prebuilt_meta(newer.dispatch_run, commit: "b2")) ==
               :ok

      kept = record!(older.collection, ctx.pool)

      assert prebuilt(
               ctx.key,
               older.dispatch,
               prebuilt_meta(older.dispatch_run, image: @old_image, commit: "a1")
             ) == :ok

      assert record!(older.collection, ctx.pool) == kept
      assert %Record{commit: "b2", reported_ref: "env-2", failure_cause: nil} = kept
      assert DateTime.compare(kept.built_queued_at, newer.dispatch_run.environment_ref_at) == :eq
      released!(older)
      assert Slots.held(ctx.pool.id) == 0

      assert [entry] = entries()
      assert entry.details["dispatch_id"] == newer.dispatch.public_id
    end

    test "its release after the newer one's prebuilt records no failure, and ends its run",
         ctx do
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      assert prebuilt(ctx.key, newer.dispatch, prebuilt_meta(newer.dispatch_run, commit: "b2")) ==
               :ok

      kept = record!(older.collection, ctx.pool)
      assert release(ctx.key, older) == :ok

      assert record!(older.collection, ctx.pool) == kept
      assert %Record{commit: "b2", failure_cause: nil, failure_reason: nil} = kept
      released!(older, :released)
      assert Slots.held(ctx.pool.id) == 0
    end

    test "with no image yet, its prebuilt and its release write as before, and the newer one's prebuilt after them",
         ctx do
      # Its release, with no image yet: the failure is recorded.
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)
      assert release(ctx.key, older) == :ok

      assert %Record{image: nil, failure_cause: :released, failure_reason: "The build failed."} =
               record!(older.collection, ctx.pool)

      # The newer one's prebuilt then records its build, and clears the failure.
      assert prebuilt(ctx.key, newer.dispatch, prebuilt_meta(newer.dispatch_run, commit: "b2")) ==
               :ok

      assert %Record{commit: "b2", failure_cause: nil} = record!(older.collection, ctx.pool)

      # Another collection: the older prebuild's prebuilt first records its build.
      older = handed_over!(ctx)
      newer = newer_prebuild_handed_over!(ctx.key, older)

      assert prebuilt(ctx.key, older.dispatch, prebuilt_meta(older.dispatch_run, commit: "a1")) ==
               :ok

      recorded = record!(older.collection, ctx.pool)
      assert %Record{commit: "a1", reported_ref: "env-1"} = recorded

      assert DateTime.compare(recorded.built_queued_at, older.dispatch_run.environment_ref_at) ==
               :eq

      # The newer one's prebuilt after it replaces it.
      assert prebuilt(ctx.key, newer.dispatch, prebuilt_meta(newer.dispatch_run, commit: "b2")) ==
               :ok

      replaced = record!(older.collection, ctx.pool)
      assert %Record{commit: "b2", reported_ref: "env-2"} = replaced

      assert DateTime.compare(replaced.built_queued_at, newer.dispatch_run.environment_ref_at) ==
               :eq

      assert length(entries()) == 3
    end
  end

  describe "a prebuild that waits again, and takes a newer ref" do
    @image_b "registry.example.com/acme/env@sha256:" <> String.duplicate("bb", 32)
    @image_c "registry.example.com/acme/env@sha256:" <> String.duplicate("cc", 32)

    # The collection's environment_ref set to `ref`, triggered as a listing does.
    defp set_ref!(%Collection{id: id}, ref) do
      {:ok, _queued} =
        Repo.transact(fn ->
          {1, _rows} =
            Repo.update_all(from(c in Collection, where: c.id == ^id),
              set: [environment_ref: ref]
            )

          {:ok, Environments.trigger([Repo.get!(Collection, id)], Dispatches.now())}
        end)
    end

    defp hand_over!(key, %Dispatch{} = dispatch) do
      {:ok, %{run: _run}} =
        Dispatches.handover(key, dispatch.public_id, %{
          body: ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
        })

      queue_run!(%DispatchRun{id: dispatch.dispatch_run_id})
    end

    # P1 claimed for env-1; env-2 queues P2, claimed and handed over; P1's lease lapses
    # and, with none waiting, P1 waits again with the record's queued_ref, env-2, taking
    # it after P2 took it, its queued_at kept.
    defp waits_again!(ctx) do
      {collection, d1, p1} = started!(ctx)
      set_ref!(collection, "env-2")
      %{dispatch: d2} = dispatched!(ctx.key)
      p2 = hand_over!(ctx.key, d2)

      Dispatches.sweep(DateTime.add(d1.lease_until, 1, :second))
      again = queue_run!(p1)

      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} = again
      assert DateTime.compare(again.queued_at, p1.queued_at) == :eq
      assert DateTime.compare(again.environment_ref_at, p2.environment_ref_at) == :gt

      %{collection: collection, p1: again, d2: d2, p2: p2}
    end

    # P1 claimed again and handed over.
    defp claimed_again!(ctx, p1) do
      %{dispatch: dispatch, run: run} = dispatched!(ctx.key)
      assert run.id == p1.id
      {dispatch, hand_over!(ctx.key, dispatch)}
    end

    test "its build after the one of a prebuild that took the ref before it counts", ctx do
      %{collection: collection, p1: p1, d2: d2, p2: p2} = waits_again!(ctx)

      :ok = prebuilt(ctx.key, d2, prebuilt_meta(p2, image: @image_b))
      {d1, p1} = claimed_again!(ctx, p1)
      :ok = prebuilt(ctx.key, d1, prebuilt_meta(p1, image: @image_c))

      recorded = record!(collection, ctx.pool)
      assert %Record{image: @image_c, reported_ref: "env-2"} = recorded
      assert DateTime.compare(recorded.built_queued_at, p1.environment_ref_at) == :eq
    end

    test "a newer ref taken while it waits counts too, after a build of the ref before", ctx do
      %{collection: collection, p1: p1, d2: d2, p2: p2} = waits_again!(ctx)
      :ok = prebuilt(ctx.key, d2, prebuilt_meta(p2, image: @image_b))

      # env-3 while P1 waits: P1 takes it, and when it took it.
      set_ref!(collection, "env-3")
      taken = queue_run!(p1)
      assert %DispatchRun{state: :waiting, environment_ref: "env-3"} = taken
      assert DateTime.compare(taken.queued_at, p1.queued_at) == :eq
      refute DateTime.compare(taken.environment_ref_at, p1.environment_ref_at) == :eq

      {d1, p1} = claimed_again!(ctx, taken)
      :ok = prebuilt(ctx.key, d1, prebuilt_meta(p1, image: @image_c))

      assert %Record{image: @image_c, reported_ref: "env-3", failure_cause: nil} =
               record!(collection, ctx.pool)

      assert Repo.all(
               from r in DispatchRun,
                 where: r.source_collection_id == ^collection.id and r.state == :waiting
             ) == []
    end

    test "the build of a prebuild that took the ref before it, coming after, changes nothing",
         ctx do
      %{collection: collection, p1: p1, d2: d2, p2: p2} = waits_again!(ctx)

      {d1, p1} = claimed_again!(ctx, p1)
      :ok = prebuilt(ctx.key, d1, prebuilt_meta(p1, image: @image_c))
      kept = record!(collection, ctx.pool)

      :ok = prebuilt(ctx.key, d2, prebuilt_meta(p2, image: @image_b))
      assert record!(collection, ctx.pool) == kept
      assert %Record{image: @image_c} = kept
    end
  end

  describe "the refusals, in the contract's order" do
    test "an id not of a dispatch's shape, unknown, or another pool's is forbidden, before any lock, writing nothing",
         ctx do
      {collection, dispatch, queued} = started!(ctx)
      lapse!(dispatch)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))
      meta = prebuilt_meta(queued)

      assert prebuilt(ctx.key, "not-a-dispatch", meta) == {:error, :forbidden}
      assert prebuilt(ctx.key, "dp_0000000000000000", meta) == {:error, :forbidden}
      assert prebuilt(ctx.key, String.upcase(dispatch.public_id), meta) == {:error, :forbidden}
      assert prebuilt(other, dispatch, meta) == {:error, :forbidden}

      # Another organisation's pool.
      %{scope: elsewhere} = sign_up_fixture()
      %{key: elsewhere_key} = handover_place_fixture(elsewhere)
      assert prebuilt(elsewhere_key, dispatch, meta) == {:error, :forbidden}

      # The lapse is not judged for a key refused: the dispatch stays as it was.
      assert %Dispatch{stale_at: nil, ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
      assert queue_run!(queued).state == :claimed
      assert %Record{image: nil} = record!(collection, ctx.pool)
      assert entries() == []
    end

    test "a key revoked since is unauthorized", ctx do
      %{dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      {:ok, _revoked} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == {:error, :unauthorized}
      assert %Dispatch{ended_at: nil} = dispatch!(dispatch)
    end

    test "a dispatch that ended is gone before a run_id that is not its run, writing nothing",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == :ok
      recorded = record!(collection, ctx.pool)

      # A second prebuilt, the same or another, is gone: the first ended the run.
      for meta <- [
            prebuilt_meta(queued),
            prebuilt_meta(queued, image: @old_image, size: 1),
            prebuilt_meta(queued, run_id: Ecto.UUID.generate())
          ] do
        assert prebuilt(ctx.key, dispatch, meta) == {:error, :gone}
      end

      assert record!(collection, ctx.pool) == recorded
      assert [_one] = entries()
    end

    test "a dispatch not handed over whose lease lapsed is lease_expired, before its step or its run is asked, the lapse committed",
         ctx do
      # A prebuild's.
      {collection, dispatch, queued} = started!(ctx)
      lapse!(dispatch)
      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == {:error, :lease_expired}
      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} = dispatch!(dispatch)
      assert queue_run!(queued).state == :waiting
      assert %Record{image: nil} = record!(collection, ctx.pool)

      # An explore run's, whose step is not prebuild, with a run_id that is not its run.
      {:ok, explore} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
      %{dispatch: dispatch} = dispatched!(ctx.key)
      lapse!(dispatch)

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(explore, run_id: Ecto.UUID.generate())) ==
               {:error, :lease_expired}

      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} = dispatch!(dispatch)
      assert queue_run!(explore).state == :waiting
      assert entries() == []
    end

    test "a dispatch whose step is not prebuild is not_prebuild, before not_handed_over and run_mismatch",
         ctx do
      {:ok, explore} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
      %{dispatch: dispatch} = dispatched!(ctx.key)

      for meta <- [prebuilt_meta(explore), prebuilt_meta(explore, run_id: Ecto.UUID.generate())] do
        assert prebuilt(ctx.key, dispatch, meta) == {:error, :not_prebuild}
      end

      # Handed over, the same.
      {:ok, %{run: _run}} =
        Dispatches.handover(ctx.key, dispatch.public_id, %{body: "{}"})

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(explore)) == {:error, :not_prebuild}
      assert %DispatchRun{state: :handed_over} = queue_run!(explore)
      assert entries() == []
    end

    test "a prebuild not handed over is not_handed_over, before run_mismatch", ctx do
      {collection, dispatch, queued} = started!(ctx)
      before = unchanged(collection, dispatch, queued)

      for meta <- [prebuilt_meta(queued), prebuilt_meta(queued, run_id: Ecto.UUID.generate())] do
        assert prebuilt(ctx.key, dispatch, meta) == {:error, :not_handed_over}
      end

      assert unchanged(collection, dispatch, queued) == before
      assert entries() == []
    end

    test "a run_id that is not the dispatch's run is run_mismatch, writing nothing", ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      before = unchanged(collection, dispatch, queued)

      # Another run of the queue's id, and one of no run.
      other_run = Repo.get!(DispatchRun, elem(started!(ctx), 2).id)

      for run_id <- [other_run.run_id, Ecto.UUID.generate()] do
        assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued, run_id: run_id)) ==
                 {:error, :run_mismatch}
      end

      assert unchanged(collection, dispatch, queued) == before
      assert entries() == []
    end
  end

  describe "after the run's end" do
    test "after the run's outcome is gone, and nothing is recorded", ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued, run: run} =
        handed_over!(ctx)

      {:ok, _given} = give_outcome(ctx.key, run, "succeeded")
      before = {unchanged(collection, dispatch, queued), Repo.get!(Run, run.id)}

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == {:error, :gone}
      assert {unchanged(collection, dispatch, queued), Repo.get!(Run, run.id)} == before
      assert %Record{image: nil} = record!(collection, ctx.pool)
      assert entries() == []
    end

    test "after the run's exit folded, which ends nothing of a prebuild's queue, records the build and ends the run prebuilt",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued, run: run} =
        handed_over!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
        )

      folded = Repo.get!(Run, run.id)
      meta = prebuilt_meta(queued)

      assert prebuilt(ctx.key, dispatch, meta) == :ok
      assert Repo.get!(Run, run.id) == folded
      assert %DispatchRun{state: :ended, end_cause: :prebuilt} = queue_run!(queued)
      assert %Dispatch{end_cause: :prebuilt, slot_freed_at: %DateTime{}} = dispatch!(dispatch)
      assert record!(collection, ctx.pool).image == meta.image
      assert length(entries()) == 1
    end
  end

  test "a failure rolls back, writes nothing, and is unavailable", ctx do
    %{collection: collection, dispatch: dispatch, dispatch_run: queued, run: run} =
      handed_over!(ctx)

    # A commit the record cannot keep, which the body never carries: the write fails.
    too_long = String.duplicate("c", 300)

    {answer, log} =
      with_log(fn -> prebuilt(ctx.key, dispatch, prebuilt_meta(queued, commit: too_long)) end)

    assert answer == {:error, :unavailable}
    assert log =~ "a prebuilt could not be recorded"
    refute log =~ too_long
    assert %DispatchRun{state: :handed_over} = queue_run!(queued)
    assert %Dispatch{ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
    assert %Run{released_at: nil} = Repo.get!(Run, run.id)
    assert %Record{image: nil} = record!(collection, ctx.pool)
    assert entries() == []

    assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == :ok
  end
end
