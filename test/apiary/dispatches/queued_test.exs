defmodule Apiary.Dispatches.QueuedTest do
  # The run record of a run of the queue from the moment it is queued
  # (`Apiary.Dispatches.Queued`): every way a run is queued writes it, numbered, pending,
  # with no node; the claim updates it; a failed start ends it and gives the retry the
  # next number; a run that ends while it waits ends its record, which keeps its number;
  # and the lost-run check, the rebuild and retention leave a queued run as it is.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [walked_claim: 2, workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Retention}
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Runs.{Liveness, Projector, Run}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    gateway = workspace_gateway!(scope)
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{scope: scope, gateway: gateway, pool: pool, key: key}
  end

  defp queue!(work_item, take_in \\ 1) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, take_in) end)
    run
  end

  defp queued!(scope), do: scope |> work_item_fixture() |> queue!()

  defp record(%DispatchRun{id: id}), do: Repo.one(from r in Run, where: r.dispatch_run_id == ^id)

  defp records(scope),
    do: Repo.all(from r in Run, where: r.workspace_id == ^scope.workspace.id, order_by: r.number)

  defp run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)

  # The queued record of `queued`: pending, numbered, with no node and no registration.
  defp assert_queued(%DispatchRun{} = queued, number) do
    assert %Run{
             state: "pending",
             number: ^number,
             node_id: nil,
             registered_at: nil,
             started_at: nil,
             projected_sequence: 0
           } = run = record(queued)

    assert Run.public_id?(run.public_id)
    assert run.node_run_id == queued.run_id
    assert run.workspace_id == queued.workspace_id
    assert run.organisation_id == queued.organisation_id
    assert Run.queued?(run)
    run
  end

  describe "queueing writes the run record" do
    test "queue/2 writes a pending run, numbered next, at the time it was queued", ctx do
      first = queued!(ctx.scope)
      second = queued!(ctx.scope)

      run = assert_queued(first, 1)
      assert run.inserted_at == run!(first).queued_at
      assert_queued(second, 2)
    end

    test "queue_next/3 writes the next run's record with the next number", ctx do
      work_item = work_item_fixture(ctx.scope)
      first = queue!(work_item)

      Repo.update_all(from(r in DispatchRun, where: r.id == ^first.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, {:ok, next}} =
        Repo.transact(fn -> {:ok, Dispatches.queue_next(work_item, 1)} end)

      assert_queued(next, 2)
    end

    @tag needs: [:factory, :workflow_model]
    test "queue_stage/3 writes the stage's run with its record", ctx do
      work_item = work_item_fixture(ctx.scope)

      {:ok, run} =
        Repo.transact(fn ->
          Dispatches.queue_stage(work_item.id, 1, %{rounds_left: 0, stage: %{}})
        end)

      assert_queued(run, 1)
    end

    test "requeue_for_image/1 writes the requeued run's record with the next number", ctx do
      work_item = work_item_fixture(ctx.scope)
      first = queue!(work_item)

      Repo.update_all(from(r in DispatchRun, where: r.id == ^first.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, requeued} = Repo.transact(fn -> Dispatches.requeue_for_image(run!(first)) end)
      assert %DispatchRun{image_requeue: true} = requeued
      assert_queued(requeued, 2)
    end

    test "queue_prebuild/3 writes a new prebuild's record; one already waiting takes no number",
         ctx do
      collection = collection_fixture(ctx.scope)

      prebuild = fn ref ->
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, ref) end)
      end

      {:ok, first} = prebuild.("env-1")
      assert_queued(first, 1)

      {:ok, again} = prebuild.("env-1")
      assert again.id == first.id
      assert length(records(ctx.scope)) == 1

      {:ok, other} = prebuild.("env-2")
      assert_queued(other, 2)
    end

    test "a queue that rolls back gives its number back", ctx do
      work_item = work_item_fixture(ctx.scope)

      assert {:error, :rolled_back} =
               Repo.transact(fn ->
                 {:ok, _run} = Dispatches.queue(work_item, 1)
                 {:error, :rolled_back}
               end)

      assert_queued(queued!(ctx.scope), 1)
    end

    test "a take in queues its run with its record, the workspace told", ctx do
      :ok = Apiary.Runs.subscribe_touched(ctx.scope)
      queued = queued!(ctx.scope)
      assert_queued(queued, 1)
      workspace_id = ctx.scope.workspace.id
      assert_received {:runs_touched, ^workspace_id}
    end
  end

  describe "the claim" do
    test "updates the queued record and inserts none: its id, number and queue time kept",
         ctx do
      queued = queued!(ctx.scope)
      before = assert_queued(queued, 1)

      {:ok, %{registered: registered}} = walked_claim(ctx.key, Dispatches.now())

      assert registered.id == before.id
      assert registered.public_id == before.public_id
      assert registered.number == 1
      assert registered.inserted_at == before.inserted_at

      assert %Run{state: "pending", node_id: node_id, registered_at: %DateTime{}} =
               record(queued)

      assert node_id == ctx.pool.id
      refute Run.queued?(record(queued))
      assert length(records(ctx.scope)) == 1
    end

    test "a run of the queue with no record, as the previous release queued it, gets one",
         ctx do
      queued = queued!(ctx.scope)
      Repo.delete_all(from r in Run, where: r.dispatch_run_id == ^queued.id)

      {:ok, %{registered: registered}} = walked_claim(ctx.key, Dispatches.now())
      assert %Run{number: 2, registered_at: %DateTime{}} = registered
      assert registered.dispatch_run_id == queued.id
    end
  end

  describe "a failed start" do
    test "a release ends the run failed with its number; the retry waits as the next number",
         ctx do
      queued = queued!(ctx.scope)
      {:ok, %{dispatch: dispatch, registered: first}} = walked_claim(ctx.key, Dispatches.now())

      assert :ok = Dispatches.release(ctx.key, dispatch.public_id, %{reason: "No machine."})

      assert %Run{state: "failed", reason: "machine_not_made", number: 1} =
               Repo.get!(Run, first.id)

      assert run!(queued).state == :waiting
      retry = assert_queued(queued, 2)
      assert retry.id != first.id
    end

    test "a lapsed lease ends the run failed with its number; the retry waits as the next number",
         ctx do
      queued = queued!(ctx.scope)
      {:ok, %{dispatch: dispatch, registered: first}} = walked_claim(ctx.key, Dispatches.now())

      Dispatches.sweep(dispatch.lease_until)

      assert %Run{state: "failed", reason: "lease_lapsed", number: 1} =
               Repo.get!(Run, first.id)

      retry = assert_queued(queued, 2)
      assert retry.inserted_at == dispatch.lease_until
    end
  end

  describe "a run that ends while it waits keeps its number" do
    test "undone: cancelled, undone", ctx do
      work_item = work_item_fixture(ctx.scope)
      queued = queue!(work_item)

      assert {:ok, :ok} =
               Repo.transact(fn -> {:ok, Dispatches.cancel_for_undo(work_item)} end)

      assert %Run{state: "cancelled", reason: "undone", number: 1} = record(queued)
    end

    test "closed, waiting or claimed: cancelled, closed; the claimed run's code redeems no more",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      claimed = queue!(work_item)
      {:ok, %{registered: registered}} = walked_claim(ctx.key, Dispatches.now())
      assert registered.dispatch_run_id == claimed.id
      waiting = queue_next_waiting!(ctx, work_item)

      {:ok, _closed} = Apiary.WorkItems.close(ctx.scope, Repo.get!(WorkItem, work_item.id))

      assert %Run{state: "cancelled", reason: "closed", number: 1, run_documents: nil} =
               record(claimed)

      assert %Run{state: "cancelled", reason: "closed", number: 2} = record(waiting)
      assert %Dispatch{end_cause: :closed} = Repo.get_by!(Dispatch, dispatch_run_id: claimed.id)
    end

    test "closed or undone before a claim takes it: cancelled with the cause", ctx do
      ended =
        for {state, cause} <- [closed: "closed", undone: "undone"] do
          work_item = work_item_fixture(ctx.scope)
          queued = queue!(work_item)

          set =
            if state == :closed,
              do: [state: :closed, closed_at: Dispatches.now()],
              else: [state: :undone]

          Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: set)
          {queued, cause}
        end

      assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now())

      for {queued, cause} <- ended,
          do: assert(%Run{state: "cancelled", reason: ^cause} = record(queued))
    end

    # A prebuild builds an environment image, which the registry stores.
    @tag needs: [:factory, :registry]
    test "a claimed prebuild superseded on its lapse: its started run failed, no new record",
         ctx do
      collection = collection_fixture(ctx.scope)

      prebuild = fn ->
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)
      end

      {:ok, first} = prebuild.()
      {:ok, %{dispatch: dispatch}} = walked_claim(ctx.key, Dispatches.now())
      {:ok, second} = prebuild.()
      assert second.id != first.id

      Dispatches.sweep(dispatch.lease_until)

      assert %DispatchRun{state: :ended, end_cause: :superseded} = run!(first)
      assert %Run{state: "failed", reason: "lease_lapsed", number: 1} = record_by_number(ctx, 1)
      assert record(first) == nil
      assert_queued(second, 2)
    end
  end

  defp record_by_number(ctx, number),
    do: Repo.get_by!(Run, workspace_id: ctx.scope.workspace.id, number: number)

  # A second run of the take in, waiting, beside the claimed first.
  defp queue_next_waiting!(ctx, work_item) do
    {:ok, run} =
      Repo.transact(fn ->
        Dispatches.queue_stage(work_item.id, 1, %{rounds_left: 0, stage: %{}})
      end)

    assert run.workspace_id == ctx.scope.workspace.id
    run
  end

  describe "a queued run" do
    test "is never lost by the lost-run check, however long it waits", ctx do
      queued = queued!(ctx.scope)
      run = record(queued)

      assert Liveness.check(DateTime.add(run.inserted_at, 7, :day)) == []
      assert %Run{state: "pending"} = record(queued)
    end

    test "a rebuild leaves it, and a run that ended while it waited, as they are", ctx do
      queued = queued!(ctx.scope)
      ended = queued!(ctx.scope)

      {:ok, :ok} =
        Repo.transact(fn ->
          {:ok, Dispatches.cancel_for_undo(Repo.get!(WorkItem, ended.work_item_id))}
        end)

      assert %Run{state: "cancelled"} = record(ended)

      for run <- [record(queued), record(ended)], do: {:ok, _run} = Projector.rebuild(run)

      assert %Run{state: "pending"} = record(queued)
      assert Run.queued?(record(queued))
      assert %Run{state: "cancelled", reason: "undone"} = record(ended)
    end

    test "is not pruned by retention", ctx do
      queued = queued!(ctx.scope)
      old = DateTime.add(DateTime.utc_now(), -400, :day)

      Repo.update_all(from(r in Run, where: r.dispatch_run_id == ^queued.id),
        set: [inserted_at: old]
      )

      Repo.update_all(
        from(w in Apiary.Organisations.Workspace, where: w.id == ^ctx.scope.workspace.id),
        set: [events_retention_days: 30]
      )

      refute Retention.due_or_pruned?(record(queued))
    end
  end
end
