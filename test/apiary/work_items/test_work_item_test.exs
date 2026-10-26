defmodule Apiary.WorkItems.TestWorkItemTest do
  # A test work item (`Apiary.WorkItems.take_in_test/2`): what the table holds of it and
  # of every other work item, its changeset, the take in that makes it and queues its
  # first run, who may make one, the Work items list that leaves it out, and the claim,
  # which skips the check of the connection for it alone.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Edition, EditionStubs, Organisations, Repo, WorkItems}
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Settle}
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
      work_item = test_item!(ctx.scope)
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
      assert %WorkItem{target_system: nil} = test_item!(ctx.scope)
      assert [%DispatchRun{state: :waiting}] = runs(test_item!(ctx.scope))

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
        assert {:ok, %WorkItem{test: true, owner_id: owner_id}} =
                 WorkItems.take_in_test(scope, @line)

        assert owner_id == scope.user.id
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
    test "leaves a test work item out of every view, count, band, filter and the sidebar's count",
         ctx do
      %{scope: scope} = ctx

      # Each waits at Confirm for its owner, the reader.
      listed = work_item_fixture(scope)
      test_item = test_item!(scope)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^test_item.id)

      for work_item <- [listed, test_item] do
        %{dispatch_run: run} = explore_run_fixture(work_item, result: understood_result())
        Settle.settle(run.id)
      end

      closed_test = test_item!(scope)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^closed_test.id),
          set: [state: :closed, closed_at: DateTime.utc_now()]
        )

      page = WorkItems.list_work_items(scope)
      assert Enum.map(page.rows, & &1.id) == [listed.public_id]
      assert page.counts == %{open: 1, you: 1, declined: 0, closed: 0}

      for view <- ["you", "closed"] do
        page = WorkItems.list_work_items(scope, %{"view" => view})
        refute test_item.public_id in Enum.map(page.rows, & &1.id)
        refute closed_test.public_id in Enum.map(page.rows, & &1.id)
      end

      bands = WorkItems.list_bands(scope)
      assert [%{id: id}] = Enum.flat_map(Map.values(bands.bands), & &1)
      assert id == listed.public_id

      assert WorkItems.list_filter_values(scope, :owner) == [%{key: scope.user.id, count: 1}]

      assert WorkItems.list_filter_values(scope, :collection) == [
               %{key: listed.collection_title, count: 1}
             ]

      assert WorkItems.list_filter_values(scope, :collection, "Test") == []
      assert WorkItems.count_waiting_on(scope) == 1
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
