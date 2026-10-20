defmodule Apiary.Dispatches.ReleaseTest do
  # A node pool's starter gives back the run of a dispatch its pool claimed
  # (`Apiary.Dispatches.Release`): each refusal in the contract's order, the lapse judged
  # before anything else and committed, a dispatch handed over never `lease_expired`;
  # before the handover, an explore run that waits again or ends, a prebuild that waits
  # again, is superseded, or ends with its build recorded as failed; after it, the run
  # ended `released`, the next run of an explore run's take in queued only while its work
  # item explores that take in, a prebuild's build recorded as failed and nothing queued;
  # a release after an outcome, which writes nothing; a failure that writes nothing; and
  # the one audit entry, about the pool before the handover and the run after it.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @reason "The job could not start."
  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  defp queued!(ctx, attrs \\ %{}) do
    work_item = work_item_fixture(ctx.scope, attrs)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {work_item, run}
  end

  # A collection, the pool's environment record of it, `env-1` queued and a good build
  # kept, and a prebuild of it queued for the pool.
  defp prebuild!(ctx) do
    collection = collection_fixture(ctx.scope)

    record =
      Repo.insert!(%Record{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        pool_id: ctx.pool.id,
        source_collection_id: collection.id,
        queued_ref: "env-1",
        queued_at: DateTime.utc_now(),
        image: @image,
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1"
      })

    {:ok, run} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    {collection, record, run}
  end

  defp started!(ctx) do
    %{dispatch: dispatch} = dispatched!(ctx.key)
    dispatch
  end

  defp handed_over!(ctx) do
    dispatch = started!(ctx)

    assert {:ok, %{run: run}} =
             Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})

    {dispatch, run}
  end

  defp release(key, dispatch, retry, opts \\ []) do
    Dispatches.release(key, id(dispatch), %{
      reason: Keyword.get(opts, :reason, @reason),
      retry: retry
    })
  end

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id), do: public_id

  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp record!(%Record{id: id}), do: Repo.get!(Record, id)
  defp entries, do: Repo.all(from e in Entry, where: e.action == "dispatch.release")

  defp runs_of(%WorkItem{id: id}),
    do: Repo.all(from r in DispatchRun, where: r.work_item_id == ^id, order_by: r.attempt)

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

  # A dispatch handed over, its claim, its dispatched and its handover moved back so the
  # clock is past its lease, as ten minutes and more after the claim.
  defp lapse_handed_over!(%Dispatch{id: id}) do
    now = DateTime.utc_now()

    lease_until = %{
      DateTime.truncate(DateTime.add(now, -60, :second), :second)
      | microsecond: {0, 6}
    }

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [
          claimed_at: DateTime.add(now, -700, :second),
          dispatched_at: DateTime.add(now, -690, :second),
          handed_over_at: DateTime.add(now, -680, :second),
          lease_until: lease_until
        ]
      )
  end

  # The dispatch ended `released`, its slot freed at its end.
  defp released!(ctx, dispatch) do
    assert %Dispatch{end_cause: :released, ended_at: %DateTime{} = at, slot_freed_at: at} =
             dispatch!(dispatch)

    assert Slots.held(ctx.pool.id) == 0
  end

  # The one entry, by the pool's key, about `subject`, with `came` and the rest.
  defp entry!(ctx, dispatch, subject, details) do
    assert [entry] = entries()
    assert {entry.subject_kind, entry.subject_id} == subject
    assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}

    assert entry.details ==
             Map.merge(
               %{"dispatch_id" => dispatch.public_id, "reason" => @reason},
               details
             )
  end

  describe "the refusals, in the contract's order" do
    test "an id not of a dispatch's shape, unknown, or another pool's is forbidden, before any lock, writing nothing",
         ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)
      lapse!(dispatch)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      assert release(ctx.key, "not-a-dispatch", true) == {:error, :forbidden}
      assert release(ctx.key, "dp_0000000000000000", true) == {:error, :forbidden}
      assert release(other, dispatch, true) == {:error, :forbidden}

      # The lapse is not judged for a key refused: the dispatch stays as it was.
      assert %Dispatch{stale_at: nil, ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
      assert queue_run!(queued).state == :claimed
      assert entries() == []
    end

    test "a key revoked since is unauthorized", ctx do
      queued!(ctx)
      dispatch = started!(ctx)
      {:ok, _revoked} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)

      assert release(ctx.key, dispatch, true) == {:error, :unauthorized}
      assert %Dispatch{ended_at: nil} = dispatch!(dispatch)
    end

    test "a dispatch that ended is gone, and nothing is written", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)
      assert release(ctx.key, dispatch, false) == :ok
      ended = dispatch!(dispatch)

      assert release(ctx.key, dispatch, true) == {:error, :gone}
      assert dispatch!(dispatch) == ended
      assert queue_run!(queued).end_cause == :released
      assert length(entries()) == 1
    end

    test "a dispatch whose lease lapsed is lease_expired, the lapse committed: the run waits again",
         ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)
      lapse!(dispatch)

      assert release(ctx.key, dispatch, false) == {:error, :lease_expired}

      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil, slot_freed_at: %DateTime{}} =
               dispatch!(dispatch)

      assert queue_run!(queued).state == :waiting

      # Stale already: lease_expired again, and still nothing ends.
      assert release(ctx.key, dispatch, true) == {:error, :lease_expired}
      assert queue_run!(queued).state == :waiting
      assert entries() == []
    end

    test "a dispatch handed over is never lease_expired: past its lease, its release is :ok",
         ctx do
      {_work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)
      lapse_handed_over!(dispatch)
      assert DateTime.compare(Dispatches.now(), dispatch!(dispatch).lease_until) == :gt

      assert release(ctx.key, dispatch, false) == :ok
      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
      assert %Dispatch{stale_at: nil} = dispatch!(dispatch)
      released!(ctx, dispatch)
      assert %Run{state: "cancelled", reason: "released"} = Repo.get!(Run, run.id)
    end
  end

  describe "before the handover, an explore run" do
    test "with retry waits again, the same run_id and queued_at; the dispatch ends released",
         ctx do
      {work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)

      assert release(ctx.key, dispatch, true) == :ok

      run = queue_run!(queued)
      assert %DispatchRun{state: :waiting, end_cause: nil} = run
      assert {run.run_id, run.queued_at} == {queued.run_id, queued.queued_at}
      released!(ctx, dispatch)
      assert Repo.get!(WorkItem, work_item.id).state == :exploring

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "explore",
        "retry" => true,
        "handed_over" => false,
        "waits" => true
      })

      # The next claim takes the same run again, with a new dispatch.
      %{dispatch: again} = dispatched!(ctx.key)
      assert again.dispatch_run_id == queued.id
      assert again.id != dispatch.id
    end

    test "without retry ends the run, released, and leaves the work item exploring", ctx do
      {work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)

      assert release(ctx.key, dispatch, false) == :ok

      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
      released!(ctx, dispatch)
      assert Repo.get!(WorkItem, work_item.id).state == :exploring
      assert runs_of(work_item) |> length() == 1

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "explore",
        "retry" => false,
        "handed_over" => false,
        "ended" => true
      })
    end
  end

  describe "before the handover, a prebuild" do
    test "with retry waits again with the record's queued_ref, and no failure is recorded",
         ctx do
      {_collection, record, queued} = prebuild!(ctx)
      dispatch = started!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.id == ^record.id),
          set: [queued_ref: "env-2"]
        )

      assert release(ctx.key, dispatch, true) == :ok

      run = queue_run!(queued)
      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} = run
      assert {run.run_id, run.queued_at} == {queued.run_id, queued.queued_at}
      released!(ctx, dispatch)

      assert %Record{failure_cause: nil, failure_reason: nil, failed_at: nil, image: @image} =
               record!(record)

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "prebuild",
        "retry" => true,
        "handed_over" => false,
        "waits" => true
      })
    end

    test "with retry ends superseded while another prebuild of its collection and pool waits",
         ctx do
      {collection, record, queued} = prebuild!(ctx)
      dispatch = started!(ctx)

      {:ok, waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.id == ^record.id),
          set: [queued_ref: "env-3"]
        )

      assert release(ctx.key, dispatch, true) == :ok

      assert %DispatchRun{state: :ended, end_cause: :superseded} = queue_run!(queued)
      assert %DispatchRun{state: :waiting, environment_ref: "env-3"} = queue_run!(waiting)
      released!(ctx, dispatch)
      assert %Record{failure_cause: nil} = record!(record)

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "prebuild",
        "retry" => true,
        "handed_over" => false,
        "superseded" => true
      })
    end

    test "without retry ends, and records the last build as failed, keeping the good one",
         ctx do
      {_collection, record, queued} = prebuild!(ctx)
      dispatch = started!(ctx)

      assert release(ctx.key, dispatch, false) == :ok

      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
      released!(ctx, dispatch)
      %Dispatch{ended_at: ended_at} = dispatch!(dispatch)

      assert %Record{
               failure_cause: :released,
               failure_reason: @reason,
               failed_at: ^ended_at,
               image: @image,
               size: 734_003_200,
               commit: "9c1e4a7b",
               reported_ref: "env-1"
             } = record!(record)

      assert record!(record).built_at == record.built_at

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "prebuild",
        "retry" => false,
        "handed_over" => false,
        "ended" => true
      })
    end
  end

  describe "after the handover" do
    test "an explore run with retry ends released and queues the next run of its take in",
         ctx do
      {work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)

      assert release(ctx.key, dispatch, true) == :ok

      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
      released!(ctx, dispatch)
      assert %Run{state: "cancelled", reason: "released"} = Repo.get!(Run, run.id)

      assert [_first, next] = runs_of(work_item)
      assert %DispatchRun{state: :waiting, take_in: 1, attempt: 2, of: 3} = next
      assert next.run_id != queued.run_id

      entry!(ctx, dispatch, {"run", run.id}, %{
        "step" => "explore",
        "retry" => true,
        "handed_over" => true,
        "next_run" => next.run_id
      })
    end

    test "an explore run without retry ends released and queues nothing", ctx do
      {work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)

      assert release(ctx.key, dispatch, false) == :ok
      assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
      assert [_only] = runs_of(work_item)

      entry!(ctx, dispatch, {"run", run.id}, %{
        "step" => "explore",
        "retry" => false,
        "handed_over" => true,
        "ended" => true
      })
    end

    test "with retry, a work item no longer exploring, or on another take in, queues nothing",
         ctx do
      for change <- [[state: :closed, closed_at: DateTime.utc_now()], [take_in: 2]] do
        {work_item, queued} = queued!(ctx)
        {dispatch, _run} = handed_over!(ctx)

        {1, _rows} =
          Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: change)

        assert release(ctx.key, dispatch, true) == :ok
        assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
        assert [_only] = runs_of(work_item)

        assert %Entry{details: %{"ended" => true}} =
                 Enum.find(entries(), &(&1.details["dispatch_id"] == dispatch.public_id))
      end
    end

    test "with retry, a take in whose runs are used up queues nothing", ctx do
      {work_item, queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
          set: [attempt: 3]
        )

      {dispatch, _run} = handed_over!(ctx)

      assert release(ctx.key, dispatch, true) == :ok
      assert [_only] = runs_of(work_item)
      assert [%Entry{details: %{"ended" => true}}] = entries()
    end

    test "a prebuild, with retry or without, queues nothing and records the build as failed",
         ctx do
      for retry <- [true, false] do
        {collection, record, queued} = prebuild!(ctx)
        {dispatch, run} = handed_over!(ctx)

        assert release(ctx.key, dispatch, retry) == :ok

        assert %DispatchRun{state: :ended, end_cause: :released} = queue_run!(queued)
        released!(ctx, dispatch)

        assert Repo.all(
                 from r in DispatchRun,
                   where: r.source_collection_id == ^collection.id,
                   select: r.id
               ) == [queued.id]

        assert %Record{
                 failure_cause: :released,
                 failure_reason: @reason,
                 image: @image,
                 queued_ref: "env-1"
               } = record!(record)

        assert %Entry{subject_id: subject_id, details: details} =
                 Enum.find(entries(), &(&1.details["dispatch_id"] == dispatch.public_id))

        assert subject_id == run.id
        assert %{"handed_over" => true, "retry" => ^retry, "ended" => true} = details
      end
    end

    test "after the run's outcome is gone, and nothing is written", ctx do
      {_work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)
      run = Repo.get!(Run, run.id)
      {:ok, _given} = give_outcome(ctx.key, run, "succeeded")
      before = {queue_run!(queued), dispatch!(dispatch), Repo.get!(Run, run.id)}

      assert release(ctx.key, dispatch, true) == {:error, :gone}
      assert {queue_run!(queued), dispatch!(dispatch), Repo.get!(Run, run.id)} == before
      assert entries() == []
    end

    test "after the run's exit folded, its end not yet written, is gone, and nothing is written",
         ctx do
      {work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
        )

      folded = Repo.get!(Run, run.id)

      assert release(ctx.key, dispatch, true) == {:error, :gone}
      assert Repo.get!(Run, run.id) == folded
      assert %DispatchRun{state: :handed_over} = queue_run!(queued)
      assert %Dispatch{ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
      assert [_only] = runs_of(work_item)
      assert entries() == []
    end
  end

  test "a failure rolls back, writes nothing, and is unavailable", ctx do
    {_collection, record, queued} = prebuild!(ctx)
    dispatch = started!(ctx)

    # A reason the record cannot keep, which the body never carries: the write fails.
    too_long = String.duplicate("a", 300)

    {answer, log} =
      with_log(fn -> release(ctx.key, dispatch, false, reason: too_long) end)

    assert answer == {:error, :unavailable}
    refute log =~ too_long
    assert queue_run!(queued).state == :claimed
    assert %Dispatch{ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
    assert %Record{failure_cause: nil} = record!(record)
    assert entries() == []

    assert release(ctx.key, dispatch, false) == :ok
  end
end
