defmodule Apiary.Repo.Migrations.KeepWorkItems do
  use Ecto.Migration

  # A workspace's work items (`Apiary.WorkItems.WorkItem`), what happened to each
  # (`Apiary.WorkItems.WorkItemEvent`), and the counter their numbers come from
  # (`Apiary.WorkItems.Number`):
  #
  # - `work_item_counters`: one row per workspace, made with its first work item, holding
  #   the last number given. A number is taken by an upsert that adds one, inside the
  #   transaction that writes the work item, so the row stays locked until it commits and
  #   a rolled back work item gives its number back.
  # - `work_items`: a work item, numbered from 1 in its workspace, never twice. What it
  #   was taken in from is a snapshot of that moment (`ref`, `url`, `title`,
  #   `collection_title`), with its owner and the first instruction, 0 to 4,000
  #   characters. `public_id` is `wi_` and sixteen lowercase Crockford base32 characters.
  #   The states are the first phase's: `exploring`, `closed` and `undone`; a closed one
  #   has the time it closed, and only a closed one has it.
  # - `work_item_events`: one row per thing that happened to a work item, with who did
  #   it: a person or an adapter, by id, or the instance, with none. `data` is a JSON
  #   object of 16 KiB at most.
  #
  # Every table is held to its workspace's organisation by the composite key, and an
  # event to its work item's workspace, as a run's events are. The people are plain
  # references, indexed: an account is made a tombstone, never deleted.
  @public_id "^wi_[0-9a-hjkmnp-tv-z]{16}$"

  def change do
    create table(:work_item_counters, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true

      add :last_number, :bigint, null: false
    end

    create index(:work_item_counters, [:organisation_id])

    create constraint(:work_item_counters, :work_item_counters_last_number_check,
             check: "last_number >= 1"
           )

    create table(:work_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :public_id, :text, null: false
      add :number, :bigint, null: false
      add :ref, :text, null: false
      add :url, :text
      add :title, :text, null: false
      add :collection_title, :text, null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :first_instruction, :text, null: false, default: ""
      add :state, :text, null: false

      add :taken_in_by_id, references(:users, type: :binary_id, on_delete: :nothing), null: false

      add :taken_in_at, :utc_datetime_usec, null: false
      add :closed_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :closed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:work_items, [:public_id])
    create unique_index(:work_items, [:id, :workspace_id])
    create unique_index(:work_items, [:workspace_id, :number])
    create index(:work_items, [:organisation_id, :workspace_id])
    create index(:work_items, [:owner_id])
    create index(:work_items, [:taken_in_by_id])
    create index(:work_items, [:closed_by_id])

    create constraint(:work_items, :work_items_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    create constraint(:work_items, :work_items_number_check, check: "number >= 1")

    create constraint(:work_items, :work_items_ref_check,
             check: "char_length(ref) BETWEEN 1 AND 255"
           )

    create constraint(:work_items, :work_items_url_check,
             check:
               "url IS NULL OR (char_length(url) <= 2048 AND " <>
                 "url ~ '^https?://[^/@[:space:]]+(/[^[:space:]]*)?$')"
           )

    create constraint(:work_items, :work_items_title_check,
             check: "char_length(title) BETWEEN 1 AND 1024"
           )

    create constraint(:work_items, :work_items_collection_title_check,
             check: "char_length(collection_title) BETWEEN 1 AND 1024"
           )

    create constraint(:work_items, :work_items_first_instruction_check,
             check: "char_length(first_instruction) <= 4000"
           )

    create constraint(:work_items, :work_items_state_check,
             check: "state IN ('exploring', 'closed', 'undone')"
           )

    create constraint(:work_items, :work_items_closed_check,
             check:
               "(state = 'closed') = (closed_at IS NOT NULL) AND " <>
                 "(closed_by_id IS NULL OR closed_at IS NOT NULL)"
           )

    create table(:work_item_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :work_item_id,
          references(:work_items,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :kind, :text, null: false
      add :actor_kind, :text, null: false
      add :actor_id, :binary_id
      add :at, :utc_datetime_usec, null: false
      add :data, :jsonb, null: false, default: fragment("'{}'::jsonb")
    end

    create index(:work_item_events, [:work_item_id, :at])
    create index(:work_item_events, [:organisation_id, :workspace_id])

    create constraint(:work_item_events, :work_item_events_kind_check,
             check: "kind IN ('taken_in', 'closed', 'undone')"
           )

    create constraint(:work_item_events, :work_item_events_actor_check,
             check:
               "actor_kind IN ('person', 'adapter', 'instance') AND " <>
                 "(actor_kind = 'instance') = (actor_id IS NULL)"
           )

    create constraint(:work_item_events, :work_item_events_data_check,
             check: "jsonb_typeof(data) = 'object' AND octet_length(data::text) <= 16384"
           )
  end
end
