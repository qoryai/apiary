defmodule Apiary.WorkItems.FinishedTest do
  # A work item that finishes (`Apiary.Stages`) and the one check for a finished work item
  # whose ticket has not reopened (`Apiary.WorkItems.Finished`): the close at the last
  # stage, in the same transaction, by the instance; Take in again refused until the
  # ticket reopens at its source; what Take in again does on a reopened ticket; and the row
  # after an undo of it.
  # Not async: a process saved here is read by its stage runner, as `Apiary.StagesTest`.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Processes, Repo, Sources, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Sources.{Backlog, Item}
  alias Apiary.WorkItems.{Finished, WorkItem, WorkItemEvent, WorkList}

  @moduletag needs: [:factory, :workflow_model]

  @stage "st_r79kph11eg"

  setup do
    %{scope: scope} = sign_up_fixture()
    tracker = tracker_fixture(scope)
    {:ok, :accepted} = post(tracker, [item("R")])
    Map.merge(tracker, %{scope: scope, ticket: ticket(tracker)})
  end

  defp post(tracker, items), do: Sources.post_items(tracker.key_scope, items_body("TRK", items))

  defp ticket(tracker), do: Repo.get_by!(Item, collection_id: tracker.collection.id)

  defp later(seconds), do: DateTime.add(at(), seconds, :second)

  defp close_ticket(ctx, seconds),
    do: {:ok, :accepted} = post(ctx, [item("R", state: "closed", updated_at: later(seconds))])

  defp reopen_ticket(ctx, seconds),
    do: {:ok, :accepted} = post(ctx, [item("R", updated_at: later(seconds))])

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp closed_event(work_item),
    do:
      Repo.one!(
        from e in WorkItemEvent, where: e.work_item_id == ^work_item.id and e.kind == :closed
      )

  defp runs(work_item),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [r.take_in, r.attempt]
      )

  defp stage(extra) do
    Map.merge(
      %{
        "id" => @stage,
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [%{"workflow" => "explore-a-ticket"}],
        "outputs" => [%{"type" => "proposal", "required" => true}],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      extra
    )
  end

  defp save!(scope, stages) do
    document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
    {:ok, version} = Processes.save(scope, scope.workspace, document)
    version
  end

  defp list_row(ctx, work_item) do
    %{rows: rows} = WorkList.list(ctx.scope, %{view: :closed})
    Enum.find(rows, &(&1.id == work_item.public_id))
  end

  defp ids(scope, view),
    do: Enum.map(Backlog.list_tickets(scope, %{view: view}).rows, & &1.id)

  describe "the last stage" do
    test "a confirmation closes the work item, by the instance, in the same step", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)

      assert %WorkItem{
               state: :closed,
               closed_at: %DateTime{},
               closed_by_id: nil,
               stage_id: @stage,
               stage_state: :done
             } = work_item

      assert %WorkItemEvent{actor_kind: :instance, actor_id: nil, data: data} =
               closed_event(work_item)

      assert data["reason"] == "last_stage_done"
      assert Stages.status(work_item).state == :done
    end

    test "a gate that needs no person closes it at the run's end", ctx do
      save!(ctx.scope, [stage(%{"gate" => %{"kind" => "none"}})])
      {:ok, taken} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)

      closed = end_run!(reload(taken), understood_result())

      assert %WorkItem{state: :closed, closed_by_id: nil, stage_state: :done} = closed
      assert closed_event(closed).data["reason"] == "last_stage_done"
    end

    test "a stage before the last leaves it live", ctx do
      save!(ctx.scope, [
        stage(%{}),
        stage(%{"id" => "st_p9w5cvh311", "name" => "Shape", "sequence" => [], "outputs" => []})
      ])

      {:ok, taken} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      work_item = end_run!(reload(taken), understood_result())
      {:ok, _confirmed} = WorkItems.confirm(ctx.scope, work_item, 1)

      assert %WorkItem{state: :exploring, closed_at: nil, stage_id: "st_p9w5cvh311"} =
               reload(work_item)
    end

    test "tells the work items' topic once it commits", ctx do
      one_stage_process_fixture(ctx.scope)
      {:ok, taken} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      work_item = end_run!(reload(taken), understood_result())
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))

      {:ok, _approved} =
        Stages.approve(ctx.scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      assert_received {:work_items_changed, ids}
      assert work_item.public_id in ids
      assert %WorkItem{state: :closed} = reload(work_item)
    end
  end

  describe "the check" do
    setup ctx do
      %{work_item: finished_fixture(ctx.scope, ctx.ticket)}
    end

    test "holds while the ticket stays open, and while it stays closed", ctx do
      assert Finished.finished?(ctx.work_item, ticket(ctx))
      close_ticket(ctx, 60)
      assert %Item{state: :closed, last_closed_at: %DateTime{}} = ticket(ctx)
      assert Finished.finished?(ctx.work_item, ticket(ctx))
    end

    test "ends once the ticket closed after the work item finished, and reopened", ctx do
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)

      refute Finished.finished?(ctx.work_item, ticket(ctx))
    end

    test "an edit of the ticket is no reopening", ctx do
      {:ok, :accepted} = post(ctx, [item("R", title: "A new title", updated_at: later(60))])

      assert Finished.finished?(ctx.work_item, ticket(ctx))
    end

    test "a close and a reopening before the work item finished count for nothing", ctx do
      {1, _} =
        Repo.update_all(from(i in Item, where: i.id == ^ticket(ctx).id),
          set: [last_closed_at: DateTime.add(ctx.work_item.closed_at, -60, :second)]
        )

      assert Finished.finished?(ctx.work_item, ticket(ctx))
    end
  end

  describe "a work item a person closed" do
    test "is no finished work item, whatever its stage", ctx do
      one_stage_process_fixture(ctx.scope)
      {:ok, taken} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, closed} = WorkItems.close(ctx.scope, taken)

      refute Finished.finished?(closed, ticket(ctx))

      assert {:ok, %WorkItem{state: :exploring}} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
    end
  end

  describe "Take in again" do
    setup ctx do
      %{work_item: finished_fixture(ctx.scope, ctx.ticket)}
    end

    test "is refused while the ticket has not reopened, and changes nothing", ctx do
      before = reload(ctx.work_item)
      number = before.number

      assert {:error, {:taken, %WorkItem{number: ^number}}} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

      assert reload(ctx.work_item) == before
      refute WorkItems.take_in_again?(before)
    end

    test "is refused as closed while the ticket is closed at its source", ctx do
      close_ticket(ctx, 60)

      assert WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id) ==
               {:error, :ticket_closed}

      refute WorkItems.take_in_again?(ctx.work_item)
    end

    test "on a reopened ticket moves the same row to Explore, at run 1 of 3", ctx do
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      assert WorkItems.take_in_again?(ctx.work_item)
      assert %WorkItem{state: :closed, stage_state: :done} = reload(ctx.work_item)
      [first_run] = runs(ctx.work_item)

      assert {:ok, %WorkItem{} = again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

      assert again.id == ctx.work_item.id

      assert %WorkItem{state: :exploring, take_in: 2, closed_at: nil, stage_state: :running} =
               reload(again)

      assert [^first_run, %DispatchRun{take_in: 2, attempt: 1, of: 3}] = runs(again)

      assert Repo.aggregate(
               from(w in WorkItem, where: w.external_ref == ^again.external_ref),
               :count
             ) == 1
    end

    test "finishing again holds it in Taken in, until the ticket reopens once more", ctx do
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
      work_item = end_run!(reload(again), understood_result())
      {:ok, _confirmed} = WorkItems.confirm(ctx.scope, work_item, 1)

      assert %WorkItem{state: :closed, stage_state: :done, take_in: 2} = reload(work_item)
      assert ids(ctx.scope, :taken) == [ctx.ticket.public_id]
      assert ids(ctx.scope, :open) == []
    end
  end

  describe "an undo of a take in again, without a place to put back" do
    setup ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
      %{work_item: work_item, again: reload(again)}
    end

    test "an event written before the place was kept leaves the place as it is", ctx do
      place = [
        :process_version_id,
        :stage_id,
        :stage_state,
        :stage_round,
        :stage_entry,
        :loop_entry
      ]

      {1, _rows} =
        Repo.update_all(
          from(e in WorkItemEvent,
            where: e.work_item_id == ^ctx.again.id and e.kind == :taken_in,
            where: fragment("?->>'take_in' = '2'", e.data),
            update: [
              set: [
                data:
                  fragment(
                    "jsonb_set(?, '{before}', (? -> 'before') - ARRAY['workspace_id', 'process_version_id', 'stage_id', 'stage_state', 'stage_round', 'stage_entry', 'loop_entry'])",
                    e.data,
                    e.data
                  )
              ]
            ]
          ),
          []
        )

      {:ok, undone} = WorkItems.undo(ctx.scope, ctx.again)

      assert %WorkItem{state: :closed} = undone
      assert Map.take(undone, place) == Map.take(ctx.again, place)
    end

    test "a work item its take in again moved to another workspace gets no place", ctx do
      place = [
        :process_version_id,
        :stage_id,
        :stage_state,
        :stage_round,
        :stage_entry,
        :loop_entry
      ]

      {1, _rows} =
        Repo.update_all(
          from(e in WorkItemEvent,
            where: e.work_item_id == ^ctx.again.id and e.kind == :taken_in,
            where: fragment("?->>'take_in' = '2'", e.data),
            update: [
              set: [
                data:
                  fragment(
                    "jsonb_set(?, '{before,workspace_id}', to_jsonb(?::text))",
                    e.data,
                    ^Ecto.UUID.generate()
                  )
              ]
            ]
          ),
          []
        )

      {:ok, undone} = WorkItems.undo(ctx.scope, ctx.again)

      assert %WorkItem{state: :closed} = undone
      assert Map.take(undone, place) == Map.new(place, &{&1, nil})
      assert Map.take(reload(undone), place) == Map.new(place, &{&1, nil})
    end
  end

  describe "an undo of a take in again" do
    setup ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
      {:ok, undone} = WorkItems.undo(ctx.scope, again)
      %{work_item: work_item, undone: undone}
    end

    test "puts it back in Closed, as it had finished, with the row's reason", ctx do
      assert %WorkItem{state: :closed, closed_by_id: nil} = ctx.undone
      assert ctx.undone.closed_at == ctx.work_item.closed_at

      assert %{state: :closed, ended_by_id: nil, ended_reason: "last_stage_done"} =
               list_row(ctx, ctx.undone)
    end

    test "puts back its place in the process: every stage done", ctx do
      place = [
        :process_version_id,
        :stage_id,
        :stage_state,
        :stage_round,
        :stage_entry,
        :loop_entry
      ]

      assert %WorkItem{stage_state: :done} = ctx.undone
      assert Map.take(ctx.undone, place) == Map.take(ctx.work_item, place)
    end

    test "leaves the ticket in Open with Take in again, as it stays reopened", ctx do
      assert ids(ctx.scope, :open) == [ctx.ticket.public_id]
      assert ids(ctx.scope, :taken) == []
      assert WorkItems.take_in_again?(ctx.undone)

      assert {:ok, %WorkItem{state: :exploring, take_in: 3}} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
    end
  end
end
