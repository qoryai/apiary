defmodule Apiary.Dispatches.PrebuiltTest do
  # A node pool's starter reports the image a prebuild its pool claimed built
  # (`Apiary.Dispatches.Prebuilt`): each refusal in the contract's order, the lapse judged
  # and committed, nothing written on any refusal; on success the build recorded on the
  # claiming pool's record with the target the registered run was handed over for, the
  # reported ref as it is, the last failure cleared and `retired_at` kept, the run ended as
  # a release after its handover with retry false ends it, nothing queued; a second
  # prebuilt and one after the run's outcome or exit, gone; a failure that writes nothing;
  # and the one audit entry, about the registered run.
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

  # A prebuild queued by the trigger, claimed at revision 2 and started, not handed over.
  defp started!(ctx, attrs \\ %{}) do
    collection = collection_fixture(ctx.scope, attrs)

    {:ok, _queued} =
      Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

    %{dispatch: dispatch, run: queued} = dispatched!(ctx.key, 2)
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
    test "records the build for the claiming pool, ends the run as a release, and queues nothing",
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

      # The run ends as a release after its handover with retry false ends it.
      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)

      assert %Dispatch{end_cause: :released, ended_at: %DateTime{} = at, slot_freed_at: at} =
               dispatch!(dispatch)

      assert DateTime.compare(record.built_at, at) == :eq
      assert Slots.held(ctx.pool.id) == 0
      assert %Run{released_at: %DateTime{}, outcome_state: nil} = Repo.get!(Run, run.id)

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

    test "after the ref went absent, stores the build and keeps it retired", ctx do
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

    test "records the target the run was handed over for, not the collection's target now (V-714)",
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

  describe "the refusals, in the contract's order" do
    test "revision 1 is not_found first, before the id, the key or the dispatch is asked", ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))
      meta = prebuilt_meta(queued, revision: 1)
      before = unchanged(collection, dispatch, queued)

      for {key, id} <- [
            {ctx.key, dispatch},
            {ctx.key, "not-a-dispatch"},
            {ctx.key, "dp_0000000000000000"},
            {other, dispatch}
          ] do
        assert prebuilt(key, id, meta) == {:error, :not_found}
      end

      {:ok, _revoked} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      assert prebuilt(ctx.key, dispatch, meta) == {:error, :not_found}
      assert unchanged(collection, dispatch, queued) == before
      assert entries() == []
    end

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
        Dispatches.handover(ctx.key, dispatch.public_id, %{revision: 2, body: "{}"})

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

    test "after the run's exit folded, its end not yet written, is gone, and nothing is recorded",
         ctx do
      %{collection: collection, dispatch: dispatch, dispatch_run: queued, run: run} =
        handed_over!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
        )

      folded = Repo.get!(Run, run.id)

      assert prebuilt(ctx.key, dispatch, prebuilt_meta(queued)) == {:error, :gone}
      assert Repo.get!(Run, run.id) == folded
      assert %DispatchRun{state: :handed_over} = queue_run!(queued)
      assert %Dispatch{ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
      assert %Record{image: nil} = record!(collection, ctx.pool)
      assert entries() == []
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
