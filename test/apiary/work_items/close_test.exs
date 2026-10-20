defmodule Apiary.WorkItems.CloseTest do
  # The close of a work item (`Apiary.WorkItems.close_locked/3`) and its first caller, the
  # removal of an adapter (`Apiary.Adapters.delete_adapter/2`), which closes, as the
  # instance, every live work item of every organisation whose ticket came through a
  # connection to it: the state, when, who, the work item's event and the queue told; the
  # work items it leaves as they are; the ticket, which keeps its record; a take in after
  # the adapter is added again, which makes a new work item; and the runs of the queue,
  # which end before their handover and go on after it.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Adapters, Dispatches, WorkItems}
  alias Apiary.Adapters.Connection
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: :factory

  setup do
    %{scope: first} = sign_up_fixture()
    %{scope: second} = sign_up_fixture()
    %{adapter: adapter} = connectable_adapter_fixture()
    {first_connection, _nonce} = connection_fixture(first, adapter, :listed)
    {second_connection, _nonce} = connection_fixture(second, adapter, :listed)

    %{
      admin: instance_admin_scope(),
      adapter: adapter,
      first: first,
      second: second,
      first_connection: first_connection,
      second_connection: second_connection
    }
  end

  defp remove!(ctx), do: {:ok, _deleted} = Adapters.delete_adapter(ctx.admin, ctx.adapter)

  defp taken!(scope, connection, attrs \\ %{}),
    do: work_item_fixture(scope, Map.put(Map.new(attrs), :connection_id, connection.id))

  defp queue!(work_item) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  defp claimed!(key) do
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now())
    dispatch
  end

  defp events(work_item),
    do:
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^work_item.id,
          order_by: [asc: e.at, asc: e.kind]
      )

  defp closes(work_item), do: Enum.filter(events(work_item), &(&1.kind == :closed))

  defp run!(run), do: Repo.get!(DispatchRun, run.id)
  defp dispatch!(dispatch), do: Repo.get!(Dispatch, dispatch.id)

  # The pool of the scope's workspace and a key enrolled on it.
  defp pool!(scope) do
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{pool: pool, key: key}
  end

  describe "removing an adapter" do
    test "closes the open work items of its connections in two organisations, as the instance",
         ctx do
      first = taken!(ctx.first, ctx.first_connection)
      second = taken!(ctx.second, ctx.second_connection)
      first_run = queue!(first)
      second_run = queue!(second)

      :ok = Dispatches.subscribe(ctx.first.workspace.id)
      :ok = Dispatches.subscribe(ctx.second.workspace.id)

      remove!(ctx)

      for work_item <- [first, second] do
        assert %WorkItem{state: :closed, closed_at: %DateTime{} = closed_at, closed_by_id: nil} =
                 closed = Repo.get!(WorkItem, work_item.id)

        assert closed.taken_in_at == work_item.taken_in_at

        assert [:taken_in, :closed] = Enum.map(events(work_item), & &1.kind)

        assert [
                 %WorkItemEvent{
                   actor_kind: :instance,
                   actor_id: nil,
                   at: ^closed_at,
                   data: %{"reason" => "adapter_removed"}
                 } = event
               ] = closes(work_item)

        assert event.workspace_id == work_item.workspace_id
        assert event.organisation_id == work_item.organisation_id
      end

      for run <- [first_run, second_run],
          do: assert(%DispatchRun{state: :ended, end_cause: :closed} = run!(run))

      # Each workspace's queue is told once the removal commits.
      assert_received {Dispatches, :changed}
      assert_received {Dispatches, :changed}
      refute_received {Dispatches, :changed}
    end

    test "closes the work items of a connection to it that ended before", ctx do
      before = taken!(ctx.first, ctx.first_connection, external_ref: "acme/shop#1")

      Repo.update_all(from(c in Connection, where: c.id == ^ctx.first_connection.id),
        set: [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
      )

      {connection, _nonce} = connection_fixture(ctx.first, ctx.adapter, :listed)
      now = taken!(ctx.first, connection, external_ref: "acme/shop#2")

      remove!(ctx)

      for work_item <- [before, now] do
        assert Repo.get!(WorkItem, work_item.id).state == :closed
        assert [%WorkItemEvent{actor_kind: :instance}] = closes(work_item)
      end
    end

    test "leaves closed, declined and undone work items as they are", ctx do
      at = ~U[2026-10-16 12:00:00.000000Z]
      user_id = ctx.first.user.id

      ended =
        for {ref, changes} <- [
              {"acme/shop#1", [state: :closed, closed_at: at, closed_by_id: user_id]},
              {"acme/shop#2", [state: :declined, declined_at: at, declined_by_id: user_id]},
              {"acme/shop#3", [state: :undone]}
            ] do
          work_item = taken!(ctx.first, ctx.first_connection, external_ref: ref)
          Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: changes)
          Repo.get!(WorkItem, work_item.id)
        end

      remove!(ctx)

      for work_item <- ended do
        assert Repo.get!(WorkItem, work_item.id) == work_item
        assert [%WorkItemEvent{kind: :taken_in}] = events(work_item)
      end
    end

    test "leaves another adapter's work items as they are", ctx do
      other = work_item_fixture(ctx.first)
      refute other.adapter_id == ctx.adapter.id
      run = queue!(other)

      remove!(ctx)

      assert Repo.get!(WorkItem, other.id) == other
      assert closes(other) == []
      assert %DispatchRun{state: :waiting, end_cause: nil} = run!(run)
    end

    test "leaves the ticket's record as it is", ctx do
      work_item = taken!(ctx.first, ctx.first_connection)
      ticket = Repo.get!(Item, work_item.item_id)

      remove!(ctx)

      assert Repo.get!(WorkItem, work_item.id).state == :closed
      assert Repo.get!(Item, work_item.item_id) == ticket
    end

    test "with no work item removes it as before", ctx do
      assert {:ok, %{deleted_at: %DateTime{}}} = Adapters.delete_adapter(ctx.admin, ctx.adapter)
    end

    test "after the adapter is added again, a take in of the same ticket makes a new work item",
         ctx do
      old = taken!(ctx.first, ctx.first_connection)
      remove!(ctx)

      # Added again: a new adapter under the same name, connected again.
      %{adapter: again} = connectable_adapter_fixture(%{name: ctx.adapter.name})
      refute again.id == ctx.adapter.id
      {connection, _nonce} = connection_fixture(ctx.first, again, :listed)

      ticket =
        source_item_fixture(ctx.first, connection: connection, external_ref: old.external_ref)

      new =
        taken!(ctx.first, connection, item_id: ticket.id, external_ref: old.external_ref)

      refute new.id == old.id
      assert %WorkItem{state: :exploring, adapter_id: adapter_id} = Repo.get!(WorkItem, new.id)
      assert adapter_id == again.id
      assert new.number == old.number + 1
      assert Repo.get!(WorkItem, old.id).state == :closed

      # One work item per ticket of an adapter: the ref under the removed adapter is taken.
      assert {:error, changeset} =
               %WorkItem{
                 organisation_id: ctx.first.organisation.id,
                 workspace_id: ctx.first.workspace.id,
                 number: new.number + 1,
                 state: :exploring,
                 taken_in_by_id: ctx.first.user.id,
                 taken_in_at: DateTime.utc_now()
               }
               |> WorkItem.take_in_changeset(%{
                 connection_id: ctx.first_connection.id,
                 adapter_id: ctx.adapter.id,
                 item_id: old.item_id,
                 external_ref: old.external_ref,
                 url: old.url,
                 title: old.title,
                 collection_title: old.collection_title,
                 target_system: old.target_system,
                 target_path: old.target_path,
                 owner_id: ctx.first.user.id
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).external_ref
    end
  end

  describe "the runs of the queue, at the removal" do
    setup ctx, do: pool!(ctx.first)

    test "a waiting run with no dispatch ends, cause closed", ctx do
      run = ctx.first |> taken!(ctx.first_connection) |> queue!()

      remove!(ctx)

      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)
      assert Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^run.id) == []
      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
    end

    test "a waiting run with a stale dispatch ends closed, and the dispatch run_ended", ctx do
      run = ctx.first |> taken!(ctx.first_connection) |> queue!()
      dispatch = claimed!(ctx.key)
      Dispatches.sweep(dispatch.lease_until)
      assert %DispatchRun{state: :waiting} = run!(run)
      stale = dispatch!(dispatch)

      remove!(ctx)

      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)

      assert %Dispatch{ended_at: %DateTime{}, end_cause: :run_ended} = ended = dispatch!(dispatch)
      assert ended.stale_at == stale.stale_at
      assert ended.slot_freed_at == stale.slot_freed_at
    end

    test "a claimed run ends closed, its live dispatch with it, and its slot is freed once",
         ctx do
      run = ctx.first |> taken!(ctx.first_connection) |> queue!()
      dispatch = claimed!(ctx.key)
      assert Slots.held(ctx.pool.id) == 1
      :ok = Dispatches.subscribe(ctx.first.workspace.id)

      remove!(ctx)

      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)

      assert %Dispatch{
               stale_at: nil,
               handed_over_at: nil,
               ended_at: %DateTime{},
               end_cause: :closed,
               slot_freed_at: %DateTime{} = freed_at
             } = dispatch!(dispatch)

      assert Slots.held(ctx.pool.id) == 0
      assert_received {Dispatches, :changed}

      # Freed once: a later free leaves the first time.
      {:ok, _workspaces} =
        Repo.transact(fn -> {:ok, Slots.free({:runs, [run.id]}, Dispatches.now())} end)

      assert dispatch!(dispatch).slot_freed_at == freed_at
    end

    test "a claimed run whose lease lapsed unswept: the dispatch lapses, then the run ends closed",
         ctx do
      run = ctx.first |> taken!(ctx.first_connection) |> queue!()
      dispatch = claimed!(ctx.key)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [
          claimed_at: DateTime.add(dispatch.claimed_at, -700, :second),
          lease_until: DateTime.add(dispatch.lease_until, -700, :second)
        ]
      )

      remove!(ctx)

      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)

      assert %Dispatch{
               stale_at: %DateTime{},
               slot_freed_at: %DateTime{},
               end_cause: :run_ended
             } = dispatch!(dispatch)

      assert Slots.held(ctx.pool.id) == 0
    end

    test "a handed-over run goes on, its dispatch as it was", ctx do
      work_item = taken!(ctx.first, ctx.first_connection)
      run = queue!(work_item)
      dispatch = claimed!(ctx.key)
      at = DateTime.add(dispatch.claimed_at, 1, :second)

      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at]
      )

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [state: :handed_over])
      handed_over = dispatch!(dispatch)

      remove!(ctx)

      assert Repo.get!(WorkItem, work_item.id).state == :closed
      assert %DispatchRun{state: :handed_over, end_cause: nil} = run!(run)
      assert dispatch!(dispatch) == handed_over
      assert Slots.held(ctx.pool.id) == 1
    end
  end

  describe "close_locked/3" do
    test "a person's close names them, and its event has no reason, only the stage", ctx do
      work_item = taken!(ctx.first, ctx.first_connection)
      user_id = ctx.first.user.id

      assert {:ok, []} =
               Repo.transact(fn ->
                 locked =
                   Repo.one!(from w in WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE")

                 WorkItems.close_locked([locked], {:person, user_id}, Dispatches.now())
               end)

      assert %WorkItem{state: :closed, closed_by_id: ^user_id} = Repo.get!(WorkItem, work_item.id)

      assert [%WorkItemEvent{actor_kind: :person, actor_id: ^user_id, data: data}] =
               closes(work_item)

      assert data == %{"stage" => "explore"}
    end

    test "refuses a work item that is not live, writing nothing", ctx do
      work_item = taken!(ctx.first, ctx.first_connection)
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [state: :undone])
      undone = Repo.get!(WorkItem, work_item.id)

      assert {:error, :not_live} =
               Repo.transact(fn ->
                 WorkItems.close_locked(
                   [undone],
                   {:instance, "adapter_removed"},
                   Dispatches.now()
                 )
               end)

      assert Repo.get!(WorkItem, work_item.id) == undone
      assert closes(work_item) == []
    end

    test "runs only inside the caller's transaction", ctx do
      work_item = taken!(ctx.first, ctx.first_connection)

      assert_raise ArgumentError, fn ->
        WorkItems.close_locked([work_item], {:instance, "adapter_removed"}, Dispatches.now())
      end

      assert_raise ArgumentError, fn ->
        Dispatches.cancel_for_close([work_item.id], Dispatches.now())
      end

      assert_raise ArgumentError, fn ->
        WorkItems.close_for_adapter(ctx.adapter, Dispatches.now())
      end
    end
  end
end
