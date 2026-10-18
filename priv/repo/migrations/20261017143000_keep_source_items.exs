defmodule Apiary.Repo.Migrations.KeepSourceItems do
  use Ecto.Migration

  # The items an adapter sends of a collection, their comments, and the bookkeeping of an
  # items listing, as the integration contract has them (`source-items.schema.json`,
  # `source-item-comments.schema.json`, `definitions.schema.json`). The contract calls
  # them items; the pages call them tickets.
  #
  # - `source_items` (`Apiary.Sources.Item`): one row per item of a collection
  #   (`source_collections`), its organisation and its adapter held to the collection's
  #   by the composite key. `public_id` is `tk_` and sixteen lowercase Crockford base32
  #   characters, made by `source_item_public_id()`. `external_ref` is the adapter's ref
  #   for it, 1 to 200 characters, unique in its collection, which the core compares and
  #   stores and never reads meaning into; nothing is unique on the ref across
  #   collections. `key` is the item's name at its source, 1 to 64 characters or none,
  #   shown as text and never parsed. `url` is `https://`, 2,048 characters at most;
  #   `title` 1 to 1,024 characters; `body` at most 65,536 characters, written in
  #   `body_format`; `filed_by_name`, 1 to 100 characters, and `filed_by_kind`, `person`
  #   or `automation`, as sent; `labels`, at most 100, each 1 to 100 characters, each
  #   once; `state`, `open` or `closed`, with `state_reason`, at most 64 characters, or
  #   none; `type`, the contract's pattern, or none; the target (`target_system`,
  #   `target_path`, both or neither) to the contract's `$defs/target`; `truncated`, the
  #   fields the adapter cut, each once; `comment_count`, 0 or more;
  #   `source_created_at` and `source_updated_at`, the item's times at its source, which
  #   tell an earlier write of it from a later one. `closed_by_listing_at` is for an item a
  #   complete listing left out and closed, and only a closed item has it;
  #   `disconnected_at` is for an item that left every Backlog where it is, as an item of
  #   another live collection of the adapter holds its ref (`Apiary.Sources`): one whose
  #   ref such an item took, or one written already ended, as a write that does not take
  #   the ref is. The column marks it, so that its row can stay. An item stays with its
  #   collection when the collection ends; the Backlog leaves out the tickets of an ended
  #   collection by the collection's `ended_at`.
  # - `source_item_comments` (`Apiary.Sources.Comment`): one row per comment of an item,
  #   by the comment's ref, unique on its item, with the same bounds: `url`, `author_name`
  #   and `author_kind`, `body` and `body_format`, `truncated`, its times at its source,
  #   and `deleted_at`, which marks a comment deleted at its source, so that its row can
  #   stay. A comment goes with its item.
  # - `source_item_listings` (`Apiary.Sources.Listing`): one row per items listing of a
  #   collection, by the listing's id, `external_id`: its `started_at`, the part numbers
  #   that arrived (`parts`, each once, from 1 to 10,000, at most 10,000 of them), the
  #   number of the part that said `complete` (`last_part`), when every part from 1 to
  #   that one had arrived (`completed_at`), and when the row was made (`inserted_at`).
  #
  # Every character count is in code points, as `char_length` counts. A list of texts is
  # held by `source_texts_valid(texts, shortest, longest, most)`: one dimension, at most
  # `most` texts, none NULL, each `shortest` to `longest` characters, and none twice. A
  # listing's parts are held by `source_parts_valid(parts)`: one dimension, 1 to 10,000
  # numbers, none NULL, each 1 to 10,000, and none twice. Both, and
  # `source_item_public_id()`, have the `search_path` `pg_catalog`, where every function
  # they call is (20261011120000), whatever the `search_path` of the session that calls
  # them.
  #
  # The rows of the three tables are an organisation's, and go only with it: a collection
  # and a connection end by their state and are never deleted alone. The keys to a
  # collection are NO ACTION, as a collection's key to its connection is.
  @public_id "^tk_[0-9a-hjkmnp-tv-z]{16}$"
  # definitions.schema.json: $defs.target's system, $defs.body_format and $defs.type.
  @system "^[a-z0-9.-]{1,253}$"
  @body_format "^[a-z][a-z0-9_-]{0,39}$"
  @type_pattern "^[a-z][a-z ]{0,39}$"
  # $defs.url: `https://`, then an authority with no user information, then nothing, or a
  # path, a query or a fragment, with no white space, as `Apiary.Adapters.Wire.url?/1`
  # takes one.
  @url "^https://[^/?#@[:space:]]+([/?#][^[:space:]]*)?$"

  def up do
    execute("""
    CREATE FUNCTION source_item_public_id() RETURNS text LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := 'tk_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """)

    execute("""
    CREATE FUNCTION source_texts_valid(texts text[], shortest integer, longest integer,
                                       most integer)
    RETURNS boolean LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog AS $$
      SELECT texts IS NOT NULL
        AND (cardinality(texts) = 0 OR array_ndims(texts) = 1)
        AND cardinality(texts) <= most
        AND NOT EXISTS (
          SELECT 1 FROM unnest(texts) AS t(text)
          WHERE t.text IS NULL OR char_length(t.text) NOT BETWEEN shortest AND longest
        )
        AND (SELECT count(DISTINCT t.text) FROM unnest(texts) AS t(text)) = cardinality(texts)
    $$
    """)

    execute("""
    CREATE FUNCTION source_parts_valid(parts integer[])
    RETURNS boolean LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog AS $$
      SELECT parts IS NOT NULL
        AND array_ndims(parts) = 1
        AND cardinality(parts) BETWEEN 1 AND 10000
        AND array_position(parts, NULL) IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM unnest(parts) AS p(part) WHERE p.part NOT BETWEEN 1 AND 10000
        )
        AND (SELECT count(DISTINCT p.part) FROM unnest(parts) AS p(part)) = cardinality(parts)
    $$
    """)

    # The key an item names its collection by: the collection, its organisation and its
    # adapter at once.
    create unique_index(:source_collections, [:id, :organisation_id, :adapter_id])

    create table(:source_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false, default: fragment("source_item_public_id()")

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :adapter_id, :binary_id, null: false

      add :collection_id,
          references(:source_collections,
            type: :binary_id,
            with: [organisation_id: :organisation_id, adapter_id: :adapter_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :external_ref, :text, null: false
      add :key, :text
      add :url, :text, null: false
      add :title, :text, null: false
      add :body, :text, null: false
      add :body_format, :text, null: false
      add :filed_by_name, :text, null: false
      add :filed_by_kind, :text, null: false
      add :labels, {:array, :text}, null: false, default: fragment("'{}'::text[]")
      add :state, :text, null: false
      add :state_reason, :text
      add :type, :text
      add :target_system, :text
      add :target_path, :text
      add :truncated, {:array, :text}, null: false, default: fragment("'{}'::text[]")
      add :comment_count, :bigint, null: false, default: 0
      add :source_created_at, :utc_datetime, null: false
      add :source_updated_at, :utc_datetime, null: false
      add :closed_by_listing_at, :utc_datetime_usec
      add :disconnected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_items, [:public_id])
    create unique_index(:source_items, [:id, :organisation_id])
    create unique_index(:source_items, [:id, :organisation_id, :adapter_id])
    create unique_index(:source_items, [:collection_id, :external_ref])

    execute(
      "CREATE INDEX source_items_collection_id_state_source_updated_at_index " <>
        "ON source_items (collection_id, state, source_updated_at DESC)"
    )

    create index(:source_items, [:organisation_id, :filed_by_name])

    create constraint(:source_items, :source_items_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    create constraint(:source_items, :source_items_external_ref_check,
             check: "char_length(external_ref) BETWEEN 1 AND 200"
           )

    create constraint(:source_items, :source_items_key_check,
             check: "key IS NULL OR char_length(key) BETWEEN 1 AND 64"
           )

    create constraint(:source_items, :source_items_url_check,
             check: "char_length(url) <= 2048 AND url ~ '#{@url}'"
           )

    create constraint(:source_items, :source_items_title_check,
             check: "char_length(title) BETWEEN 1 AND 1024"
           )

    create constraint(:source_items, :source_items_body_check,
             check: "char_length(body) <= 65536"
           )

    create constraint(:source_items, :source_items_body_format_check,
             check: "body_format ~ '#{@body_format}'"
           )

    create constraint(:source_items, :source_items_filed_by_check,
             check:
               "char_length(filed_by_name) BETWEEN 1 AND 100 AND " <>
                 "filed_by_kind IN ('person', 'automation')"
           )

    create constraint(:source_items, :source_items_labels_check,
             check: "source_texts_valid(labels, 1, 100, 100)"
           )

    create constraint(:source_items, :source_items_state_check,
             check: "state IN ('open', 'closed')"
           )

    create constraint(:source_items, :source_items_state_reason_check,
             check: "state_reason IS NULL OR char_length(state_reason) <= 64"
           )

    create constraint(:source_items, :source_items_type_check,
             check: "type IS NULL OR type ~ '#{@type_pattern}'"
           )

    create constraint(:source_items, :source_items_target_check,
             check:
               "(target_system IS NULL AND target_path IS NULL) OR " <>
                 "(target_system IS NOT NULL AND target_path IS NOT NULL AND " <>
                 "target_system ~ '#{@system}' AND char_length(target_path) BETWEEN 1 AND 200)"
           )

    create constraint(:source_items, :source_items_truncated_check,
             check:
               "truncated <@ ARRAY['title', 'body', 'filed_by.name', 'labels']::text[] AND " <>
                 "source_texts_valid(truncated, 1, 13, 4)"
           )

    create constraint(:source_items, :source_items_comment_count_check,
             check: "comment_count >= 0"
           )

    create constraint(:source_items, :source_items_closed_by_listing_check,
             check: "closed_by_listing_at IS NULL OR state = 'closed'"
           )

    create table(:source_item_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_id,
          references(:source_items,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :external_ref, :text, null: false
      add :url, :text, null: false
      add :author_name, :text, null: false
      add :author_kind, :text, null: false
      add :body, :text, null: false
      add :body_format, :text, null: false
      add :truncated, {:array, :text}, null: false, default: fragment("'{}'::text[]")
      add :source_created_at, :utc_datetime, null: false
      add :source_updated_at, :utc_datetime, null: false
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_item_comments, [:item_id, :external_ref])
    create index(:source_item_comments, [:organisation_id])

    create constraint(:source_item_comments, :source_item_comments_external_ref_check,
             check: "char_length(external_ref) BETWEEN 1 AND 200"
           )

    create constraint(:source_item_comments, :source_item_comments_url_check,
             check: "char_length(url) <= 2048 AND url ~ '#{@url}'"
           )

    create constraint(:source_item_comments, :source_item_comments_author_check,
             check:
               "char_length(author_name) BETWEEN 1 AND 100 AND " <>
                 "author_kind IN ('person', 'automation')"
           )

    create constraint(:source_item_comments, :source_item_comments_body_check,
             check: "char_length(body) <= 65536"
           )

    create constraint(:source_item_comments, :source_item_comments_body_format_check,
             check: "body_format ~ '#{@body_format}'"
           )

    create constraint(:source_item_comments, :source_item_comments_truncated_check,
             check:
               "truncated <@ ARRAY['body', 'author.name']::text[] AND " <>
                 "source_texts_valid(truncated, 1, 11, 2)"
           )

    create table(:source_item_listings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :collection_id,
          references(:source_collections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :external_id, :text, null: false
      add :started_at, :utc_datetime, null: false
      add :parts, {:array, :integer}, null: false
      add :last_part, :integer
      add :completed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:source_item_listings, [:collection_id, :external_id])
    create index(:source_item_listings, [:organisation_id])
    create index(:source_item_listings, [:inserted_at])

    create constraint(:source_item_listings, :source_item_listings_external_id_check,
             check: "char_length(external_id) BETWEEN 1 AND 200"
           )

    create constraint(:source_item_listings, :source_item_listings_parts_check,
             check:
               "source_parts_valid(parts) AND " <>
                 "(last_part IS NULL OR (last_part BETWEEN 1 AND 10000 AND last_part >= ALL(parts)))"
           )

    create constraint(:source_item_listings, :source_item_listings_completed_check,
             check: "completed_at IS NULL OR last_part IS NOT NULL"
           )
  end

  # Rolled back, the items, their comments and their listings go, and the three functions.
  def down do
    drop table(:source_item_listings)
    drop table(:source_item_comments)
    drop table(:source_items)
    drop index(:source_collections, [:id, :organisation_id, :adapter_id])

    execute("DROP FUNCTION source_parts_valid(integer[])")
    execute("DROP FUNCTION source_texts_valid(text[], integer, integer, integer)")
    execute("DROP FUNCTION source_item_public_id()")
  end
end
