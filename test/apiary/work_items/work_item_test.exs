defmodule Apiary.WorkItems.WorkItemTest do
  # The work items' tables as the migration made them, asked in raw SQL so that no
  # changeset stands between the write and the database, then the changesets.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

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
      ref: "acme/shop#12",
      title: "The checkout keeps the old price",
      collection_title: "acme/shop",
      owner_id: Ecto.UUID.generate()
    })
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
    %{scope: scope, work_item: work_item_fixture(scope)}
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

    test "the state is exploring, closed or undone; only a closed one has its closing", ctx do
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
            {"ref", "", "work_items_ref_check"},
            {"ref", String.duplicate("r", 256), "work_items_ref_check"},
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
            {"ref", String.duplicate("r", 255)},
            {"title", String.duplicate("t", 1024)},
            {"collection_title", String.duplicate("c", 1024)},
            {"first_instruction", String.duplicate("é", 4000)},
            {"first_instruction", ""}
          ] do
        assert %{num_rows: 1} = update!("work_items", item.id, "#{column} = $2", [value])
      end
    end

    test "an address is http or https, with no user or blank, 2,048 characters at most", ctx do
      %{work_item: item} = ctx

      for url <- [
            "ftp://forge.example.com/acme/shop/issues/12",
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

      for url <- [
            nil,
            "http://forge.example.com/acme/shop/issues/12",
            "https://forge.example.com:8443/acme/shop/-/issues/12?tab=notes#note_3",
            "https://forge.example.com/" <> String.duplicate("a", 2022)
          ] do
        assert %{num_rows: 1} = update!("work_items", item.id, "url = $2", [url])
      end
    end

    test "a work item's workspace is of its organisation", %{work_item: item} do
      %{organisation: other} = sign_up_fixture()

      refused("work_items_workspace_id_fkey", fn ->
        update!("work_items", item.id, "organisation_id = $2", [Ecto.UUID.dump!(other.id)])
      end)
    end
  end

  describe "work_item_events" do
    test "the kind is taken_in, closed or undone", %{work_item: item} do
      event = event_of(item)

      refused("work_item_events_kind_check", fn ->
        update!("work_item_events", event.id, "kind = 'answered'")
      end)

      for kind <- ~w(closed undone) do
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

      assert %{ref: [_], title: [_], collection_title: [_], owner_id: [_]} =
               errors_on(changeset)

      changeset =
        WorkItem.take_in_changeset(%WorkItem{}, %{
          ref: String.duplicate("r", 256),
          url: "https://forge.example.com/" <> String.duplicate("a", 2023),
          title: String.duplicate("t", 1025),
          collection_title: String.duplicate("c", 1025),
          owner_id: Ecto.UUID.generate(),
          first_instruction: String.duplicate("é", 4001)
        })

      assert errors_on(changeset) |> Map.keys() |> Enum.sort() ==
               [:collection_title, :first_instruction, :ref, :title, :url]
    end

    test "gives a fresh public id, and leaves no first instruction empty" do
      changeset =
        WorkItem.take_in_changeset(%WorkItem{}, %{
          ref: "acme/shop#12",
          title: "The checkout keeps the old price",
          collection_title: "acme/shop",
          owner_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert Apiary.PublicId.valid?("wi", get_change(changeset, :public_id))
      assert get_field(changeset, :first_instruction) == ""
    end

    test "counts code points, as the database does, not graphemes" do
      # One grapheme each: e and a combining acute accent, two code points; a woman, a
      # zero width joiner and a laptop, three.
      combining = "e\u0301"
      zwj = "\u{1F469}\u200D\u{1F4BB}"
      assert {String.length(combining), String.length(zwj)} == {1, 1}

      over = %{
        ref: String.duplicate(combining, 128),
        title: String.duplicate(zwj, 342),
        collection_title: String.duplicate(combining, 513),
        first_instruction: String.duplicate(zwj, 1334)
      }

      changeset = WorkItem.take_in_changeset(%WorkItem{}, snapshot(over))

      assert errors_on(changeset) |> Map.keys() |> Enum.sort() ==
               [:collection_title, :first_instruction, :ref, :title]

      at_most = %{
        ref: String.duplicate(combining, 127) <> "r",
        title: String.duplicate(zwj, 341) <> "t",
        collection_title: String.duplicate(combining, 512),
        first_instruction: String.duplicate(zwj, 1333) <> "f"
      }

      assert WorkItem.take_in_changeset(%WorkItem{}, snapshot(at_most)).valid?
    end

    test "a value the database refuses is an error on its field, not a raise", ctx do
      for {field, value} <- [
            ref: String.duplicate("r", 256),
            url: "https://user@forge.example.com/acme/shop/issues/12",
            title: String.duplicate("t", 1025),
            collection_title: String.duplicate("c", 1025),
            first_instruction: String.duplicate("\u{1F469}\u200D\u{1F4BB}", 1334)
          ] do
        # Past the changeset's own checks, as a value they count apart would be.
        assert {:error, changeset} =
                 new_work_item(ctx.scope)
                 |> WorkItem.take_in_changeset(snapshot(%{owner_id: ctx.scope.user.id}))
                 |> put_change(field, value)
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
end
