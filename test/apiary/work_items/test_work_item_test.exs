defmodule Apiary.WorkItems.TestWorkItemTest do
  # A test work item (`Apiary.WorkItems.take_in_test/2`): what the table holds of it and
  # of every other work item, its changeset, the take in that makes it and queues its
  # first run, who may make one, the Work items list that shows it, and the claim,
  # which skips the check of the connection for it alone.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [handed_over: 4, workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [event_fixture: 4]
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Edition, EditionStubs, Organisations, Repo, WorkItems}
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Settle}
  alias Apiary.Runs.{Liveness, Projector, Run}
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: :factory

  @line "Hello! Where are you running?"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  defp update!(id, assignments, params \\ []) do
    Repo.query!("UPDATE work_items SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  defp test_item!(scope, line \\ @line) do
    {:ok, work_item} = WorkItems.take_in_test(scope, line)
    work_item
  end

  # `work_item` closed, straight in the database, so that the workspace may take in another
  # test.
  defp close!(work_item) do
    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now()]
      )

    work_item
  end

  defp runs(work_item),
    do: Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

  defp nothing_written! do
    assert Repo.aggregate(WorkItem, :count) == 0
    assert Repo.aggregate(DispatchRun, :count) == 0
    assert Repo.aggregate(WorkItemEvent, :count) == 0
    refute Repo.exists?(from e in Entry, where: e.action == "work_item.take_in")
  end

  describe "work_items" do
    test "a test work item has no connection, adapter, ticket, ref or address", ctx do
      item = test_item!(ctx.scope)
      connection = ticket_connection_fixture(ctx.scope)
      ticket = source_item_fixture(ctx.scope, connection: connection)

      for {assignments, params} <- [
            {"connection_id = $2, adapter_id = $3",
             [Ecto.UUID.dump!(connection.id), Ecto.UUID.dump!(connection.adapter_id)]},
            {"connection_id = $2", [Ecto.UUID.dump!(connection.id)]},
            {"adapter_id = $2", [Ecto.UUID.dump!(connection.adapter_id)]},
            {"item_id = $2", [Ecto.UUID.dump!(ticket.id)]},
            {"external_ref = $2", ["acme/shop#12"]},
            {"url = $2", ["https://forge.example.com/acme/shop/issues/12"]}
          ] do
        refused("work_items_test_check", fn -> update!(item.id, assignments, params) end)
      end
    end

    test "any other work item has its connection, adapter, ref and address, and is no test",
         ctx do
      item = work_item_fixture(ctx.scope)
      assert %WorkItem{test: false} = Repo.reload!(item)

      for assignments <- [
            "test = true",
            "connection_id = NULL",
            "adapter_id = NULL",
            "connection_id = NULL, adapter_id = NULL",
            "external_ref = NULL",
            "url = NULL",
            "test = true, connection_id = NULL, adapter_id = NULL"
          ] do
        refused("work_items_test_check", fn -> update!(item.id, assignments) end)
      end

      # Its ticket's row may still go, as before.
      assert %{num_rows: 1} = update!(item.id, "item_id = NULL")
    end

    test "the key to the connection is MATCH SIMPLE, NO ACTION, on the same columns" do
      assert %{rows: [[definition, "s", "a"]]} =
               Repo.query!(
                 "SELECT pg_get_constraintdef(oid), confmatchtype::text, confdeltype::text " <>
                   "FROM pg_constraint WHERE conname = 'work_items_connection_id_fkey'"
               )

      assert definition ==
               "FOREIGN KEY (connection_id, organisation_id, adapter_id) " <>
                 "REFERENCES adapter_connections(id, organisation_id, adapter_id)"
    end

    test "the key still holds a work item that is no test to a connection of its organisation and adapter",
         ctx do
      item = work_item_fixture(ctx.scope)
      %{scope: other} = sign_up_fixture()
      theirs = ticket_connection_fixture(other)
      another = ticket_connection_fixture(ctx.scope)

      for id <- [theirs.id, another.id, Ecto.UUID.generate()] do
        refused("work_items_connection_id_fkey", fn ->
          update!(item.id, "connection_id = $2", [Ecto.UUID.dump!(id)])
        end)
      end
    end
  end

  describe "test_changeset/2" do
    defp changeset(attrs), do: WorkItem.test_changeset(%WorkItem{}, attrs)

    test "takes the line as the title, sets test, a fixed collection title and take in 1" do
      owner_id = Ecto.UUID.generate()
      changeset = changeset(%{title: @line, owner_id: owner_id})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :title) == @line
      assert Ecto.Changeset.get_change(changeset, :test) == true

      assert Ecto.Changeset.get_change(changeset, :collection_title) ==
               WorkItem.test_collection_title()

      assert Ecto.Changeset.get_change(changeset, :take_in) == 1
      assert "wi_" <> _ = Ecto.Changeset.get_change(changeset, :public_id)
    end

    test "takes no connection, adapter, ticket, ref, address or target, whatever it is given" do
      changeset =
        changeset(%{
          title: @line,
          owner_id: Ecto.UUID.generate(),
          connection_id: Ecto.UUID.generate(),
          adapter_id: Ecto.UUID.generate(),
          item_id: Ecto.UUID.generate(),
          external_ref: "acme/shop#12",
          url: "https://forge.example.com/acme/shop/issues/12",
          target_system: "forge.example.com",
          target_path: "acme/shop",
          collection_title: "acme/shop"
        })

      assert changeset.valid?

      for field <- [
            :connection_id,
            :adapter_id,
            :item_id,
            :external_ref,
            :url,
            :target_system,
            :target_path
          ] do
        assert Ecto.Changeset.get_field(changeset, field) == nil, inspect(field)
      end

      assert Ecto.Changeset.get_field(changeset, :collection_title) ==
               WorkItem.test_collection_title()
    end

    test "asks for the line, within the title's bounds, and the owner" do
      owner_id = Ecto.UUID.generate()

      assert %{title: ["can't be blank"], owner_id: ["can't be blank"]} =
               errors_on(changeset(%{}))

      for line <- [nil, "   ", "\t\n"] do
        assert %{title: ["can't be blank"]} =
                 errors_on(changeset(%{title: line, owner_id: owner_id}))
      end

      assert %{title: ["can't be blank", "should be at least 1 character(s)"]} =
               errors_on(changeset(%{title: "", owner_id: owner_id}))

      assert %{title: ["is invalid"]} = errors_on(changeset(%{title: 42, owner_id: owner_id}))

      assert %{title: ["should be at most 1024 character(s)"]} =
               errors_on(changeset(%{title: String.duplicate("é", 1025), owner_id: owner_id}))

      assert changeset(%{title: String.duplicate("é", 1024), owner_id: owner_id}).valid?
    end

    test "refuses a line with a character a run's input refuses" do
      owner_id = Ecto.UUID.generate()

      for {line, message} <- [
            {"stop\u0007here", "must not contain control characters"},
            {"hidden\u200Bword", "must not contain invisible characters"},
            {"turned\u202Earound", "must not contain invisible characters"}
          ] do
        assert %{title: [^message]} = errors_on(changeset(%{title: line, owner_id: owner_id}))
      end
    end
  end

  describe "take_in_test/2" do
    test "makes a test work item of the line, owned and taken in by the person, now", ctx do
      %{scope: scope} = ctx
      before = DateTime.utc_now()

      assert {:ok, %WorkItem{} = work_item} = WorkItems.take_in_test(scope, @line)
      assert %WorkItem{test: true} = Repo.get!(WorkItem, work_item.id)

      assert work_item.test
      assert work_item.organisation_id == scope.organisation.id
      assert work_item.workspace_id == scope.workspace.id
      assert work_item.number == 1
      assert work_item.state == :exploring
      assert work_item.take_in == 1
      assert work_item.title == @line
      assert work_item.collection_title == WorkItem.test_collection_title()
      assert work_item.first_instruction == ""
      assert {work_item.owner_id, work_item.taken_in_by_id} == {scope.user.id, scope.user.id}
      assert DateTime.compare(work_item.taken_in_at, before) != :lt

      for field <- [
            :connection_id,
            :adapter_id,
            :item_id,
            :external_ref,
            :url,
            :target_system,
            :target_path
          ] do
        assert Map.fetch!(work_item, field) == nil, inspect(field)
      end
    end

    test "numbers it next in the workspace, after a work item taken in from a ticket", ctx do
      ticket_item = work_item_fixture(ctx.scope)
      work_item = close!(test_item!(ctx.scope))
      assert {ticket_item.number, work_item.number} == {1, 2}
      assert test_item!(ctx.scope).number == 3
    end

    test "writes its event, its first run and its entry in the trail", ctx do
      work_item = test_item!(ctx.scope)

      assert [event] = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^work_item.id)
      assert event.kind == :taken_in
      assert {event.actor_kind, event.actor_id} == {:person, ctx.scope.user.id}
      assert event.data == %{"take_in" => 1, "before" => nil}

      assert [run] = runs(work_item)
      assert {run.state, run.step, run.take_in, run.attempt} == {:waiting, "explore", 1, 1}
      assert run.workspace_id == ctx.scope.workspace.id

      assert [entry] = Repo.all(from e in Entry, where: e.action == "work_item.take_in")
      assert {entry.subject_kind, entry.subject_id} == {"work_item", work_item.id}
      assert entry.after == %{"state" => "exploring"}
      assert entry.details == %{"take_in" => 1, "test" => true}
    end

    test "tells the workspace's work items and its queue, by public id", ctx do
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      work_item = test_item!(ctx.scope)
      id = work_item.public_id

      assert_receive {:work_items_changed, [^id]}
      assert_receive {Dispatches, :changed}
    end

    test "needs no target in a domain that needs one, nor in one that does not", ctx do
      assert %WorkItem{target_system: nil} = software = test_item!(ctx.scope)
      assert [%DispatchRun{state: :waiting}] = runs(software)
      close!(software)

      general = with_domain(ctx.scope, "general")
      assert %WorkItem{target_system: nil} = work_item = test_item!(general)
      assert [%DispatchRun{state: :waiting}] = runs(work_item)
    end

    test "refuses a line the changeset refuses, and writes nothing", ctx do
      for line <- [nil, "", "  ", 42, String.duplicate("t", 1025), "stop\u0007here"] do
        assert {:error, %Ecto.Changeset{} = changeset} = WorkItems.take_in_test(ctx.scope, line)
        assert changeset.errors[:title], inspect(line)
      end

      nothing_written!()
    end
  end

  describe "who may take in a test" do
    test "every member of the workspace, as for a take in", ctx do
      admin = member_fixture(ctx.scope, :admin)
      member = member_fixture(ctx.scope)

      for scope <- [admin.scope, member.scope] do
        assert {:ok, %WorkItem{test: true, owner_id: owner_id} = work_item} =
                 WorkItems.take_in_test(scope, @line)

        assert owner_id == scope.user.id
        close!(work_item)
      end
    end

    test "nobody outside the workspace, nobody it is hidden from, and no scope without one",
         ctx do
      %{scope: other} = sign_up_fixture()
      foreign = %{other | organisation: ctx.scope.organisation, workspace: ctx.scope.workspace}

      assert {:error, reason} = WorkItems.take_in_test(foreign, @line)
      assert reason in [:not_found, :forbidden]

      assert WorkItems.take_in_test(%{ctx.scope | workspace: nil}, @line) == {:error, :not_found}

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      assert WorkItems.take_in_test(ctx.scope, @line) == {:error, :not_found}

      nothing_written!()
    end

    test "nobody removed from the organisation", ctx do
      member = member_fixture(ctx.scope)
      {:ok, _} = Organisations.remove_member(ctx.scope, member.membership.id)

      assert {:error, _refused} = WorkItems.take_in_test(member.scope, @line)
      nothing_written!()
    end
  end

  describe "the Work items list" do
    test "shows a test work item in every view, count, band, owner filter and the sidebar's count",
         ctx do
      %{scope: scope} = ctx

      closed_test = close!(test_item!(scope))

      # Each waits at Confirm for its owner, the reader.
      listed = work_item_fixture(scope)
      test_item = test_item!(scope)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^test_item.id)

      for work_item <- [listed, test_item] do
        %{dispatch_run: run} = explore_run_fixture(work_item, result: understood_result())
        Settle.settle(run.id)
      end

      page = WorkItems.list_work_items(scope)

      assert Enum.sort(Enum.map(page.rows, & &1.id)) ==
               Enum.sort([listed.public_id, test_item.public_id])

      assert page.counts == %{open: 2, you: 2, declined: 0, closed: 1}

      row = Enum.find(page.rows, &(&1.id == test_item.public_id))

      assert {row.number, row.title, row.test, row.integration, row.key} ==
               {test_item.number, @line, true, nil, nil}

      assert %{test: false, integration: integration} =
               Enum.find(page.rows, &(&1.id == listed.public_id))

      assert is_binary(integration)

      closed = WorkItems.list_work_items(scope, %{"view" => "closed"})
      assert Enum.map(closed.rows, & &1.id) == [closed_test.public_id]

      bands = WorkItems.list_bands(scope)
      ids = bands.bands |> Map.values() |> Enum.concat() |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([listed.public_id, test_item.public_id])

      assert WorkItems.list_filter_values(scope, :owner) == [%{key: scope.user.id, count: 3}]
      assert WorkItems.count_waiting_on(scope) == 2

      # Its collection title is no collection, so the Filter menu offers it as none.
      assert WorkItems.list_filter_values(scope, :collection) == [
               %{key: listed.collection_title, count: 1}
             ]

      assert WorkItems.list_filter_values(scope, :collection, "Test") == []
    end

    test "a collection filter lists no test work item, even for a collection titled as its",
         ctx do
      test_item = test_item!(ctx.scope)

      # A real collection with the title a test work item keeps for the column.
      connection = ticket_connection_fixture(ctx.scope)

      collection =
        source_collection_fixture(ctx.scope, connection, %{title: test_item.collection_title})

      item = source_item_fixture(ctx.scope, collection: collection)

      titled =
        work_item_fixture(ctx.scope, %{
          connection_id: connection.id,
          item_id: item.id,
          collection_title: test_item.collection_title
        })

      page = WorkItems.list_work_items(ctx.scope, %{"collection" => ["Test run"]})
      assert Enum.map(page.rows, & &1.id) == [titled.public_id]
      assert page.counts == %{open: 1, you: 0, declined: 0, closed: 0}

      assert WorkItems.list_filter_values(ctx.scope, :collection) == [
               %{key: "Test run", count: 1}
             ]
    end

    test "finds a test work item by its line", ctx do
      test_item = test_item!(ctx.scope)
      _listed = work_item_fixture(ctx.scope)

      page = WorkItems.list_work_items(ctx.scope, %{"search" => "where are you"})
      assert Enum.map(page.rows, & &1.id) == [test_item.public_id]
    end
  end

  describe "one live test a workspace" do
    # The live test work item of the scope with its queued run replaced by one of `opts`
    # (`explore_run_fixture/2`).
    defp test_with_run!(scope, opts) do
      work_item = test_item!(scope)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      %{dispatch_run: run} = explore_run_fixture(work_item, opts)
      {work_item, run}
    end

    defp refused_while_running!(scope, live) do
      assert WorkItems.take_in_test(scope, "A second line") == {:error, :test_running}

      assert [%WorkItem{id: id, state: :exploring}] = Repo.all(WorkItem)
      assert id == live.id
      assert Repo.all(from e in Entry, where: e.action == "work_item.close") == []
    end

    test "while the live one's run waits for a machine, ends that run, closes it and makes the new one",
         ctx do
      for queued_at <- [DateTime.utc_now(), DateTime.add(DateTime.utc_now(), -301, :second)] do
        last = test_item!(ctx.scope)
        [waiting] = runs(last)

        {1, _rows} =
          Repo.update_all(from(r in DispatchRun, where: r.id == ^waiting.id),
            set: [queued_at: queued_at]
          )

        assert {:ok, %WorkItem{state: :exploring} = next} =
                 WorkItems.take_in_test(ctx.scope, "Once more")

        assert %DispatchRun{state: :ended, end_cause: :closed} = Repo.reload!(waiting)

        assert %WorkItem{state: :closed, closed_by_id: closed_by} = Repo.reload!(last)
        assert closed_by == ctx.scope.user.id

        assert [_entry] =
                 Repo.all(
                   from e in Entry,
                     where: e.action == "work_item.close" and e.subject_id == ^last.id
                 )

        assert [%DispatchRun{state: :waiting}] = runs(next)
        close!(next)
      end
    end

    test "refuses it while the live one's run is claimed or handed over", ctx do
      for state <- [:claimed, :handed_over] do
        {live, _run} = test_with_run!(ctx.scope, state: state)
        refused_while_running!(ctx.scope, live)
        Repo.delete_all(WorkItem)
      end
    end

    test "once the live one's runs have all ended, closes it as the person, then makes the new one",
         ctx do
      for opts <- [
            [end_cause: :lost],
            [end_cause: :inputs_invalid],
            [end_cause: :ticket_gone],
            [end_cause: :released],
            [end_cause: :run_ended],
            [end_cause: :run_ended, result: understood_result()],
            [end_cause: :run_ended, result: questions_result()]
          ] do
        {last, run} = test_with_run!(ctx.scope, opts)
        if opts[:result], do: Settle.settle(run.id)

        assert {:ok, %WorkItem{state: :exploring} = next} =
                 WorkItems.take_in_test(ctx.scope, "Once more"),
               inspect(opts)

        assert %WorkItem{state: :closed, closed_by_id: closed_by} = Repo.reload!(last)
        assert closed_by == ctx.scope.user.id

        assert [%WorkItemEvent{actor_kind: :person}] =
                 Repo.all(
                   from e in WorkItemEvent,
                     where: e.work_item_id == ^last.id and e.kind == :closed
                 )

        assert [entry] =
                 Repo.all(
                   from e in Entry,
                     where: e.action == "work_item.close" and e.subject_id == ^last.id
                 )

        assert {entry.before, entry.after} == {%{"state" => "exploring"}, %{"state" => "closed"}}
        assert [%DispatchRun{state: :waiting}] = runs(next)
        close!(next)
      end
    end

    test "tells the workspace of the one it closed and the one it made", ctx do
      {last, _run} = test_with_run!(ctx.scope, end_cause: :lost)
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))

      next = test_item!(ctx.scope)
      assert_receive {:work_items_changed, ids}
      assert Enum.sort(ids) == Enum.sort([last.public_id, next.public_id])
    end

    test "a line the changeset refuses leaves the live one as it was", ctx do
      {last, _run} = test_with_run!(ctx.scope, end_cause: :lost)

      assert {:error, %Ecto.Changeset{}} = WorkItems.take_in_test(ctx.scope, "")
      assert %WorkItem{state: :exploring} = Repo.reload!(last)
      assert Repo.all(from e in Entry, where: e.action == "work_item.close") == []
    end

    test "takes in another once the live one is undone, declined or closed", ctx do
      undone = test_item!(ctx.scope)
      {:ok, _undone} = WorkItems.undo(ctx.scope, undone)

      declined = test_item!(ctx.scope)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^declined.id)
      {:ok, _declined} = WorkItems.decline(ctx.scope, declined)

      closed = test_item!(ctx.scope)
      {:ok, _closed} = WorkItems.close(ctx.scope, closed)

      assert %WorkItem{state: :exploring} = test_item!(ctx.scope)
    end

    test "counts only the workspace's test work items", ctx do
      _ticket_item = work_item_fixture(ctx.scope)
      _live = test_item!(ctx.scope)

      elsewhere = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
      assert %WorkItem{workspace_id: workspace_id} = test_item!(elsewhere)
      assert workspace_id == elsewhere.workspace.id
    end

    test "the index refuses a second live test work item in a workspace", ctx do
      ended = close!(test_item!(ctx.scope))
      _live = test_item!(ctx.scope)

      refused("work_items_workspace_id_live_test_index", fn ->
        update!(ended.id, "state = 'exploring', closed_at = NULL")
      end)
    end
  end

  describe "undo, decline and close of a test work item" do
    setup %{scope: scope} do
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(scope.workspace.id))
      Phoenix.PubSub.subscribe(Apiary.PubSub, Apiary.Sources.Topic.topic(scope.workspace.id))
      :ok
    end

    # The work item's change is told on the workspace's work items, and no Backlog hears
    # of it, as it has no ticket.
    defp told!(%WorkItem{public_id: id}) do
      assert_receive {:work_items_changed, [^id]}
      refute_received {:tickets_changed, _ids}
    end

    test "an undo ends its waiting run and makes it undone", ctx do
      work_item = test_item!(ctx.scope)
      [run] = runs(work_item)
      told!(work_item)

      assert {:ok, %WorkItem{state: :undone}} = WorkItems.undo(ctx.scope, work_item)
      assert %DispatchRun{state: :ended, end_cause: :undone} = Repo.reload!(run)
      told!(work_item)
    end

    test "a decline works once no run of it is live", ctx do
      work_item = test_item!(ctx.scope)
      told!(work_item)

      assert WorkItems.decline(ctx.scope, work_item) == {:error, :running}

      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      assert {:ok, %WorkItem{state: :declined}} = WorkItems.decline(ctx.scope, work_item)
      told!(work_item)
    end

    test "a close ends its waiting run and closes it", ctx do
      work_item = test_item!(ctx.scope)
      [run] = runs(work_item)
      told!(work_item)

      assert {:ok, %WorkItem{state: :closed}} = WorkItems.close(ctx.scope, work_item)
      assert %DispatchRun{state: :ended} = Repo.reload!(run)
      told!(work_item)
    end
  end

  describe "the lookups" do
    test "find a test work item for a page, by its number and its public id, with no ticket",
         ctx do
      work_item = test_item!(ctx.scope)

      assert WorkItems.get_by_number(ctx.scope, work_item.number).id == work_item.id
      assert WorkItems.get_by_public_id(ctx.scope, work_item.public_id).id == work_item.id

      none = %{
        integration: nil,
        item_noun: nil,
        collection_noun: nil,
        adapter_removed: false,
        uninstalled: false,
        uninstalled_at: nil,
        ticket: nil,
        comments: []
      }

      assert WorkItems.ticket(ctx.scope, work_item) == none
      assert WorkItems.ticket(ctx.scope, work_item, :all) == none

      # The work item pages name it by its collection title alone, with no key.
      name = %{key: nil, collection_title: WorkItem.test_collection_title(), ticket_id: nil}
      assert WorkItems.ticket_names(ctx.scope, [work_item]) == %{work_item.id => name}
    end

    test "read where Explore stands for it and its Thread, as for any work item", ctx do
      work_item = test_item!(ctx.scope)

      assert %{} = WorkItems.explore(ctx.scope, work_item)
      assert is_list(WorkItems.thread(ctx.scope, work_item))
      assert WorkItems.backlog_off(ctx.scope, [work_item]) == MapSet.new()
    end
  end

  describe "the claim" do
    setup %{scope: scope} do
      _gateway = workspace_gateway!(scope)
      pool = pool_fixture(scope)
      %{access_key: key} = enrolled_key_fixture(scope, pool)
      %{key: key}
    end

    defp dispatched?(run),
      do: Repo.exists?(from d in Dispatch, where: d.dispatch_run_id == ^run.id)

    defp run!(run), do: Repo.get!(DispatchRun, run.id)

    defp queue!(work_item) do
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      run
    end

    test "takes the run of a test work item, which has no connection to check", ctx do
      [run] = runs(test_item!(ctx.scope))

      assert {:ok, _taken} = Dispatches.claim(ctx.key, Dispatches.now())

      assert dispatched?(run)
      refute run!(run).end_cause in [:closed, :undone]
    end

    test "while the claim holds its run, a new take in of a test is refused and the run stays claimed",
         ctx do
      last = test_item!(ctx.scope)
      [run] = runs(last)
      assert {:ok, _taken} = Dispatches.claim(ctx.key, Dispatches.now())
      assert %DispatchRun{state: :claimed} = run!(run)

      assert WorkItems.take_in_test(ctx.scope, "Once more") == {:error, :test_running}
      assert %DispatchRun{state: :claimed} = run!(run)
      assert %WorkItem{state: :exploring} = Repo.reload!(last)
      assert [%WorkItem{}] = Repo.all(WorkItem)
    end

    test "after its run, claimed and handed over, ended by its exit or lost, a new take in of a test closes it",
         ctx do
      ends = [
        {:run_ended,
         fn handed ->
           event_fixture(handed.run, 9, "run.exited", %{"state" => "failed", "exit_code" => 1})
           assert {:ok, %Run{}} = Projector.project(handed.run)
         end},
        {:lost, fn handed -> Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second)) end}
      ]

      for {cause, run_end} <- ends do
        last = test_item!(ctx.scope)
        [queued] = runs(last)
        handed = handed_over(ctx.scope, ctx.key, queued, %{})

        # While its run is in progress, a new take in of a test is refused.
        assert WorkItems.take_in_test(ctx.scope, "Once more") == {:error, :test_running}

        run_end.(handed)
        assert %DispatchRun{state: :ended, end_cause: ^cause} = run!(queued)

        assert {:ok, next} = WorkItems.take_in_test(ctx.scope, "Once more")
        assert %WorkItem{state: :closed} = Repo.reload!(last)
        assert [%DispatchRun{state: :waiting}] = runs(next)
        close!(next)
      end
    end

    test "ends the run of a test work item that is not exploring, or moved, and takes none",
         ctx do
      other = workspace_fixture(ctx.scope.organisation)
      now = Dispatches.now()

      ended =
        for {fields, cause} <- [
              {[state: :closed, closed_at: now], :closed},
              {[state: :declined, declined_at: now], :closed},
              {[state: :undone], :undone},
              {[workspace_id: other.id], :closed}
            ] do
          work_item = test_item!(ctx.scope)
          [run] = runs(work_item)

          {1, _rows} =
            Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: fields)

          {run, cause}
        end

      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}

      for {run, cause} <- ended do
        assert %DispatchRun{state: :ended, end_cause: ^cause} = run!(run)
        refute dispatched?(run)
      end
    end

    test "a work item with a connection keeps the check: its run ends closed once the connection ends",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)

      Repo.update_all(from(c in Connection, where: c.id == ^work_item.connection_id),
        set: [state: :ended, ended_at: Dispatches.now(), ended_reason: :adapter_reported]
      )

      assert Dispatches.claim(ctx.key, Dispatches.now()) == {:ok, :none}
      assert %DispatchRun{state: :ended, end_cause: :closed} = run!(run)
      refute dispatched?(run)
    end

    test "a work item with a connection cannot become a test or lose its connection", ctx do
      work_item = work_item_fixture(ctx.scope)

      for assignments <- [
            "test = true",
            "connection_id = NULL, adapter_id = NULL",
            "test = true, connection_id = NULL, adapter_id = NULL"
          ] do
        refused("work_items_test_check", fn -> update!(work_item.id, assignments) end)
      end
    end
  end
end
