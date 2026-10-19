defmodule Apiary.WorkItems.TakeInTest do
  # A first take in of a ticket of the Backlog (`Apiary.WorkItems.take_in/3`): the work
  # item it makes, numbered next in the workspace, with its snapshot of the ticket, its
  # target, its owner and its first instruction; its event, its first run, its feed entry,
  # its entry in the trail and what the pages are told; and each refusal, which changes
  # nothing. Then the lookups a page finds one work item by.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.Adapters.{Collection, Connection, Feed}
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
    %{scope: scope, connection: connection, ticket: ticket}
  end

  defp collection(ticket), do: Repo.get!(Collection, ticket.collection_id)
  defp adapter(ticket), do: Repo.get!(Node, ticket.adapter_id)

  defp events(work_item),
    do:
      Repo.all(
        from e in WorkItemEvent, where: e.work_item_id == ^work_item.id, order_by: [asc: e.at]
      )

  defp runs(work_item),
    do: Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

  defp entries(action),
    do: Repo.all(from e in Entry, where: e.action == ^action)

  defp no_work_item!, do: assert(Repo.aggregate(WorkItem, :count) == 0)

  describe "a first take in" do
    test "makes the work item from the ticket and its collection, as the person, now", ctx do
      %{scope: scope, ticket: ticket} = ctx
      collection = collection(ticket)

      assert {:ok, %WorkItem{} = work_item} = WorkItems.take_in(scope, ticket.public_id)

      assert work_item.organisation_id == scope.organisation.id
      assert work_item.workspace_id == scope.workspace.id
      assert work_item.number == 1
      assert work_item.state == :exploring
      assert work_item.take_in == 1
      assert work_item.connection_id == ctx.connection.id
      assert work_item.adapter_id == ticket.adapter_id
      assert work_item.item_id == ticket.id
      assert work_item.external_ref == ticket.external_ref
      assert work_item.url == ticket.url
      assert work_item.title == ticket.title
      assert work_item.collection_title == collection.title
      assert work_item.target_system == collection.target_system
      assert work_item.target_path == collection.target_path
      assert work_item.owner_id == scope.user.id
      assert work_item.taken_in_by_id == scope.user.id
      assert %DateTime{} = work_item.taken_in_at
      assert work_item.first_instruction == ""
      assert "wi_" <> _ = work_item.public_id
    end

    test "numbers each new work item of the workspace next", ctx do
      {:ok, first} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
      {:ok, second} = WorkItems.take_in(ctx.scope, other.public_id)

      assert {first.number, second.number} == {1, 2}
    end

    test "takes the ticket's target before its collection's", ctx do
      ticket =
        backlog_ticket_fixture(ctx.scope,
          connection: ctx.connection,
          target_system: "code.example.org",
          target_path: "acme/basket"
        )

      {:ok, work_item} = WorkItems.take_in(ctx.scope, ticket.public_id)

      assert {work_item.target_system, work_item.target_path} ==
               {"code.example.org", "acme/basket"}
    end

    test "takes the owner and the first instruction under the string keys a form gives", ctx do
      %{user: member} = member_fixture(ctx.scope)

      {:ok, work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{
          "owner_id" => member.id,
          "first_instruction" => "Look at the basket first."
        })

      assert work_item.owner_id == member.id
      assert work_item.first_instruction == "Look at the basket first."
    end

    test "takes the owner and the first instruction the page gives", ctx do
      %{user: member} = member_fixture(ctx.scope)

      {:ok, work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{
          owner_id: member.id,
          first_instruction: "Look at the basket first.\n\tThen the price."
        })

      assert work_item.owner_id == member.id
      assert work_item.taken_in_by_id == ctx.scope.user.id
      assert work_item.first_instruction == "Look at the basket first.\n\tThen the price."
    end

    test "writes its event, its first run, its feed entry and its entry in the trail", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)

      assert [event] = events(work_item)
      assert event.kind == :taken_in
      assert {event.actor_kind, event.actor_id} == {:person, ctx.scope.user.id}
      assert event.data == %{"take_in" => 1, "before" => nil}

      assert [run] = runs(work_item)
      assert {run.state, run.take_in, run.attempt} == {:waiting, 1, 1}
      assert run.workspace_id == ctx.scope.workspace.id

      assert [%{kind: "work_item", data: data}] = Feed.entries(adapter(ctx.ticket))

      assert data == %{
               "work_item_id" => work_item.public_id,
               "ref" => ctx.ticket.external_ref,
               "status" => "taken_in",
               "url" => WorkItems.stable_url(work_item)
             }

      assert [entry] = entries("work_item.take_in")
      assert {entry.subject_kind, entry.subject_id} == {"work_item", work_item.id}
      assert entry.after == %{"state" => "exploring"}
      assert entry.details == %{"take_in" => 1}
    end

    test "tells the work items and the Backlog of the workspace, by public ids", ctx do
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))
      Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(ctx.scope.workspace.id))

      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      work_item_id = work_item.public_id
      ticket_id = ctx.ticket.public_id

      assert_receive {:work_items_changed, [^work_item_id]}
      assert_receive {:tickets_changed, [^ticket_id]}
    end

    test "a ticket whose work item exists, in any state, is taken", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)

      assert {:error, {:taken, %WorkItem{id: id}}} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id)

      assert id == work_item.id

      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)

      assert {:error, {:taken, %WorkItem{id: ^id}}} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id)

      assert Repo.aggregate(WorkItem, :count) == 1
    end
  end

  describe "a take in refused" do
    test "for a ticket not in the Backlog of the workspace", ctx do
      %{scope: other} = sign_up_fixture()
      foreign = backlog_ticket_fixture(other)
      elsewhere = workspace_fixture(ctx.scope.organisation)

      unassigned =
        backlog_ticket_fixture(ctx.scope,
          connection: ctx.connection,
          collection: %{workspace_id: elsewhere.id}
        )

      for id <- ["tk_nosuchticket00", "not an id", foreign.public_id, unassigned.public_id] do
        assert WorkItems.take_in(ctx.scope, id) == {:error, :not_found}
      end

      no_work_item!()
    end

    test "while the ticket's record, its collection or its connection has ended", ctx do
      now = DateTime.utc_now()

      gone = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
      gone |> Ecto.Changeset.change(disconnected_at: now) |> Repo.update!()
      assert WorkItems.take_in(ctx.scope, gone.public_id) == {:error, :not_found}

      ended = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)

      collection(ended)
      |> Ecto.Changeset.change(ended_at: now, ended_reason: :disconnected)
      |> Repo.update!()

      assert WorkItems.take_in(ctx.scope, ended.public_id) == {:error, :not_found}

      Repo.get!(Connection, ctx.connection.id)
      |> Ecto.Changeset.change(state: :ended, ended_at: now, ended_reason: :adapter_reported)
      |> Repo.update!()

      assert WorkItems.take_in(ctx.scope, ctx.ticket.public_id) == {:error, :not_found}
      no_work_item!()
    end

    test "for a collection assigned there that is not linked", ctx do
      collection(ctx.ticket) |> Ecto.Changeset.change(backlog: false) |> Repo.update!()
      assert WorkItems.take_in(ctx.scope, ctx.ticket.public_id) == {:error, :not_linked}
      no_work_item!()
    end

    test "for a ticket closed at its source", ctx do
      ctx.ticket
      |> Ecto.Changeset.change(state: :closed, state_reason: "completed")
      |> Repo.update!()

      assert WorkItems.take_in(ctx.scope, ctx.ticket.public_id) == {:error, :ticket_closed}
      no_work_item!()
    end

    test "with no target, the ticket's or its collection's", ctx do
      ticket =
        backlog_ticket_fixture(ctx.scope,
          connection: ctx.connection,
          collection: %{target_system: nil, target_path: nil}
        )

      assert WorkItems.take_in(ctx.scope, ticket.public_id) == {:error, :no_target}
      no_work_item!()
    end

    test "with a target a run's variables refuse", ctx do
      for {system, path} <- [
            {"forge.example.com.", "acme/shop"},
            {"forge.example.com", "acme"},
            {"forge.example.com", "acme/shop/basket"},
            {"forge.example.com", "acme/.git"},
            {"forge.example.com", "acme/shop basket"},
            {"forge..example.com", "acme/shop"},
            {".example.com", "acme/shop"},
            {"forge.example.com", "acme/-rf"},
            {"forge.example.com", "-acme/shop"}
          ] do
        ticket =
          backlog_ticket_fixture(ctx.scope,
            connection: ctx.connection,
            collection: %{target_system: system, target_path: path}
          )

        assert WorkItems.take_in(ctx.scope, ticket.public_id) == {:error, :target_invalid},
               inspect({system, path})
      end

      no_work_item!()
    end

    test "for an owner who does not act in the workspace", ctx do
      %{user: stranger} = sign_up_fixture()

      for owner_id <- [stranger.id, Ecto.UUID.generate(), "not an id", 42] do
        assert WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{owner_id: owner_id}) ==
                 {:error, :owner}
      end

      no_work_item!()
    end

    test "for a first instruction a run's input refuses", ctx do
      long = String.duplicate("a", WorkItem.max_instruction() + 1)

      for {text, message} <- [
            {long, "should be at most %{count} character(s)"},
            {"stop\u0007here", "must not contain control characters"},
            {"hidden\u200Bword", "must not contain invisible characters"},
            {"turned\u202Earound", "must not contain invisible characters"}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{first_instruction: text})

        assert {^message, _opts} = changeset.errors[:first_instruction]
      end

      no_work_item!()
      assert Repo.aggregate(DispatchRun, :count) == 0
      assert Feed.entries(adapter(ctx.ticket)) == []
      assert entries("work_item.take_in") == []
    end

    test "to a scope with no workspace", ctx do
      assert WorkItems.take_in(%{ctx.scope | workspace: nil}, ctx.ticket.public_id) ==
               {:error, :not_found}
    end
  end

  describe "in a domain that needs no target" do
    setup ctx, do: %{scope: with_domain(ctx.scope, "general")}

    test "takes in a ticket with no target: the work item has none, and its run waits", ctx do
      ticket =
        backlog_ticket_fixture(ctx.scope,
          connection: ctx.connection,
          collection: %{target_system: nil, target_path: nil}
        )

      assert {:ok, %WorkItem{target_system: nil, target_path: nil} = work_item} =
               WorkItems.take_in(ctx.scope, ticket.public_id)

      assert %WorkItem{target_system: nil, target_path: nil} = Repo.reload!(work_item)
      assert [%DispatchRun{state: :waiting}] = runs(work_item)
    end

    test "keeps the domain's rules for a target there is, and not the software ones", ctx do
      ticket =
        backlog_ticket_fixture(ctx.scope,
          connection: ctx.connection,
          collection: %{target_system: "ads.example.com", target_path: "accounts/1234/-a"}
        )

      assert {:ok, %WorkItem{target_system: "ads.example.com", target_path: "accounts/1234/-a"}} =
               WorkItems.take_in(ctx.scope, ticket.public_id)

      for system <- ["ads..example.com", ".example.com", "ads.example.com."] do
        ticket =
          backlog_ticket_fixture(ctx.scope,
            connection: ctx.connection,
            collection: %{target_system: system, target_path: "accounts/1234"}
          )

        assert WorkItems.take_in(ctx.scope, ticket.public_id) == {:error, :target_invalid},
               system
      end
    end
  end

  describe "the lookups" do
    setup ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      %{work_item: work_item}
    end

    test "find the work item by its number, its public id and its ticket", ctx do
      id = ctx.work_item.id

      assert %WorkItem{id: ^id} = WorkItems.get_by_number(ctx.scope, 1)
      assert %WorkItem{id: ^id} = WorkItems.get_by_number(ctx.scope, "1")
      assert %WorkItem{id: ^id} = WorkItems.get_by_public_id(ctx.scope, ctx.work_item.public_id)
      assert %WorkItem{id: ^id} = WorkItems.get_for_ticket(ctx.scope, ctx.ticket.public_id)
    end

    test "find nothing for another number, a malformed one, or another id", ctx do
      for number <- [
            2,
            0,
            -1,
            "1a",
            "",
            nil,
            String.duplicate("9", 40),
            "9999999999999999999",
            9_223_372_036_854_775_808,
            Integer.pow(10, 40)
          ] do
        assert WorkItems.get_by_number(ctx.scope, number) == nil, inspect(number)
      end

      assert WorkItems.get_by_public_id(ctx.scope, "wi_0000000000000000") == nil
      assert WorkItems.get_by_public_id(ctx.scope, "not an id") == nil
      assert WorkItems.get_for_ticket(ctx.scope, "tk_0000000000000000") == nil
    end

    test "find nothing for another organisation or another workspace", ctx do
      %{scope: other} = sign_up_fixture()
      assert WorkItems.get_by_number(other, 1) == nil
      assert WorkItems.get_by_public_id(other, ctx.work_item.public_id) == nil
      assert WorkItems.get_for_ticket(other, ctx.ticket.public_id) == nil

      elsewhere = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
      assert WorkItems.get_by_number(elsewhere, 1) == nil
      assert WorkItems.get_for_ticket(elsewhere, ctx.ticket.public_id) == nil

      # The stable address finds it in whichever workspace it is now.
      id = ctx.work_item.id
      assert %WorkItem{id: ^id} = WorkItems.get_by_public_id(elsewhere, ctx.work_item.public_id)
    end

    test "find nothing for a person who may not read the workspace's work items", ctx do
      %{scope: other} = sign_up_fixture()
      foreign = %{other | organisation: ctx.scope.organisation, workspace: ctx.scope.workspace}

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      hidden = Apiary.Access.reload(ctx.scope)

      for scope <- [foreign, hidden] do
        assert WorkItems.get_by_number(scope, 1) == nil
        assert WorkItems.get_by_public_id(scope, ctx.work_item.public_id) == nil
        assert WorkItems.get_for_ticket(scope, ctx.ticket.public_id) == nil
      end
    end

    test "a work item of another workspace comes by its state alone, from its ticket and from a take in",
         ctx do
      elsewhere = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))

      # A record of the same ticket in a collection of the other workspace.
      record =
        backlog_ticket_fixture(elsewhere,
          connection: ctx.connection,
          external_ref: ctx.ticket.external_ref
        )

      state_only = %WorkItem{state: :exploring}
      assert WorkItems.get_for_ticket(elsewhere, record.public_id) == state_only
      assert WorkItems.take_in(elsewhere, record.public_id) == {:error, {:taken, state_only}}

      assert WorkItems.take_in_again(elsewhere, record.public_id) ==
               {:error, {:taken, state_only}}

      # In its own workspace, the whole work item.
      id = ctx.work_item.id

      assert {:error, {:taken, %WorkItem{id: ^id}}} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
    end

    test "take_in_answers/2 is none until the questions come", ctx do
      assert WorkItems.take_in_answers(ctx.work_item, 1) == []
    end
  end

  describe "subscribe/1" do
    test "hears the workspace's work items, for a person who may read them", ctx do
      assert :ok = WorkItems.subscribe(ctx.scope)
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      id = work_item.public_id
      assert_receive {:work_items_changed, [^id]}
    end

    test "refuses a scope with no workspace", ctx do
      assert WorkItems.subscribe(%{ctx.scope | workspace: nil}) == {:error, :not_found}
    end
  end
end
