defmodule Apiary.WorkItems.TakeInAgainTest do
  # A take in again of an ended work item (`Apiary.WorkItems.take_in_again/3`): live
  # again, its take in counted one more, pointed at the ticket's current record, with the
  # ticket's title and address and its collection's title as they are now; how it had
  # ended kept in its event for an undo; its first run of the new count; the feed told
  # only for one that had ended undone; a move to the scope's workspace, numbered next
  # there; and each refusal.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Adapters.{Collection, Feed}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Sources.Topic
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    %{scope: scope, connection: connection, ticket: ticket, work_item: work_item}
  end

  defp adapter(ticket), do: Repo.get!(Node, ticket.adapter_id)
  defp statuses(ticket), do: Enum.map(Feed.entries(adapter(ticket)), & &1.data["status"])

  # The runs of the work item end, as their run would end them.
  defp end_runs!(work_item) do
    Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
      set: [state: :ended, end_cause: :run_ended]
    )
  end

  defp declined!(ctx) do
    end_runs!(ctx.work_item)
    {:ok, declined} = WorkItems.decline(ctx.scope, ctx.work_item)
    declined
  end

  defp latest_taken_in(work_item),
    do:
      Repo.one(
        from e in WorkItemEvent,
          where: e.work_item_id == ^work_item.id and e.kind == :taken_in,
          order_by: [desc: e.at],
          limit: 1
      )

  test "brings a declined work item back, as the person, now, with its run of the new count",
       ctx do
    declined = declined!(ctx)
    %{user: member} = member_fixture(ctx.scope)

    assert {:ok, %WorkItem{} = again} =
             WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{
               owner_id: member.id,
               first_instruction: "Only the basket, this time."
             })

    assert again.id == ctx.work_item.id
    assert again.number == ctx.work_item.number
    assert again.state == :exploring
    assert again.take_in == 2
    assert again.owner_id == member.id
    assert again.first_instruction == "Only the basket, this time."
    assert again.taken_in_by_id == ctx.scope.user.id
    assert DateTime.compare(again.taken_in_at, ctx.work_item.taken_in_at) == :gt
    assert {again.declined_at, again.declined_by_id} == {nil, nil}
    assert {again.closed_at, again.closed_by_id} == {nil, nil}

    assert [%DispatchRun{state: :waiting, take_in: 2, attempt: 1}] =
             Repo.all(
               from r in DispatchRun,
                 where: r.work_item_id == ^again.id and r.state == :waiting
             )

    event = latest_taken_in(again)
    assert event.data["take_in"] == 2

    assert event.data["before"] == %{
             "state" => "declined",
             "at" => DateTime.to_iso8601(declined.declined_at),
             "by_id" => ctx.scope.user.id,
             "taken_in_by_id" => ctx.scope.user.id,
             "taken_in_at" => DateTime.to_iso8601(ctx.work_item.taken_in_at),
             "owner_id" => ctx.scope.user.id,
             "target_system" => ctx.work_item.target_system,
             "target_path" => ctx.work_item.target_path
           }

    assert [entry] =
             Repo.all(
               from e in Entry,
                 where: e.action == "work_item.take_in",
                 where: fragment("?->>'again' = 'true'", e.details)
             )

    assert entry.before == %{"state" => "declined"}
    assert entry.after == %{"state" => "exploring"}
    assert entry.details == %{"again" => true, "take_in" => 2}
  end

  test "takes the owner and the first instruction under the string keys a form gives", ctx do
    {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
    %{user: member} = member_fixture(ctx.scope)

    {:ok, again} =
      WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{
        "owner_id" => member.id,
        "first_instruction" => "Only the basket."
      })

    assert again.id == closed.id
    assert again.owner_id == member.id
    assert again.first_instruction == "Only the basket."
  end

  test "takes the ticket's title and address and its collection's title as they are now", ctx do
    {:ok, _closed} = WorkItems.close(ctx.scope, ctx.work_item)

    ctx.ticket
    |> Ecto.Changeset.change(
      title: "The checkout keeps the old price in the basket",
      url: "https://forge.example.com/acme/shop-moved/tickets/12"
    )
    |> Repo.update!()

    Repo.get!(Collection, ctx.ticket.collection_id)
    |> Ecto.Changeset.change(title: "acme/shop-moved")
    |> Repo.update!()

    {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

    assert again.title == "The checkout keeps the old price in the basket"
    assert again.url == "https://forge.example.com/acme/shop-moved/tickets/12"
    assert again.collection_title == "acme/shop-moved"
    assert again.external_ref == ctx.work_item.external_ref
    assert again.adapter_id == ctx.work_item.adapter_id
  end

  test "points the work item at the ticket's current record, in another workspace, and moves it there",
       ctx do
    {:ok, _undone} = WorkItems.undo(ctx.scope, ctx.work_item)
    elsewhere = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
    first_there = backlog_ticket_fixture(elsewhere, connection: ctx.connection)
    {:ok, numbered} = WorkItems.take_in(elsewhere, first_there.public_id)

    # The ticket's record ended in the first collection, and a new one came in a
    # collection of the other workspace.
    ctx.ticket |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now()) |> Repo.update!()

    record =
      backlog_ticket_fixture(elsewhere,
        connection: ctx.connection,
        external_ref: ctx.ticket.external_ref,
        title: "The checkout keeps the old price, again"
      )

    Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))
    Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(elsewhere.workspace.id))
    Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(elsewhere.workspace.id))

    assert WorkItems.take_in_again(ctx.scope, record.public_id) == {:error, :not_found}
    assert {:ok, again} = WorkItems.take_in_again(elsewhere, record.public_id)

    assert again.workspace_id == elsewhere.workspace.id
    assert again.number == numbered.number + 1
    assert again.item_id == record.id
    assert again.title == "The checkout keeps the old price, again"
    assert again.take_in == 2

    # Its run of the new count waits in the workspace it moved to; the old run stays.
    assert [run] =
             Repo.all(
               from r in DispatchRun, where: r.work_item_id == ^again.id and r.take_in == 2
             )

    assert run.workspace_id == elsewhere.workspace.id

    id = again.public_id
    record_id = record.public_id
    assert_receive {:work_items_changed, [^id]}
    assert_receive {:work_items_changed, [^id]}
    assert_receive {:tickets_changed, [^record_id]}

    # Its old number is never given again.
    other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
    {:ok, next} = WorkItems.take_in(ctx.scope, other.public_id)
    assert next.number == ctx.work_item.number + 1
  end

  test "tells the adapter taken_in only for a work item that had ended undone", ctx do
    {:ok, _undone} = WorkItems.undo(ctx.scope, ctx.work_item)
    {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
    assert statuses(ctx.ticket) == ["taken_in", "undone", "taken_in"]

    {:ok, _closed} = WorkItems.close(ctx.scope, again)
    {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
    assert statuses(ctx.ticket) == ["taken_in", "undone", "taken_in"]

    end_runs!(again)
    {:ok, _declined} = WorkItems.decline(ctx.scope, again)
    {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
    assert statuses(ctx.ticket) == ["taken_in", "undone", "taken_in"]
    assert again.take_in == 4
  end

  test "in a domain that needs no target, takes in again a ticket that lost its target", ctx do
    declined!(ctx)
    scope = with_domain(ctx.scope, "example")

    Repo.get!(Collection, ctx.ticket.collection_id)
    |> Ecto.Changeset.change(target_system: nil, target_path: nil)
    |> Repo.update!()

    assert {:ok, %WorkItem{state: :exploring, take_in: 2, target_system: nil, target_path: nil}} =
             WorkItems.take_in_again(scope, ctx.ticket.public_id)

    assert %{"target_system" => "forge.example.com"} =
             latest_taken_in(ctx.work_item).data["before"]
  end

  describe "refused" do
    test "for a ticket with no work item", ctx do
      other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
      assert WorkItems.take_in_again(ctx.scope, other.public_id) == {:error, :not_taken}
    end

    test "for a live work item", ctx do
      id = ctx.work_item.id

      assert {:error, {:taken, %WorkItem{id: ^id}}} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
    end

    test "for a ticket closed at its source, with no target or one a run's variables refuse, or an owner not in the workspace",
         ctx do
      declined!(ctx)
      %{user: stranger} = sign_up_fixture()

      assert WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{owner_id: stranger.id}) ==
               {:error, :owner}

      Repo.get!(Collection, ctx.ticket.collection_id)
      |> Ecto.Changeset.change(target_system: nil, target_path: nil)
      |> Repo.update!()

      assert WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id) == {:error, :no_target}

      for {system, path} <- [
            {"forge.example.com.", "acme/shop"},
            {"forge.example.com", "acme"},
            {"forge..example.com", "acme/shop"},
            {"forge.example.com", "acme/-rf"}
          ] do
        Repo.get!(Collection, ctx.ticket.collection_id)
        |> Ecto.Changeset.change(target_system: system, target_path: path)
        |> Repo.update!()

        assert WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id) ==
                 {:error, :target_invalid},
               inspect({system, path})
      end

      ctx.ticket |> Ecto.Changeset.change(state: :closed) |> Repo.update!()
      assert WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id) == {:error, :ticket_closed}

      assert %WorkItem{state: :declined, take_in: 1} = Repo.get!(WorkItem, ctx.work_item.id)
    end

    test "for a first instruction a run's input refuses, which changes nothing", ctx do
      declined!(ctx)

      assert {:error, %Ecto.Changeset{} = changeset} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{
                 first_instruction: "a\u0000b"
               })

      assert {"must not contain control characters", _} = changeset.errors[:first_instruction]
      assert %WorkItem{state: :declined, take_in: 1} = Repo.get!(WorkItem, ctx.work_item.id)
    end
  end
end
