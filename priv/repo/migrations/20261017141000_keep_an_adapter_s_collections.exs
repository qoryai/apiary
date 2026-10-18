defmodule Apiary.Repo.Migrations.KeepAnAdapterSCollections do
  use Ecto.Migration

  # The collections an adapter's listing names through a connection, and the parts of
  # those listings, as the integration contract has them (`source-collections.schema.json`,
  # `sources-disconnect.schema.json`):
  #
  # - `source_collections` (`Apiary.Adapters.Collection`): one row per collection, of the
  #   connection whose listing named it, its organisation and its adapter held to that
  #   connection's by the composite key. `public_id` is `sc_` and sixteen lowercase
  #   Crockford base32 characters. `external_ref` is the adapter's ref for it, 1 to 200
  #   characters, which the core compares and stores and never reads meaning into; `url`,
  #   `title` and the optional target (`target_system`, `target_path`, both or neither)
  #   are as the listing last gave them. `last_listed_at` is the `started_at` of the
  #   newest listing that named it. A collection is live until `ended_at`, for
  #   `ended_reason`: `disconnected` by `POST /v1/sources/disconnect`, `not_listed` when a
  #   complete listing left it out, `connection_ended` when its connection ended. Final:
  #   a ref named again makes a new row. One live collection per adapter and ref (the
  #   unique partial index). `workspace_id` is the one workspace it is linked to, or none.
  # - `source_collection_listings`: one row per listing of a connection, by the listing's
  #   id, `external_id`: its `started_at`, the part numbers that arrived (`parts`), the
  #   number of the part that said `complete` (`last_part`) and when every part from 1 to
  #   that one had arrived (`completed_at`). Bookkeeping: deleted a day after it was made.
  @public_id "^sc_[0-9a-hjkmnp-tv-z]{16}$"
  @system "^[a-z0-9.-]{1,253}$"

  def change do
    # The key a collection names its connection by: the connection, its organisation and
    # its adapter at once.
    create unique_index(:adapter_connections, [:id, :organisation_id, :adapter_id])

    create table(:source_collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :nothing), null: false

      add :connection_id,
          references(:adapter_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id, adapter_id: :adapter_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: :nothing
          )

      add :external_ref, :text, null: false
      add :url, :text, null: false
      add :title, :text, null: false
      add :target_system, :text
      add :target_path, :text
      add :last_listed_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_collections, [:public_id])
    create unique_index(:source_collections, [:id, :organisation_id])

    create unique_index(:source_collections, [:adapter_id, :external_ref],
             where: "ended_at IS NULL",
             name: :source_collections_live_index
           )

    create index(:source_collections, [:adapter_id, :external_ref, :ended_at])
    create index(:source_collections, [:connection_id], where: "ended_at IS NULL")
    create index(:source_collections, [:organisation_id])
    create index(:source_collections, [:workspace_id])

    create constraint(:source_collections, :source_collections_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    create constraint(:source_collections, :source_collections_external_ref_check,
             check: "char_length(external_ref) BETWEEN 1 AND 200"
           )

    create constraint(:source_collections, :source_collections_url_check,
             check: "url ~ '^https://' AND char_length(url) <= 2048"
           )

    create constraint(:source_collections, :source_collections_title_check,
             check: "char_length(title) BETWEEN 1 AND 1024"
           )

    create constraint(:source_collections, :source_collections_target_check,
             check:
               "(target_system IS NULL AND target_path IS NULL) OR " <>
                 "(target_system IS NOT NULL AND target_path IS NOT NULL AND " <>
                 "target_system ~ '#{@system}' AND char_length(target_path) BETWEEN 1 AND 200)"
           )

    create constraint(:source_collections, :source_collections_ended_check,
             check:
               "(ended_at IS NULL) = (ended_reason IS NULL) AND (ended_reason IS NULL OR " <>
                 "ended_reason IN ('disconnected', 'not_listed', 'connection_ended'))"
           )

    create table(:source_collection_listings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :connection_id,
          references(:adapter_connections,
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

    create unique_index(:source_collection_listings, [:connection_id, :external_id])
    create index(:source_collection_listings, [:organisation_id])
    create index(:source_collection_listings, [:inserted_at])

    create constraint(:source_collection_listings, :source_collection_listings_external_id_check,
             check: "char_length(external_id) BETWEEN 1 AND 200"
           )

    create constraint(:source_collection_listings, :source_collection_listings_parts_check,
             check:
               "cardinality(parts) BETWEEN 1 AND 10000 AND 1 <= ALL(parts) AND " <>
                 "(last_part IS NULL OR (last_part BETWEEN 1 AND 10000 AND last_part >= ALL(parts)))"
           )

    create constraint(:source_collection_listings, :source_collection_listings_completed_check,
             check: "completed_at IS NULL OR last_part IS NOT NULL"
           )
  end
end
