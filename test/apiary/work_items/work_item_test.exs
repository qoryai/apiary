defmodule Apiary.WorkItems.WorkItemTest do
  # The work items' tables as the migration made them, asked in raw SQL so that no
  # changeset stands between the write and the database, then the changesets.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Adapters.Connection
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  # Sets `assignments` on the row `id` of `table`, with `params` after the id: $2 onwards.
  defp update!(table, id, assignments, params \\ []) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  defp event_of(work_item) do
    Repo.one!(from e in WorkItemEvent, where: e.work_item_id == ^work_item.id)
  end

  # A snapshot within every bound, with `attrs` over it.
  defp snapshot(attrs) do
    Enum.into(attrs, %{
      connection_id: Ecto.UUID.generate(),
      adapter_id: Ecto.UUID.generate(),
      item_id: Ecto.UUID.generate(),
      external_ref: "acme/shop#13",
      url: "https://forge.example.com/acme/shop/issues/13",
      title: "The checkout keeps the old price",
      collection_title: "acme/shop",
      target_system: "forge.example.com",
      target_path: "acme/shop",
      owner_id: Ecto.UUID.generate()
    })
  end

  # The snapshot of a ticket of the setup's connection that no work item names yet.
  defp fresh_snapshot(ctx, attrs \\ %{}) do
    snapshot(
      Enum.into(attrs, %{
        owner_id: ctx.scope.user.id,
        connection_id: ctx.connection.id,
        adapter_id: ctx.connection.adapter_id,
        item_id: ctx.item.id
      })
    )
  end

  # A work item of the scope's workspace before its snapshot, with a number no fixture
  # takes.
  defp new_work_item(scope) do
    %WorkItem{
      organisation_id: scope.workspace.organisation_id,
      workspace_id: scope.workspace.id,
      number: 99,
      state: :exploring,
      taken_in_by_id: scope.user.id,
      taken_in_at: DateTime.utc_now()
    }
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)

    %{
      scope: scope,
      connection: connection,
      item: source_item_fixture(scope, connection: connection, external_ref: "acme/shop#13"),
      work_item: work_item_fixture(scope, connection_id: connection.id)
    }
  end

  describe "work_items" do
    test "a public id is wi_ and sixteen Crockford base32 characters", %{work_item: item} do
      assert Apiary.PublicId.valid?("wi", item.public_id)

      for public_id <- [
            "nd_0123456789abcdef",
            "wi_0123456789ABCDEF",
            "wi_0123456789abcdeu",
            "wi_0123456789abcde",
            "wi0123456789abcdef"
          ] do
        refused("work_items_public_id_check", fn ->
          update!("work_items", item.id, "public_id = $2", [public_id])
        end)
      end

      assert %{num_rows: 1} =
               update!("work_items", item.id, "public_id = $2", [
                 Apiary.PublicId.generate("wi")
               ])
    end

    test "a number is 1 or more, once in a workspace, and again in another", ctx do
      %{scope: scope, work_item: item} = ctx
      second = work_item_fixture(scope)
      assert {item.number, second.number} == {1, 2}

      refused("work_items_number_check", fn ->
        update!("work_items", item.id, "number = 0")
      end)

      refused("work_items_workspace_id_number_index", fn ->
        update!("work_items", second.id, "number = 1")
      end)

      elsewhere = workspace_scope(scope.user, workspace_fixture(scope.organisation))
      assert %WorkItem{number: 1} = work_item_fixture(elsewhere)
    end

    test "the state is exploring, declined, closed or undone; only a closed one has its closing",
         ctx do
      %{scope: scope, work_item: item} = ctx
      closer = Ecto.UUID.dump!(scope.user.id)

      refused("work_items_state_check", fn ->
        update!("work_items", item.id, "state = 'shipped'")
      end)

      for assignments <- [
            "state = 'closed'",
            "closed_at = now()",
            "state = 'undone', closed_at = now()"
          ] do
        refused("work_items_closed_check", fn -> update!("work_items", item.id, assignments) end)
      end

      refused("work_items_closed_check", fn ->
        update!("work_items", item.id, "closed_by_id = $2", [closer])
      end)

      assert %{num_rows: 1} = update!("work_items", item.id, "state = 'undone'")

      refused("work_items_closed_check", fn ->
        update!(
          "work_items",
          item.id,
          "state = 'declined', declined_at = now(), closed_at = now()"
        )
      end)

      assert %{num_rows: 1} =
               update!(
                 "work_items",
                 item.id,
                 "state = 'closed', closed_at = now(), closed_by_id = $2",
                 [closer]
               )

      # Closed by no person: the time alone.
      assert %{num_rows: 1} = update!("work_items", item.id, "closed_by_id = NULL")
    end

    test "the snapshot keeps to its bounds", %{work_item: item} do
      for {column, value, constraint} <- [
            {"external_ref", "", "work_items_external_ref_check"},
            {"external_ref", String.duplicate("é", 201), "work_items_external_ref_check"},
            {"title", "", "work_items_title_check"},
            {"title", String.duplicate("t", 1025), "work_items_title_check"},
            {"collection_title", "", "work_items_collection_title_check"},
            {"collection_title", String.duplicate("c", 1025),
             "work_items_collection_title_check"},
            {"first_instruction", String.duplicate("é", 4001),
             "work_items_first_instruction_check"}
          ] do
        refused(constraint, fn ->
          update!("work_items", item.id, "#{column} = $2", [value])
        end)
      end

      for {column, value} <- [
            {"external_ref", String.duplicate("é", 200)},
            {"title", String.duplicate("t", 1024)},
            {"collection_title", String.duplicate("c", 1024)},
            {"first_instruction", String.duplicate("é", 4000)},
            {"first_instruction", ""}
          ] do
        assert %{num_rows: 1} = update!("work_items", item.id, "#{column} = $2", [value])
      end
    end

    test "an address is https alone, with no user or blank, 2,048 characters at most", ctx do
      %{work_item: item} = ctx

      for url <- [
            "ftp://forge.example.com/acme/shop/issues/12",
            "http://forge.example.com/acme/shop/issues/12",
            "HTTPS://forge.example.com/acme/shop/issues/12",
            "https://",
            "https://user@forge.example.com/acme/shop/issues/12",
            "https://forge.example.com/acme shop",
            "https://forge.example.com/acme\nshop",
            "https://forge.example.com/" <> String.duplicate("a", 2023)
          ] do
        refused("work_items_url_check", fn ->
          update!("work_items", item.id, "url = $2", [url])
        end)
      end

      refused("work_items_test_check", fn -> update!("work_items", item.id, "url = NULL") end)

      for url <- [
            "https://forge.example.com:8443/acme/shop/-/issues/12?tab=notes#note_3",
            "https://forge.example.com?issue=12",
            "https://forge.example.com/" <> String.duplicate("a", 2022)
          ] do
        assert %{num_rows: 1} = update!("work_items", item.id, "url = $2", [url])
      end
    end

    test "a target is a host name to the contract's pattern and a path of 1 to 200", ctx do
      %{work_item: item} = ctx

      for {assignments, params} <- [
            {"target_system = $2", ["Forge.example.com"]},
            {"target_system = $2", ["forge example"]},
            {"target_system = $2", [""]},
            {"target_system = $2", [String.duplicate("a", 254)]},
            {"target_path = $2", [""]},
            {"target_path = $2", [String.duplicate("é", 201)]}
          ] do
        refused("work_items_target_check", fn ->
          update!("work_items", item.id, assignments, params)
        end)
      end

      # Both or neither: a work item of a domain that needs no target may have none.
      for column <- ~w(target_system target_path) do
        refused("work_items_target_pair_check", fn ->
          update!("work_items", item.id, "#{column} = NULL")
        end)
      end

      assert %{num_rows: 1} =
               update!("work_items", item.id, "target_system = NULL, target_path = NULL")

      update!("work_items", item.id, "target_system = $2, target_path = $3", [
        "forge.example.com",
        "acme/shop"
      ])

      for {column, value} <- [
            {"target_system", String.duplicate("a", 253)},
            {"target_system", "git.forge-1.example"},
            {"target_path", String.duplicate("é", 200)},
            {"target_path", "p"}
          ] do
        assert %{num_rows: 1} = update!("work_items", item.id, "#{column} = $2", [value])
      end
    end

    test "a target's system has no empty label; a path's segments are the domain's to check",
         ctx do
      %{work_item: item} = ctx

      for value <- ["forge..example.com", ".example.com", "forge.example.com."] do
        refused("work_items_target_shape_check", fn ->
          update!("work_items", item.id, "target_system = $2", [value])
        end)
      end

      # A segment led by a dash breaks the software domain's rule, which Take in checks
      # in code; the database holds it in no domain.
      for {column, value} <- [
            {"target_system", "git.forge-1.example"},
            {"target_path", "acme/a-b"},
            {"target_path", "a-cme/shop"},
            {"target_path", "-acme/shop"},
            {"target_path", "acme/-rf"},
            {"target_path", "p"}
          ] do
        assert %{num_rows: 1} = update!("work_items", item.id, "#{column} = $2", [value])
      end
    end

    test "a take in is counted from 1", %{work_item: item} do
      assert item.take_in == 1

      refused("work_items_take_in_check", fn ->
        update!("work_items", item.id, "take_in = 0")
      end)

      refused("take_in", fn -> update!("work_items", item.id, "take_in = NULL") end)
      assert %{num_rows: 1} = update!("work_items", item.id, "take_in = 2")
    end

    test "only a declined one has its declining, and the person only with the time", ctx do
      %{scope: scope, work_item: item} = ctx
      decliner = Ecto.UUID.dump!(scope.user.id)

      for {assignments, params} <- [
            {"state = 'declined'", []},
            {"declined_at = now()", []},
            {"declined_by_id = $2", [decliner]},
            {"state = 'declined', declined_by_id = $2", [decliner]}
          ] do
        refused("work_items_declined_check", fn ->
          update!("work_items", item.id, assignments, params)
        end)
      end

      assert %{num_rows: 1} =
               update!(
                 "work_items",
                 item.id,
                 "state = 'declined', declined_at = now(), declined_by_id = $2",
                 [decliner]
               )

      # Declined by no person: the time alone.
      assert %{num_rows: 1} = update!("work_items", item.id, "declined_by_id = NULL")

      assert %WorkItem{state: :declined, declined_at: %DateTime{}} =
               Repo.get!(WorkItem, item.id)

      refused("work_items_declined_check", fn ->
        update!("work_items", item.id, "state = 'exploring'")
      end)

      refused("work_items_declined_by_id_fkey", fn ->
        update!("work_items", item.id, "declined_by_id = $2", [
          Ecto.UUID.dump!(Ecto.UUID.generate())
        ])
      end)
    end

    test "a work item's workspace is of its organisation", %{work_item: item} do
      %{organisation: other} = sign_up_fixture()

      refused("work_items_workspace_id_fkey", fn ->
        update!("work_items", item.id, "organisation_id = $2", [Ecto.UUID.dump!(other.id)])
      end)
    end

    test "a work item's connection is one of its organisation", %{work_item: item} do
      %{scope: other} = sign_up_fixture()
      elsewhere = ticket_connection_fixture(other)

      for id <- [elsewhere.id, Ecto.UUID.generate()] do
        refused("work_items_connection_id_fkey", fn ->
          update!("work_items", item.id, "connection_id = $2", [Ecto.UUID.dump!(id)])
        end)
      end

      refused("work_items_test_check", fn ->
        update!("work_items", item.id, "connection_id = NULL")
      end)
    end

    test "a ticket has one work item in its organisation, live or not", ctx do
      %{scope: scope, connection: connection, work_item: first} = ctx

      # Ended, the work item still holds the ticket's key, so a second work item of the
      # ticket is refused.
      assert %{num_rows: 1} =
               update!("work_items", first.id, "state = 'closed', closed_at = now()")

      for place <- [scope, workspace_scope(scope.user, workspace_fixture(scope.organisation))] do
        assert_raise Ecto.InvalidChangesetError,
                     ~r/external_ref: \{"has already been taken"/,
                     fn ->
                       work_item_fixture(place,
                         connection_id: connection.id,
                         external_ref: first.external_ref
                       )
                     end
      end

      # Past the changeset, the database refuses it all the same.
      refused("work_items_organisation_id_adapter_id_external_ref_index", fn ->
        update!(
          "work_items",
          work_item_fixture(scope, connection_id: connection.id, external_ref: "other").id,
          "external_ref = 'acme/shop#12'"
        )
      end)

      # The changeset names the field.
      assert {:error, changeset} =
               scope
               |> new_work_item()
               |> WorkItem.take_in_changeset(
                 fresh_snapshot(ctx, %{external_ref: first.external_ref})
               )
               |> Repo.insert()

      assert %{external_ref: ["has already been taken"]} = errors_on(changeset)

      # Another ref of the adapter, the same ref through another adapter, or in another
      # organisation, is another ticket.
      assert %WorkItem{} =
               work_item_fixture(scope, connection_id: connection.id, external_ref: "r")

      assert %WorkItem{} = work_item_fixture(scope, external_ref: first.external_ref)

      %{scope: other} = sign_up_fixture()
      assert %WorkItem{} = work_item_fixture(other, external_ref: first.external_ref)
    end

    test "the index is the whole table, not a partial one" do
      assert %{rows: [[definition]]} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes " <>
                   "WHERE indexname = 'work_items_organisation_id_adapter_id_external_ref_index'"
               )

      assert definition =~ "UNIQUE INDEX"
      assert definition =~ "(organisation_id, adapter_id, external_ref)"
      refute definition =~ "WHERE"
    end

    test "nothing is unique on the ticket a work item names", ctx do
      %{scope: scope, connection: connection, work_item: first} = ctx

      assert %WorkItem{item_id: item_id} =
               work_item_fixture(scope,
                 connection_id: connection.id,
                 item_id: first.item_id,
                 external_ref: "acme/shop#12 renamed"
               )

      assert item_id == first.item_id
    end

    test "a work item's ticket is one of its organisation and its adapter", ctx do
      %{scope: scope, work_item: item} = ctx
      %{scope: other} = sign_up_fixture()
      theirs = source_item_fixture(other)
      another_adapter = source_item_fixture(scope)

      for id <- [theirs.id, another_adapter.id, Ecto.UUID.generate()] do
        refused("work_items_item_id_fkey", fn ->
          update!("work_items", item.id, "item_id = $2", [Ecto.UUID.dump!(id)])
        end)
      end
    end

    test "a work item's adapter is its connection's", ctx do
      %{scope: scope, work_item: item} = ctx
      elsewhere = ticket_connection_fixture(scope)

      # With no ticket, so that the ticket's key, which names the adapter too, is not the
      # one that refuses it.
      refused("work_items_connection_id_fkey", fn ->
        update!("work_items", item.id, "item_id = NULL, adapter_id = $2", [
          Ecto.UUID.dump!(elsewhere.adapter_id)
        ])
      end)

      refused("work_items_test_check", fn ->
        update!("work_items", item.id, "adapter_id = NULL")
      end)
    end

    test "stays when its ticket's row goes, with no ticket", %{work_item: item} do
      # SET NULL of item_id alone ("n"), so the organisation and the adapter stay.
      assert %{rows: [["n", definition]]} =
               Repo.query!(
                 "SELECT confdeltype::text, pg_get_constraintdef(oid) FROM pg_constraint " <>
                   "WHERE conname = 'work_items_item_id_fkey'"
               )

      assert definition =~ "ON DELETE SET NULL (item_id)"

      Repo.delete!(%Item{id: item.item_id})

      assert %WorkItem{item_id: nil, adapter_id: adapter_id, external_ref: ref} =
               Repo.get!(WorkItem, item.id)

      assert {adapter_id, ref} == {item.adapter_id, item.external_ref}
    end

    test "stays when its ticket's collection ends and its ticket is disconnected", ctx do
      %{work_item: item} = ctx
      ticket = Repo.get!(Item, item.item_id)

      Repo.query!(
        "UPDATE source_collections SET ended_at = now(), ended_reason = 'disconnected' " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(ticket.collection_id)]
      )

      update!("source_items", ticket.id, "disconnected_at = now()")

      assert %WorkItem{item_id: item_id} = Repo.get!(WorkItem, item.id)
      assert item_id == ticket.id
    end

    test "moves to another workspace of its organisation, and its events follow it", ctx do
      %{scope: scope, work_item: item} = ctx
      elsewhere = workspace_fixture(scope.organisation)
      %{scope: other} = sign_up_fixture()

      assert %{num_rows: 1} =
               update!("work_items", item.id, "workspace_id = $2", [
                 Ecto.UUID.dump!(elsewhere.id)
               ])

      assert %WorkItemEvent{workspace_id: workspace_id} = event_of(item)
      assert workspace_id == elsewhere.id

      refused("work_items_workspace_id_fkey", fn ->
        update!("work_items", item.id, "workspace_id = $2", [
          Ecto.UUID.dump!(other.workspace.id)
        ])
      end)
    end

    test "stays when its connection ends", %{connection: connection, work_item: item} do
      assert {1, _} =
               Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
                 set: [
                   state: :ended,
                   ended_at: DateTime.utc_now(),
                   ended_reason: :adapter_reported
                 ]
               )

      assert %WorkItem{connection_id: id} = Repo.get!(WorkItem, item.id)
      assert id == connection.id

      # A connection is never deleted alone; while a work item names it, nothing may, its
      # tickets and collections gone or not.
      for table <- ~w(source_items source_collections) do
        Repo.query!("DELETE FROM #{table} WHERE organisation_id = $1", [
          Ecto.UUID.dump!(item.organisation_id)
        ])
      end

      refused("work_items_connection_id_fkey", fn ->
        Repo.query!("DELETE FROM adapter_connections WHERE id = $1", [
          Ecto.UUID.dump!(connection.id)
        ])
      end)
    end

    test "goes with its organisation, with its connection", ctx do
      %{scope: scope, connection: connection, work_item: item} = ctx

      # The key is NO ACTION ("a"), checked at the end of the statement, so the delete
      # does not depend on the order its cascades run in.
      assert %{rows: [["a"]]} =
               Repo.query!(
                 "SELECT confdeltype::text FROM pg_constraint " <>
                   "WHERE conname = 'work_items_connection_id_fkey'"
               )

      Repo.query!("DELETE FROM organisations WHERE id = $1", [
        Ecto.UUID.dump!(scope.organisation.id)
      ])

      assert Repo.get(WorkItem, item.id) == nil
      assert Repo.get(Connection, connection.id) == nil
    end
  end

  describe "work_item_events" do
    test "the kind is taken_in, declined, closed, undone, answered, confirmed or explore_again",
         %{work_item: item} do
      event = event_of(item)

      refused("work_item_events_kind_check", fn ->
        update!("work_item_events", event.id, "kind = 'shaped'")
      end)

      for kind <- ~w(declined closed undone answered confirmed explore_again) do
        assert %{num_rows: 1} = update!("work_item_events", event.id, "kind = $2", [kind])
      end
    end

    test "a person or an adapter is named by an id, and the instance by none", ctx do
      %{scope: scope, work_item: item} = ctx
      event = event_of(item)
      id = Ecto.UUID.dump!(scope.user.id)

      for {assignments, params} <- [
            {"actor_kind = 'robot'", []},
            {"actor_id = NULL", []},
            {"actor_kind = 'adapter', actor_id = NULL", []},
            {"actor_kind = 'instance'", []},
            {"actor_kind = 'instance', actor_id = $2", [id]}
          ] do
        refused("work_item_events_actor_check", fn ->
          update!("work_item_events", event.id, assignments, params)
        end)
      end

      assert %{num_rows: 1} =
               update!("work_item_events", event.id, "actor_kind = 'adapter', actor_id = $2", [
                 Ecto.UUID.dump!(Ecto.UUID.generate())
               ])

      assert %{num_rows: 1} =
               update!("work_item_events", event.id, "actor_kind = 'instance', actor_id = NULL")
    end

    test "the data is a JSON object of 16,384 bytes at most", %{work_item: item} do
      event = event_of(item)
      # `{"a": "…"}` is 9 bytes besides the string.
      fits = %{"a" => String.duplicate("x", 16_384 - 9)}
      over = %{"a" => String.duplicate("x", 16_384 - 8)}

      for data <- [[1, 2], "text", 1, over] do
        refused("work_item_events_data_check", fn ->
          update!("work_item_events", event.id, "data = $2::jsonb", [data])
        end)
      end

      assert %{num_rows: 1} =
               update!("work_item_events", event.id, "data = $2::jsonb", [fits])
    end

    test "an event is of its work item's workspace", %{scope: scope, work_item: item} do
      event = event_of(item)
      elsewhere = workspace_fixture(scope.organisation)

      refused("work_item_events_work_item_id_fkey", fn ->
        update!("work_item_events", event.id, "workspace_id = $2", [
          Ecto.UUID.dump!(elsewhere.id)
        ])
      end)
    end

    test "goes with its work item", %{work_item: item} do
      event = event_of(item)
      Repo.delete!(item)

      assert Repo.get(WorkItemEvent, event.id) == nil
    end
  end

  describe "work_item_counters" do
    test "the last number is 1 or more", %{scope: scope} do
      refused("work_item_counters_last_number_check", fn ->
        Repo.query!("UPDATE work_item_counters SET last_number = 0 WHERE workspace_id = $1", [
          Ecto.UUID.dump!(scope.workspace.id)
        ])
      end)
    end
  end

  describe "take_in_changeset/2" do
    test "asks for the snapshot and the owner, within their bounds" do
      changeset = WorkItem.take_in_changeset(%WorkItem{}, %{})
      refute changeset.valid?

      assert %{
               connection_id: [_],
               external_ref: [_],
               title: [_],
               collection_title: [_],
               owner_id: [_]
             } = errors_on(changeset)

      changeset =
        WorkItem.take_in_changeset(
          %WorkItem{},
          snapshot(%{
            external_ref: String.duplicate("r", 201),
            url: "https://forge.example.com/" <> String.duplicate("a", 2023),
            title: String.duplicate("t", 1025),
            collection_title: String.duplicate("c", 1025),
            target_system: "Forge.example.com",
            target_path: String.duplicate("p", 201),
            first_instruction: String.duplicate("é", 4001)
          })
        )

      assert errors_on(changeset) |> Map.keys() |> Enum.sort() ==
               [
                 :collection_title,
                 :external_ref,
                 :first_instruction,
                 :target_path,
                 :target_system,
                 :title,
                 :url
               ]

      for url <- [
            "http://forge.example.com/acme/shop/issues/12",
            "https://user@forge.example.com/acme/shop/issues/12",
            "https://forge.example.com/acme shop"
          ] do
        changeset = WorkItem.take_in_changeset(%WorkItem{}, snapshot(%{url: url}))
        assert %{url: [_]} = errors_on(changeset)
      end
    end

    test "gives a fresh public id, the first take in, and leaves no first instruction empty" do
      changeset = WorkItem.take_in_changeset(%WorkItem{}, snapshot(%{}))

      assert changeset.valid?
      assert Apiary.PublicId.valid?("wi", get_change(changeset, :public_id))
      assert get_change(changeset, :take_in) == 1
      assert get_field(changeset, :first_instruction) == ""
    end

    test "takes a target's system and path both or neither", ctx do
      assert %{target_path: ["can't be blank"]} =
               errors_on(WorkItem.take_in_changeset(%WorkItem{}, snapshot(%{target_path: nil})))

      assert %{target_system: ["can't be blank"]} =
               errors_on(WorkItem.take_in_changeset(%WorkItem{}, snapshot(%{target_system: nil})))

      assert {:ok, %WorkItem{target_system: nil, target_path: nil}} =
               new_work_item(ctx.scope)
               |> WorkItem.take_in_changeset(
                 fresh_snapshot(ctx, %{target_system: nil, target_path: nil})
               )
               |> Repo.insert()
    end

    test "counts code points, as the database does, not graphemes" do
      # One grapheme each: e and a combining acute accent, two code points; a woman, a
      # zero width joiner and a laptop, three.
      combining = "e\u0301"
      zwj = "\u{1F469}\u200D\u{1F4BB}"
      assert {String.length(combining), String.length(zwj)} == {1, 1}

      over = %{
        external_ref: String.duplicate(combining, 100) <> "r",
        title: String.duplicate(zwj, 342),
        collection_title: String.duplicate(combining, 513),
        first_instruction: String.duplicate(zwj, 1334)
      }

      changeset = WorkItem.take_in_changeset(%WorkItem{}, snapshot(over))

      assert errors_on(changeset) |> Map.keys() |> Enum.sort() ==
               [:collection_title, :external_ref, :first_instruction, :title]

      at_most = %{
        external_ref: String.duplicate(combining, 100),
        title: String.duplicate(zwj, 341) <> "t",
        collection_title: String.duplicate(combining, 512),
        first_instruction: String.duplicate(zwj, 1333) <> "f"
      }

      assert WorkItem.take_in_changeset(%WorkItem{}, snapshot(at_most)).valid?
    end

    test "a value the database refuses is an error on its field, not a raise", ctx do
      for {field, value} <- [
            external_ref: String.duplicate("r", 201),
            url: "https://user@forge.example.com/acme/shop/issues/12",
            title: String.duplicate("t", 1025),
            collection_title: String.duplicate("c", 1025),
            target_system: "Forge.example.com",
            first_instruction: String.duplicate("\u{1F469}\u200D\u{1F4BB}", 1334)
          ] do
        # Past the changeset's checks, as a value they count apart would be.
        assert {:error, changeset} =
                 new_work_item(ctx.scope)
                 |> WorkItem.take_in_changeset(fresh_snapshot(ctx))
                 |> put_change(field, value)
                 |> Repo.insert()

        assert Map.keys(errors_on(changeset)) == [field]
      end

      assert {:ok, %WorkItem{take_in: 1}} =
               new_work_item(ctx.scope)
               |> WorkItem.take_in_changeset(fresh_snapshot(ctx))
               |> Repo.insert()
    end

    test "a connection or a ticket that is not there is an error on it, not a raise", ctx do
      for field <- [:connection_id, :item_id] do
        assert {:error, changeset} =
                 new_work_item(ctx.scope)
                 |> WorkItem.take_in_changeset(
                   fresh_snapshot(ctx, %{field => Ecto.UUID.generate()})
                 )
                 |> Repo.insert()

        assert Map.keys(errors_on(changeset)) == [field]
      end
    end
  end

  describe "WorkItemEvent.changeset/2" do
    test "a person or an adapter needs an id, and the instance keeps none" do
      for actor_kind <- [:person, :adapter] do
        changeset =
          WorkItemEvent.changeset(%WorkItemEvent{}, %{
            kind: :closed,
            actor_kind: actor_kind,
            at: DateTime.utc_now()
          })

        assert %{actor_id: [_]} = errors_on(changeset)
      end

      changeset =
        WorkItemEvent.changeset(%WorkItemEvent{}, %{
          kind: :closed,
          actor_kind: :instance,
          actor_id: Ecto.UUID.generate(),
          at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert get_field(changeset, :actor_id) == nil
      assert get_field(changeset, :data) == %{}
    end

    test "data the database refuses is an error on data", %{work_item: item} do
      assert {:error, changeset} =
               %WorkItemEvent{
                 organisation_id: item.organisation_id,
                 workspace_id: item.workspace_id,
                 work_item_id: item.id
               }
               |> WorkItemEvent.changeset(%{
                 kind: :closed,
                 actor_kind: :instance,
                 at: DateTime.utc_now(),
                 data: %{"a" => String.duplicate("x", 16_384)}
               })
               |> Repo.insert()

      assert %{data: [_]} = errors_on(changeset)
    end
  end

  describe "the first instruction" do
    test "holds tab, line feed and carriage return, and none of the characters a run's input refuses" do
      assert WorkItem.take_in_changeset(
               %WorkItem{},
               snapshot(%{first_instruction: "One\tline\r\nand the next, ünïcödé."})
             ).valid?

      for {text, message} <- [
            {"a\u0000b", "must not contain control characters"},
            {"a\u001Bb", "must not contain control characters"},
            {"a\u007Fb", "must not contain control characters"},
            {"a\u0085b", "must not contain control characters"},
            {"a\u00ADb", "must not contain invisible characters"},
            {"a\u200Bb", "must not contain invisible characters"},
            {"a\u202Eb", "must not contain invisible characters"},
            {"a\u2066b", "must not contain invisible characters"},
            {"a\uFEFFb", "must not contain invisible characters"}
          ] do
        changeset = WorkItem.take_in_changeset(%WorkItem{}, snapshot(%{first_instruction: text}))
        assert %{first_instruction: [^message]} = errors_on(changeset), inspect(text)

        again =
          WorkItem.take_in_again_changeset(
            %WorkItem{take_in: 1},
            again(%{first_instruction: text})
          )

        assert %{first_instruction: [^message]} = errors_on(again), inspect(text)
      end
    end

    test "is refused, not raised on, when it is not UTF-8" do
      changeset =
        WorkItem.take_in_changeset(%WorkItem{}, snapshot(%{first_instruction: <<0xFF>>}))

      refute changeset.valid?
    end
  end

  describe "take_in_again_changeset/2" do
    test "counts the take in one more and keeps the adapter and the ref" do
      work_item = %WorkItem{
        take_in: 2,
        adapter_id: Ecto.UUID.generate(),
        external_ref: "acme/shop#13"
      }

      changeset =
        WorkItem.take_in_again_changeset(
          work_item,
          again(%{adapter_id: Ecto.UUID.generate(), external_ref: "acme/shop#99"})
        )

      assert changeset.valid?
      assert get_change(changeset, :take_in) == 3
      assert get_field(changeset, :adapter_id) == work_item.adapter_id
      assert get_field(changeset, :external_ref) == "acme/shop#13"
    end

    test "asks for the snapshot and the owner, within their bounds" do
      changeset = WorkItem.take_in_again_changeset(%WorkItem{take_in: 1}, %{})
      assert %{connection_id: [_], item_id: [_], title: [_], owner_id: [_]} = errors_on(changeset)

      changeset =
        WorkItem.take_in_again_changeset(
          %WorkItem{take_in: 1},
          again(%{title: String.duplicate("t", 1025), url: "http://forge.example.com/a"})
        )

      assert %{title: [_], url: [_]} = errors_on(changeset)
    end
  end

  # A take in again's snapshot within every bound, with `attrs` over it.
  defp again(attrs) do
    attrs
    |> snapshot()
    |> Map.drop([:adapter_id, :external_ref])
    |> Map.merge(Map.take(Map.new(attrs), [:adapter_id, :external_ref]))
  end
end
