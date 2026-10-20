defmodule Apiary.WorkItems.UndoDeclineCloseTest do
  # What a person does to a live work item (`Apiary.WorkItems.undo/2`, `decline/2` and
  # `close/2`): an undo while no claim holds its run, back to how a take in again found
  # it; a decline while none of its runs is live; a close whatever its runs; each with its
  # event, its feed entry where the label changes, its entry in the trail, and each
  # refusal.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, WorkItems}
  alias Apiary.Adapters.Feed
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Nodes.Node
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    %{scope: scope, connection: connection, ticket: ticket, work_item: work_item}
  end

  defp statuses(ticket),
    do: Enum.map(Feed.entries(Repo.get!(Node, ticket.adapter_id)), & &1.data["status"])

  defp runs(work_item),
    do:
      Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id, order_by: r.take_in)

  defp end_runs!(work_item) do
    Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
      set: [state: :ended, end_cause: :run_ended]
    )
  end

  defp kinds(work_item),
    do:
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^work_item.id,
          order_by: [asc: e.at],
          select: e.kind
      )

  defp entry(action, work_item),
    do:
      Repo.one!(
        from e in Entry,
          where: e.action == ^action and e.subject_id == ^work_item.id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp other_workspace_scope(scope),
    do: workspace_scope(scope.user, workspace_fixture(scope.organisation))

  # Ids that are no UUID: a work item carrying one is not found.
  @malformed ["not-a-uuid", nil, %{}, 1]

  # What stands for `work_item`: its row, its events, its runs, its entries in the trail
  # and the statuses the adapter was told.
  defp written(work_item, ticket),
    do: {
      Repo.get!(WorkItem, work_item.id),
      kinds(work_item),
      runs(work_item),
      Repo.aggregate(from(e in Entry, where: e.subject_id == ^work_item.id), :count),
      statuses(ticket)
    }

  describe "undo" do
    test "of a first take in: undone, its waiting run ended, the adapter told", ctx do
      assert {:ok, %WorkItem{state: :undone} = undone} = WorkItems.undo(ctx.scope, ctx.work_item)

      assert [%DispatchRun{state: :ended, end_cause: :undone}] = runs(undone)
      assert kinds(undone) == [:taken_in, :undone]
      assert statuses(ctx.ticket) == ["taken_in", "undone"]

      entry = entry("work_item.undo", undone)
      assert entry.before == %{"state" => "exploring"}
      assert entry.after == %{"state" => "undone"}
      assert entry.details == %{"take_in" => 1}
    end

    test "while a claim holds its run, refused", ctx do
      pool = pool_fixture(ctx.scope)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      {:ok, %{dispatch: _dispatch}} = Dispatches.claim(key, Dispatches.now())

      assert WorkItems.undo(ctx.scope, ctx.work_item) == {:error, :claimed}
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
      assert statuses(ctx.ticket) == ["taken_in"]
    end

    test "once a run of its take in was handed over, refused, after that run ended too", ctx do
      pool = pool_fixture(ctx.scope)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now())
      at = DateTime.add(dispatch.claimed_at, 1, :second)
      ended_at = DateTime.add(at, 1, :second)

      # As the run's end after its handover leaves them.
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [
          dispatched_at: at,
          handed_over_at: at,
          ended_at: ended_at,
          end_cause: :run_ended,
          slot_freed_at: ended_at
        ]
      )

      end_runs!(ctx.work_item)

      assert WorkItems.undo(ctx.scope, ctx.work_item) == {:error, :claimed}
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
      assert statuses(ctx.ticket) == ["taken_in"]
    end

    test "of a take in again of a declined work item: declined again, as it was", ctx do
      end_runs!(ctx.work_item)
      {:ok, declined} = WorkItems.decline(ctx.scope, ctx.work_item)
      %{user: member} = member_fixture(ctx.scope)

      {:ok, again} =
        WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{owner_id: member.id})

      assert {:ok, back} = WorkItems.undo(ctx.scope, again)

      assert back.state == :declined
      assert back.take_in == 2
      assert back.declined_at == declined.declined_at
      assert back.declined_by_id == ctx.scope.user.id
      assert back.owner_id == ctx.scope.user.id
      assert back.taken_in_at == ctx.work_item.taken_in_at
      assert back.taken_in_by_id == ctx.work_item.taken_in_by_id

      assert {back.target_system, back.target_path} ==
               {ctx.work_item.target_system, ctx.work_item.target_path}

      assert statuses(ctx.ticket) == ["taken_in"]
    end

    test "of a take in again of a closed work item: closed again, as it was", ctx do
      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

      assert {:ok, back} = WorkItems.undo(ctx.scope, again)
      assert back.state == :closed
      assert back.closed_at == closed.closed_at
      assert back.closed_by_id == ctx.scope.user.id
      assert statuses(ctx.ticket) == ["taken_in"]
    end

    test "of a take in again of an undone work item: undone again, the adapter told", ctx do
      {:ok, undone} = WorkItems.undo(ctx.scope, ctx.work_item)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

      assert {:ok, back} = WorkItems.undo(ctx.scope, again)
      assert back.state == :undone
      assert back.taken_in_at == undone.taken_in_at
      assert statuses(ctx.ticket) == ["taken_in", "undone", "taken_in", "undone"]
    end

    test "of a work item that is not live, or not in the workspace, refused", ctx do
      {:ok, undone} = WorkItems.undo(ctx.scope, ctx.work_item)
      assert WorkItems.undo(ctx.scope, undone) == {:error, :not_live}

      live = work_item_fixture(ctx.scope)
      assert WorkItems.undo(other_workspace_scope(ctx.scope), live) == {:error, :not_found}

      %{scope: stranger} = sign_up_fixture()
      assert WorkItems.undo(stranger, live) == {:error, :not_found}
    end

    test "of a work item whose id is no UUID, not found, nothing written", ctx do
      before = written(ctx.work_item, ctx.ticket)

      for id <- @malformed do
        assert WorkItems.undo(ctx.scope, %{ctx.work_item | id: id}) ==
                 {:error, :not_found}
      end

      assert written(ctx.work_item, ctx.ticket) == before
    end
  end

  describe "decline" do
    test "of a work item none of whose runs is live: declined, by the person, now", ctx do
      end_runs!(ctx.work_item)

      assert {:ok, %WorkItem{state: :declined} = declined} =
               WorkItems.decline(ctx.scope, ctx.work_item)

      assert declined.declined_by_id == ctx.scope.user.id
      assert %DateTime{} = declined.declined_at
      assert kinds(declined) == [:taken_in, :declined]
      assert statuses(ctx.ticket) == ["taken_in"]

      entry = entry("work_item.decline", declined)
      assert entry.before == %{"state" => "exploring"}
      assert entry.after == %{"state" => "declined"}
    end

    test "while a run of its take in waits, or is claimed, refused", ctx do
      assert WorkItems.decline(ctx.scope, ctx.work_item) == {:error, :running}

      pool = pool_fixture(ctx.scope)
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      {:ok, %{dispatch: _dispatch}} = Dispatches.claim(key, Dispatches.now())

      assert WorkItems.decline(ctx.scope, ctx.work_item) == {:error, :running}
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
    end

    test "of a work item that is not live, or not in the workspace, refused", ctx do
      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      assert WorkItems.decline(ctx.scope, closed) == {:error, :not_live}

      live = work_item_fixture(ctx.scope)
      assert WorkItems.decline(other_workspace_scope(ctx.scope), live) == {:error, :not_found}
    end

    test "of a work item whose id is no UUID, not found, nothing written", ctx do
      before = written(ctx.work_item, ctx.ticket)

      for id <- @malformed do
        assert WorkItems.decline(ctx.scope, %{ctx.work_item | id: id}) ==
                 {:error, :not_found}
      end

      assert written(ctx.work_item, ctx.ticket) == before
    end
  end

  describe "close" do
    test "of a live work item: closed, by the person, its waiting run ended", ctx do
      assert {:ok, %WorkItem{state: :closed} = closed} = WorkItems.close(ctx.scope, ctx.work_item)

      assert closed.closed_by_id == ctx.scope.user.id
      assert [%DispatchRun{state: :ended, end_cause: :closed}] = runs(closed)
      assert kinds(closed) == [:taken_in, :closed]
      assert statuses(ctx.ticket) == ["taken_in"]

      entry = entry("work_item.close", closed)
      assert entry.before == %{"state" => "exploring"}
      assert entry.after == %{"state" => "closed"}
    end

    test "tells the queue and the work items of the workspace", ctx do
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)
      :ok = WorkItems.subscribe(ctx.scope)
      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      id = closed.public_id

      assert_receive {:work_items_changed, [^id]}
      assert_receive {Dispatches, :changed}
    end

    test "of a work item that is not live, or not in the workspace, refused", ctx do
      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      assert WorkItems.close(ctx.scope, closed) == {:error, :not_live}

      live = work_item_fixture(ctx.scope)
      assert WorkItems.close(other_workspace_scope(ctx.scope), live) == {:error, :not_found}
    end

    test "of a work item whose id is no UUID, not found, nothing written", ctx do
      before = written(ctx.work_item, ctx.ticket)

      for id <- @malformed do
        assert WorkItems.close(ctx.scope, %{ctx.work_item | id: id}) ==
                 {:error, :not_found}
      end

      assert written(ctx.work_item, ctx.ticket) == before
    end
  end
end
