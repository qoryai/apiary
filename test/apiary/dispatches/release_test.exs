defmodule Apiary.Dispatches.ReleaseTest do
  # A node pool's starter gives back the run of a dispatch its pool claimed
  # (`Apiary.Dispatches.Release`): each refusal in the contract's order, the lapse judged
  # before anything else and committed, a dispatch handed over by its `dispatched` or by
  # the redemption of its run code `machine_exists`, writing nothing; an explore run that
  # waits again, and a prebuild that waits again or is superseded, with no failure
  # recorded; the registered run deleted with its run code; and the one audit entry,
  # about the pool. A release that cannot be written is
  # `ApiaryWeb.Contract.ReleaseControllerTest`'s.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
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
        image: @image,
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1",
        built_ref: "env-1"
      })

    {:ok, run} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    {collection, record, run}
  end

  # A run claimed, which registers it: what the claim answered, its dispatch not yet
  # handed over.
  defp claimed!(ctx) do
    {:ok, claimed} = Dispatches.claim(ctx.key, Dispatches.now())
    claimed
  end

  defp started!(ctx), do: claimed!(ctx).dispatch

  # A run claimed and its machine started, which hands it over: its dispatch and its
  # registered run.
  defp handed_over!(ctx) do
    %{dispatch: dispatch, registered: run} = dispatched!(ctx.key)
    {dispatch, run}
  end

  defp release(key, dispatch), do: Dispatches.release(key, id(dispatch), %{reason: @reason})

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id), do: public_id

  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp record!(%Record{id: id}), do: Repo.get!(Record, id)

  defp registered(%DispatchRun{id: id}),
    do: Repo.one(from r in Run, where: r.dispatch_run_id == ^id)

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

  # The dispatch ended `released`, its slot freed at its end, the registered run of its
  # run of the queue deleted with its run code.
  defp released!(ctx, dispatch, queued) do
    assert %Dispatch{end_cause: :released, ended_at: %DateTime{} = at, slot_freed_at: at} =
             dispatch!(dispatch)

    assert Slots.held(ctx.pool.id) == 0
    assert registered(queued) == nil
  end

  # What a refused release leaves as it was.
  defp state(queued, dispatch), do: {queue_run!(queued), dispatch!(dispatch), registered(queued)}

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

      assert release(ctx.key, "not-a-dispatch") == {:error, :forbidden}
      assert release(ctx.key, "dp_0000000000000000") == {:error, :forbidden}
      assert release(other, dispatch) == {:error, :forbidden}

      # The lapse is not judged for a key refused: the dispatch stays as it was.
      assert %Dispatch{stale_at: nil, ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)
      assert queue_run!(queued).state == :claimed
      assert entries() == []
    end

    test "a key revoked since is unauthorized", ctx do
      queued!(ctx)
      dispatch = started!(ctx)
      {:ok, _revoked} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)

      assert release(ctx.key, dispatch) == {:error, :unauthorized}
      assert %Dispatch{ended_at: nil} = dispatch!(dispatch)
    end

    test "a dispatch that ended is gone, and nothing is written", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)
      assert release(ctx.key, dispatch) == :ok
      ended = dispatch!(dispatch)

      assert release(ctx.key, dispatch) == {:error, :gone}
      assert dispatch!(dispatch) == ended
      assert queue_run!(queued).state == :waiting
      assert length(entries()) == 1
    end

    test "a dispatch whose lease lapsed is lease_expired, the lapse committed: the run waits again",
         ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)
      lapse!(dispatch)

      assert release(ctx.key, dispatch) == {:error, :lease_expired}

      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil, slot_freed_at: %DateTime{}} =
               dispatch!(dispatch)

      assert queue_run!(queued).state == :waiting
      assert registered(queued) == nil

      # Stale already: lease_expired again, and still nothing ends.
      assert release(ctx.key, dispatch) == {:error, :lease_expired}
      assert queue_run!(queued).state == :waiting
      assert entries() == []
    end

    test "after dispatched is machine_exists, and nothing is written", ctx do
      {_work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)
      before = state(queued, dispatch)

      assert release(ctx.key, dispatch) == {:error, :machine_exists}
      assert state(queued, dispatch) == before
      assert %DispatchRun{state: :handed_over} = queue_run!(queued)
      assert registered(queued).id == run.id
      assert Slots.held(ctx.pool.id) == 1
      assert entries() == []
    end

    test "after the redemption of the run code, before dispatched, is machine_exists", ctx do
      {_work_item, queued} = queued!(ctx)
      %{dispatch: dispatch, run_code: code} = claimed!(ctx)
      _run_key = redeemed_run_key!(code)
      before = state(queued, dispatch)

      assert %Dispatch{dispatched_at: nil, handed_over_at: %DateTime{}} = dispatch!(dispatch)
      assert release(ctx.key, dispatch) == {:error, :machine_exists}
      assert state(queued, dispatch) == before
      assert %Run{run_key_payload: payload} = registered(queued)
      assert is_binary(payload)
      assert entries() == []
    end

    test "machine_exists comes before lease_expired: past its lease, a dispatch handed over",
         ctx do
      {_work_item, queued} = queued!(ctx)
      {dispatch, _run} = handed_over!(ctx)
      lapse_handed_over!(dispatch)
      assert DateTime.compare(Dispatches.now(), dispatch!(dispatch).lease_until) == :gt

      assert release(ctx.key, dispatch) == {:error, :machine_exists}
      assert %DispatchRun{state: :handed_over} = queue_run!(queued)
      assert %Dispatch{stale_at: nil, ended_at: nil} = dispatch!(dispatch)
    end

    test "gone comes before machine_exists: a dispatch handed over whose run ended", ctx do
      {_work_item, queued} = queued!(ctx)
      {dispatch, run} = handed_over!(ctx)
      run = Repo.get!(Run, run.id)

      Apiary.RunEventsFixtures.event_fixture(run, 1, "run.exited", %{
        "state" => "succeeded",
        "exit_code" => 0
      })

      {:ok, _run} = Apiary.Runs.Projector.project(run)
      before = state(queued, dispatch)

      assert %DispatchRun{state: :ended} = queue_run!(queued)
      assert release(ctx.key, dispatch) == {:error, :gone}
      assert state(queued, dispatch) == before
      assert entries() == []
    end
  end

  describe "an explore run" do
    test "waits again, the same run_id and queued_at; the dispatch ends released", ctx do
      {work_item, queued} = queued!(ctx)
      %{dispatch: dispatch, run_code: code} = claimed!(ctx)
      assert bound_gateway(code) == ctx.gateway.id

      assert release(ctx.key, dispatch) == :ok

      run = queue_run!(queued)
      assert %DispatchRun{state: :waiting, end_cause: nil} = run
      assert {run.run_id, run.queued_at} == {queued.run_id, queued.queued_at}
      released!(ctx, dispatch, queued)
      assert Repo.get!(WorkItem, work_item.id).state == :exploring
      assert [_only] = runs_of(work_item)

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "explore",
        "handed_over" => false,
        "waits" => true
      })

      # The code redeems nothing.
      pair = Apiary.AccessKeysFixtures.ed25519_key_pair()
      request = run_code_request(code, pair, DateTime.utc_now())

      assert Apiary.Runs.RunCode.redeem(request, relayed_by: ctx.gateway.id) ==
               {:error, :unauthorized}

      # The next claim takes the same run again, with a new dispatch.
      %{dispatch: again} = dispatched!(ctx.key)
      assert again.dispatch_run_id == queued.id
      assert again.id != dispatch.id
    end
  end

  describe "a prebuild" do
    test "waits again with its ref, and no failure is recorded", ctx do
      {_collection, record, queued} = prebuild!(ctx)
      dispatch = started!(ctx)

      assert release(ctx.key, dispatch) == :ok

      run = queue_run!(queued)
      assert %DispatchRun{state: :waiting, environment_ref: "env-1"} = run
      assert {run.run_id, run.queued_at} == {queued.run_id, queued.queued_at}
      released!(ctx, dispatch, queued)

      assert %Record{failure_cause: nil, failure_reason: nil, failed_at: nil, image: @image} =
               record!(record)

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "prebuild",
        "handed_over" => false,
        "waits" => true
      })
    end

    test "waits again beside a prebuild of another ref of its collection and pool", ctx do
      {collection, _record, queued} = prebuild!(ctx)
      dispatch = started!(ctx)

      {:ok, waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      assert release(ctx.key, dispatch) == :ok

      assert %DispatchRun{state: :waiting, environment_ref: "env-1"} = queue_run!(queued)
      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} = queue_run!(waiting)
      released!(ctx, dispatch, queued)
    end

    test "ends superseded while another prebuild of its collection, pool and ref waits", ctx do
      {collection, record, queued} = prebuild!(ctx)
      dispatch = started!(ctx)

      {:ok, waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert release(ctx.key, dispatch) == :ok

      assert %DispatchRun{state: :ended, end_cause: :superseded} = queue_run!(queued)
      assert %DispatchRun{state: :waiting, environment_ref: "env-1"} = queue_run!(waiting)
      released!(ctx, dispatch, queued)
      assert %Record{failure_cause: nil} = record!(record)

      entry!(ctx, dispatch, {"node", ctx.pool.id}, %{
        "step" => "prebuild",
        "handed_over" => false,
        "superseded" => true
      })
    end

    test "after dispatched is machine_exists, and the record keeps its last build", ctx do
      {_collection, record, queued} = prebuild!(ctx)
      {dispatch, _run} = handed_over!(ctx)

      assert release(ctx.key, dispatch) == {:error, :machine_exists}
      assert %DispatchRun{state: :handed_over} = queue_run!(queued)
      assert %Record{failure_cause: nil, image: @image} = record!(record)
      assert entries() == []
    end
  end
end
