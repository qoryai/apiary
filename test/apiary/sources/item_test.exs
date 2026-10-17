defmodule Apiary.Sources.ItemTest do
  # The tickets' tables as the migration made them (`source_items`, `source_item_comments`,
  # `source_item_listings`), asked in raw SQL so that no changeset stands between the
  # write and the database, each bound at its edge and one past it, then the changesets.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Sources.{Comment, Item, Listing}

  @format ~r/\Atk_[0-9a-hjkmnp-tv-z]{16}\z/

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  # Sets `assignments` on the row `id` of `table`, with `params` after the id: $2 onwards.
  defp update!(table, id, assignments, params \\ []) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  defp set!(table, id, column, value),
    do: assert(%{num_rows: 1} = update!(table, id, "#{column} = $2", [value]))

  defp refused!(table, id, column, value, constraint),
    do: refused(constraint, fn -> update!(table, id, "#{column} = $2", [value]) end)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp comment!(%Item{} = item, attrs \\ %{}) do
    %Comment{organisation_id: item.organisation_id, item_id: item.id}
    |> Comment.changeset(
      Enum.into(attrs, %{
        external_ref: "c-#{System.unique_integer([:positive])}",
        url: "https://forge.example.com/acme/shop/issues/12#comment-1",
        author_name: "Avery Example",
        author_kind: :person,
        body: "It does it on the second page too.",
        body_format: "markdown",
        source_created_at: now(),
        source_updated_at: now()
      })
    )
    |> Repo.insert!()
  end

  defp listing!(%Item{} = item, attrs \\ []) do
    fields =
      Enum.into(attrs, %{
        id: Ecto.UUID.generate(),
        organisation_id: item.organisation_id,
        collection_id: item.collection_id,
        external_id: "listing-#{System.unique_integer([:positive])}",
        started_at: now(),
        parts: [1],
        inserted_at: DateTime.utc_now()
      })

    Repo.insert!(struct!(Listing, fields))
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    item = source_item_fixture(scope)
    %{scope: scope, item: item}
  end

  describe "source_items" do
    test "a public id is tk_ and sixteen Crockford base32 characters, made by the column's default",
         %{scope: scope, item: item} do
      other = source_item_fixture(scope)

      for public_id <- [item.public_id, other.public_id] do
        assert public_id =~ @format
        assert Item.public_id?(public_id)
      end

      assert item.public_id != other.public_id
      assert Repo.get!(Item, item.id).public_id == item.public_id

      for public_id <- [
            "wi_0123456789abcdef",
            "tk_0123456789ABCDEF",
            "tk_0123456789abcdeu",
            "tk_0123456789abcde",
            "tk0123456789abcdef"
          ] do
        refused!("source_items", item.id, "public_id", public_id, "source_items_public_id_check")
      end

      refused!(
        "source_items",
        other.id,
        "public_id",
        item.public_id,
        "source_items_public_id_index"
      )

      set!("source_items", item.id, "public_id", Item.new_public_id())
    end

    test "the id function is pinned to pg_catalog" do
      assert %{rows: [[config]]} =
               Repo.query!(
                 "SELECT proconfig FROM pg_proc WHERE proname = 'source_item_public_id'"
               )

      assert config == ["search_path=pg_catalog"]

      assert %{rows: [[config]]} =
               Repo.query!("SELECT proconfig FROM pg_proc WHERE proname = 'source_texts_valid'")

      assert config == ["search_path=pg_catalog"]
    end

    test "each text keeps to its bounds, in code points", %{item: item} do
      for {column, over, at_most, constraint} <- [
            {"external_ref", String.duplicate("é", 201), String.duplicate("é", 200),
             "source_items_external_ref_check"},
            {"external_ref", "", "r", "source_items_external_ref_check"},
            {"key", String.duplicate("é", 65), String.duplicate("é", 64),
             "source_items_key_check"},
            {"key", "", "#", "source_items_key_check"},
            {"title", String.duplicate("é", 1025), String.duplicate("é", 1024),
             "source_items_title_check"},
            {"title", "", "t", "source_items_title_check"},
            {"body", String.duplicate("é", 65_537), String.duplicate("é", 65_536),
             "source_items_body_check"},
            {"filed_by_name", String.duplicate("é", 101), String.duplicate("é", 100),
             "source_items_filed_by_check"},
            {"filed_by_name", "", "A", "source_items_filed_by_check"},
            {"state_reason", String.duplicate("é", 65), String.duplicate("é", 64),
             "source_items_state_reason_check"}
          ] do
        refused!("source_items", item.id, column, over, constraint)
        set!("source_items", item.id, column, at_most)
      end

      for {column, value} <- [
            {"key", nil},
            {"body", ""},
            {"state_reason", nil},
            {"state_reason", ""}
          ],
          do: set!("source_items", item.id, column, value)

      for column <- ~w(external_ref url title body body_format filed_by_name filed_by_kind state) do
        refused(column, fn -> update!("source_items", item.id, "#{column} = NULL") end)
      end
    end

    test "an address is https alone, with no user or blank, 2,048 characters at most",
         %{item: item} do
      for url <- [
            "http://forge.example.com/acme/shop/issues/12",
            "ftp://forge.example.com/acme/shop/issues/12",
            "https://",
            "https://user@forge.example.com/acme/shop/issues/12",
            "https://forge.example.com/acme shop",
            "https://forge.example.com/" <> String.duplicate("a", 2023)
          ] do
        refused!("source_items", item.id, "url", url, "source_items_url_check")
      end

      for url <- [
            "https://forge.example.com:8443/acme/shop/-/issues/12?tab=notes#note_3",
            "https://forge.example.com?issue=12",
            "https://forge.example.com/" <> String.duplicate("a", 2022)
          ] do
        set!("source_items", item.id, "url", url)
      end
    end

    test "a body format, a type and a filer's kind keep to the contract", %{item: item} do
      for value <- ["Markdown", "1md", "", String.duplicate("a", 41)],
          do:
            refused!(
              "source_items",
              item.id,
              "body_format",
              value,
              "source_items_body_format_check"
            )

      for value <- ["text", "a", "gfm_2-x", String.duplicate("a", 40)],
          do: set!("source_items", item.id, "body_format", value)

      for value <- ["Bug", "bug2", "", " bug", String.duplicate("a", 41)],
          do: refused!("source_items", item.id, "type", value, "source_items_type_check")

      for value <- [nil, "bug", "feature request", String.duplicate("a", 40)],
          do: set!("source_items", item.id, "type", value)

      refused!("source_items", item.id, "filed_by_kind", "bot", "source_items_filed_by_check")
      set!("source_items", item.id, "filed_by_kind", "automation")
    end

    test "labels are at most 100, each 1 to 100 characters, each once", %{item: item} do
      hundred = for n <- 1..100, do: "label #{n}"

      for labels <- [
            hundred ++ ["label 101"],
            ["bug", ""],
            ["bug", String.duplicate("é", 101)],
            ["bug", "bug"],
            ["bug", nil]
          ] do
        refused!("source_items", item.id, "labels", labels, "source_items_labels_check")
      end

      refused("source_items_labels_check", fn ->
        update!("source_items", item.id, "labels = '{{a,b},{c,d}}'::text[]")
      end)

      refused("labels", fn -> update!("source_items", item.id, "labels = NULL") end)

      for labels <- [[], hundred, [String.duplicate("é", 100), "a"]],
          do: set!("source_items", item.id, "labels", labels)
    end

    test "the state is open or closed, and only a closed one was closed by a listing",
         %{item: item} do
      refused!("source_items", item.id, "state", "merged", "source_items_state_check")

      refused("source_items_closed_by_listing_check", fn ->
        update!("source_items", item.id, "closed_by_listing_at = now()")
      end)

      assert %{num_rows: 1} =
               update!("source_items", item.id, "state = 'closed', closed_by_listing_at = now()")

      refused("source_items_closed_by_listing_check", fn ->
        update!("source_items", item.id, "state = 'open'")
      end)

      assert %{num_rows: 1} =
               update!("source_items", item.id, "state = 'open', closed_by_listing_at = NULL")

      set!("source_items", item.id, "disconnected_at", DateTime.utc_now())
    end

    test "a target is both or neither, a host name and a path of 1 to 200", %{item: item} do
      for {system, path} <- [
            {"forge.example.com", nil},
            {nil, "acme/shop"},
            {"Forge.example.com", "acme/shop"},
            {String.duplicate("a", 254), "acme/shop"},
            {"forge.example.com", ""},
            {"forge.example.com", String.duplicate("é", 201)}
          ] do
        refused("source_items_target_check", fn ->
          update!("source_items", item.id, "target_system = $2, target_path = $3", [
            system,
            path
          ])
        end)
      end

      for {system, path} <- [
            {nil, nil},
            {"forge.example.com", "p"},
            {String.duplicate("a", 253), String.duplicate("é", 200)}
          ] do
        assert %{num_rows: 1} =
                 update!("source_items", item.id, "target_system = $2, target_path = $3", [
                   system,
                   path
                 ])
      end
    end

    test "truncated names the fields the adapter may cut, each once", %{item: item} do
      for value <- [["title", "title"], ["subject"], ["filed_by"], [nil]],
          do:
            refused!("source_items", item.id, "truncated", value, "source_items_truncated_check")

      for value <- [[], ["title", "body", "filed_by.name", "labels"], ["labels"]],
          do: set!("source_items", item.id, "truncated", value)
    end

    test "the comment count is 0 or more", %{item: item} do
      refused!("source_items", item.id, "comment_count", -1, "source_items_comment_count_check")
      set!("source_items", item.id, "comment_count", 0)
      set!("source_items", item.id, "comment_count", 3_000_000_000)
    end

    test "a ref is once in its collection, and may be in another collection too",
         %{scope: scope, item: item} do
      assert_raise Ecto.InvalidChangesetError, ~r/external_ref: \{"has already been taken"/, fn ->
        source_item_fixture(scope, collection: collection_of(item))
      end

      refused("source_items_collection_id_external_ref_index", fn ->
        update!(
          "source_items",
          source_item_fixture(scope,
            collection: collection_of(item),
            external_ref: "acme/shop#13"
          ).id,
          "external_ref = $2",
          [item.external_ref]
        )
      end)

      # Another live collection of the same adapter: nothing is unique across them.
      connection = Repo.get!(Apiary.Adapters.Connection, collection_of(item).connection_id)
      other = source_item_fixture(scope, connection: connection)
      assert other.external_ref == item.external_ref
      assert other.adapter_id == item.adapter_id
      assert other.collection_id != item.collection_id
    end

    test "an item is of its collection's organisation and adapter", %{scope: scope, item: item} do
      %{scope: other} = sign_up_fixture()
      theirs = source_item_fixture(other, external_ref: "theirs")
      another_adapter = source_item_fixture(scope, external_ref: "another")

      for {column, value} <- [
            {"organisation_id", other.organisation.id},
            {"adapter_id", another_adapter.adapter_id},
            {"collection_id", theirs.collection_id},
            {"collection_id", another_adapter.collection_id}
          ] do
        refused("source_items_collection_id_fkey", fn ->
          update!("source_items", item.id, "#{column} = $2", [Ecto.UUID.dump!(value)])
        end)
      end
    end

    test "a collection with items is not deleted alone, and goes with its organisation",
         %{scope: scope, item: item} do
      refused("source_items_collection_id_fkey", fn ->
        Repo.query!("DELETE FROM source_collections WHERE id = $1", [
          Ecto.UUID.dump!(item.collection_id)
        ])
      end)

      comment = comment!(item)
      listing = listing!(item)

      Repo.query!("DELETE FROM organisations WHERE id = $1", [
        Ecto.UUID.dump!(scope.organisation.id)
      ])

      assert Repo.get(Item, item.id) == nil
      assert Repo.get(Comment, comment.id) == nil
      assert Repo.get(Listing, listing.id) == nil
    end

    test "the indexes a list of tickets reads are there" do
      definitions =
        Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = 'source_items'").rows
        |> List.flatten()

      for columns <- [
            "(collection_id, state, source_updated_at DESC)",
            "(organisation_id, filed_by_name)",
            "(collection_id, external_ref)",
            "(id, organisation_id, adapter_id)"
          ] do
        assert Enum.any?(definitions, &String.contains?(&1, columns)), columns
      end

      refute Enum.any?(definitions, &String.contains?(&1, "(adapter_id, external_ref)"))
    end
  end

  describe "source_item_comments" do
    test "each field keeps to its bounds", %{item: item} do
      comment = comment!(item)

      for {column, over, at_most, constraint} <- [
            {"external_ref", String.duplicate("é", 201), String.duplicate("é", 200),
             "source_item_comments_external_ref_check"},
            {"external_ref", "", "r", "source_item_comments_external_ref_check"},
            {"author_name", String.duplicate("é", 101), String.duplicate("é", 100),
             "source_item_comments_author_check"},
            {"author_name", "", "A", "source_item_comments_author_check"},
            {"author_kind", "bot", "automation", "source_item_comments_author_check"},
            {"body", String.duplicate("é", 65_537), String.duplicate("é", 65_536),
             "source_item_comments_body_check"},
            {"body_format", "Markdown", "text", "source_item_comments_body_format_check"},
            {"url", "http://forge.example.com/c/1", "https://forge.example.com/c/1",
             "source_item_comments_url_check"},
            {"url", "https://forge.example.com/" <> String.duplicate("a", 2023),
             "https://forge.example.com/" <> String.duplicate("a", 2022),
             "source_item_comments_url_check"},
            {"truncated", ["body", "body"], ["body", "author.name"],
             "source_item_comments_truncated_check"},
            {"truncated", ["title"], [], "source_item_comments_truncated_check"}
          ] do
        refused!("source_item_comments", comment.id, column, over, constraint)
        set!("source_item_comments", comment.id, column, at_most)
      end

      set!("source_item_comments", comment.id, "body", "")
      set!("source_item_comments", comment.id, "deleted_at", DateTime.utc_now())
    end

    test "a ref is once on its item, and a comment is of its item's organisation",
         %{scope: scope, item: item} do
      comment = comment!(item)
      other_item = source_item_fixture(scope)

      assert_raise Ecto.InvalidChangesetError, ~r/external_ref/, fn ->
        comment!(item, external_ref: comment.external_ref)
      end

      assert %Comment{} = comment!(other_item, external_ref: comment.external_ref)

      %{organisation: other} = sign_up_fixture()

      refused("source_item_comments_item_id_fkey", fn ->
        update!("source_item_comments", comment.id, "organisation_id = $2", [
          Ecto.UUID.dump!(other.id)
        ])
      end)
    end

    test "goes with its item", %{item: item} do
      comment = comment!(item)
      Repo.delete!(item)
      assert Repo.get(Comment, comment.id) == nil
    end
  end

  describe "source_item_listings" do
    test "a listing's id is 1 to 200 characters, once in its collection", %{item: item} do
      listing = listing!(item)

      refused!(
        "source_item_listings",
        listing.id,
        "external_id",
        String.duplicate("é", 201),
        "source_item_listings_external_id_check"
      )

      refused!(
        "source_item_listings",
        listing.id,
        "external_id",
        "",
        "source_item_listings_external_id_check"
      )

      set!("source_item_listings", listing.id, "external_id", String.duplicate("é", 200))

      assert_raise Ecto.ConstraintError,
                   ~r/source_item_listings_collection_id_external_id_index/,
                   fn ->
                     listing!(item, external_id: String.duplicate("é", 200))
                   end
    end

    test "the parts are from 1, at most 10,000, the last at least every one", %{item: item} do
      listing = listing!(item)

      for {assignments, params} <- [
            {"parts = $2", [[]]},
            {"parts = $2", [[0]]},
            {"parts = $2", [Enum.to_list(1..10_001)]},
            {"last_part = 10001", []},
            {"parts = $2, last_part = 2", [[1, 3]]}
          ] do
        refused("source_item_listings_parts_check", fn ->
          update!("source_item_listings", listing.id, assignments, params)
        end)
      end

      refused("source_item_listings_completed_check", fn ->
        update!("source_item_listings", listing.id, "completed_at = now()")
      end)

      assert %{num_rows: 1} =
               update!(
                 "source_item_listings",
                 listing.id,
                 "parts = $2, last_part = 10000, completed_at = now()",
                 [Enum.to_list(1..10_000)]
               )
    end

    test "a listing is of its collection's organisation", %{item: item} do
      listing = listing!(item)
      %{organisation: other} = sign_up_fixture()

      refused("source_item_listings_collection_id_fkey", fn ->
        update!("source_item_listings", listing.id, "organisation_id = $2", [
          Ecto.UUID.dump!(other.id)
        ])
      end)
    end
  end

  describe "Item.changeset/2" do
    defp item_attrs(attrs) do
      Enum.into(attrs, %{
        external_ref: "acme/shop#40",
        url: "https://forge.example.com/acme/shop/issues/40",
        title: "Search finds nothing with an accent",
        body: "",
        body_format: "markdown",
        filed_by_name: " ",
        filed_by_kind: :automation,
        labels: [],
        state: :closed,
        state_reason: "",
        comment_count: 0,
        source_created_at: now(),
        source_updated_at: now()
      })
    end

    test "takes an item within the contract's bounds, a blank name and an empty body among it" do
      assert Item.changeset(%Item{}, item_attrs(%{})).valid?
    end

    test "asks for what the contract asks for" do
      changeset = Item.changeset(%Item{}, %{})

      assert errors_on(changeset) |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 :external_ref,
                 :url,
                 :title,
                 :body_format,
                 :filed_by_name,
                 :filed_by_kind,
                 :state,
                 :source_created_at,
                 :source_updated_at
               ])
    end

    test "holds every bound the database holds, in code points" do
      combining = "é"

      for {field, value} <- [
            external_ref: String.duplicate(combining, 100) <> "r",
            key: "",
            key: String.duplicate("é", 65),
            url: "http://forge.example.com/acme/shop/issues/40",
            url: "https://forge.example.com/" <> String.duplicate("a", 2023),
            title: String.duplicate("é", 1025),
            body: String.duplicate("é", 65_537),
            body_format: "Markdown",
            filed_by_name: String.duplicate("é", 101),
            filed_by_kind: :bot,
            labels: for(n <- 1..101, do: "l#{n}"),
            labels: ["bug", "bug"],
            labels: [String.duplicate("é", 101)],
            labels: [""],
            state: :merged,
            state_reason: String.duplicate("é", 65),
            type: "Bug",
            target_system: "forge.example.com",
            target_path: "acme/shop",
            truncated: ["subject"],
            truncated: ["title", "title"],
            comment_count: -1
          ] do
        changeset = Item.changeset(%Item{}, item_attrs(%{field => value}))
        refute changeset.valid?, inspect({field, value})

        expected =
          case field do
            :target_system -> :target_path
            :target_path -> :target_system
            other -> other
          end

        assert Map.has_key?(errors_on(changeset), expected), inspect({field, value})
      end

      for {field, value} <- [
            external_ref: String.duplicate(combining, 100),
            key: String.duplicate("é", 64),
            labels: [String.duplicate("é", 100) | for(n <- 1..99, do: "l#{n}")],
            state_reason: String.duplicate("é", 64),
            type: "feature request",
            truncated: ["title", "body", "filed_by.name", "labels"]
          ] do
        assert Item.changeset(%Item{}, item_attrs(%{field => value})).valid?,
               inspect({field, value})
      end

      assert Item.changeset(
               %Item{},
               item_attrs(%{target_system: "forge.example.com", target_path: "p"})
             ).valid?
    end

    test "a value the database refuses is an error on its field, not a raise", %{item: item} do
      ticket = Repo.get!(Item, item.id)

      for {field, value} <- [
            labels: ["bug", "bug"],
            url: "https://forge.example.com/acme shop",
            title: String.duplicate("\u{1F469}‍\u{1F4BB}", 342)
          ] do
        assert {:error, changeset} =
                 ticket
                 |> Item.changeset(%{})
                 |> Ecto.Changeset.force_change(field, value)
                 |> Repo.update()

        assert Map.keys(errors_on(changeset)) == [field]
      end
    end
  end

  describe "Comment.changeset/2" do
    test "holds the bounds the database holds", %{item: item} do
      for {field, value} <- [
            external_ref: String.duplicate("é", 201),
            url: "http://forge.example.com/c/1",
            author_name: String.duplicate("é", 101),
            author_kind: :bot,
            body: String.duplicate("é", 65_537),
            body_format: "Markdown",
            truncated: ["title"],
            truncated: ["body", "body"]
          ] do
        changeset =
          Comment.changeset(
            %Comment{},
            %{
              external_ref: "c1",
              url: "https://forge.example.com/c/1",
              author_name: "Avery Example",
              author_kind: :person,
              body: "",
              body_format: "text",
              source_created_at: now(),
              source_updated_at: now()
            }
            |> Map.put(field, value)
          )

        assert Map.keys(errors_on(changeset)) == [field], inspect({field, value})
      end

      assert %Comment{body: "", truncated: ["body", "author.name"]} =
               comment!(item, body: "", truncated: ["body", "author.name"])
    end
  end

  # The collection of an item.
  defp collection_of(%Item{collection_id: id}), do: Repo.get!(Apiary.Adapters.Collection, id)
end
