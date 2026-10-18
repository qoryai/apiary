defmodule Apiary.Repo.Migrations.TakeWorkItemsInAgain do
  use Ecto.Migration

  # A work item names the ticket it was taken in from (`source_items`, 20261017143000),
  # is one per ticket in its organisation, may be declined, may be taken in again, and
  # may move to another workspace of its organisation while it is not live.
  #
  # - `adapter_id` is the adapter the ticket came through, held to the work item's
  #   connection by the composite key: the connection, its organisation and its adapter
  #   at once, NO ACTION as before. An adapter is never deleted, and a connection only
  #   with its organisation.
  # - One work item per ticket in an organisation, live or not: the unique index on
  #   (`organisation_id`, `adapter_id`, `external_ref`), whatever connection or collection
  #   the ticket comes through, so that a take in again has one work item to find.
  #   Nothing is unique on `item_id`.
  # - `item_id` is the ticket the work item was last taken in from, of the work item's
  #   organisation and adapter (the composite key). When the ticket's row goes, the work
  #   item stays, with its snapshot and no ticket (`ON DELETE SET NULL` of `item_id`
  #   alone), so no delete of a ticket waits on a work item and none deletes one.
  # - `external_ref` is 1 to 200 characters, the contract's `$defs/ref`, and `url` is
  #   required, `https://` alone, 2,048 characters at most, as a ticket's.
  # - `target_system` and `target_path` are where a change for the work item goes, to the
  #   contract's `$defs/target`, both required.
  # - `take_in` counts the take ins of the work item, from 1.
  # - `state` may be `declined`; a declined one has the time it was declined,
  #   `declined_at`, and the person who declined it, `declined_by_id`, where a person did,
  #   and no other has them, as a closed one has its closing. An event may be `declined`.
  # - The key of an event to its work item and the work item's workspace follows the work
  #   item to another workspace (`ON UPDATE CASCADE`). A run of the queue names its work
  #   item by the organisation instead (`dispatch_runs`, MATCH FULL, `ON DELETE CASCADE`,
  #   on the new unique index of `work_items` (`id`, `organisation_id`)), so it stays in
  #   the workspace it was queued in, beside its runs, when its work item moves; and it
  #   goes with its work item, wherever each is.
  #
  # The table starts empty: no work item names a ticket yet, so this migration refuses to
  # run while `work_items` holds a row.
  @refusal "Qory names each work item''s ticket and target, which no work item kept so " <>
             "far, so this migration runs only while work_items is empty. It holds rows."
  # definitions.schema.json: $defs.target's system, and $defs.url as the tickets hold it.
  @system "^[a-z0-9.-]{1,253}$"
  @url "^https://[^/?#@[:space:]]+([/?#][^[:space:]]*)?$"
  @old_url "^https?://[^/@[:space:]]+(/[^[:space:]]*)?$"

  def up do
    execute("LOCK TABLE work_items IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM work_items) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    drop constraint(:work_items, :work_items_external_ref_check)
    drop constraint(:work_items, :work_items_url_check)
    drop constraint(:work_items, :work_items_state_check)
    drop constraint(:work_items, :work_items_connection_id_fkey)

    alter table(:work_items) do
      modify :url, :text, null: false
      add :adapter_id, :binary_id, null: false
      add :item_id, :binary_id
      add :target_system, :text, null: false
      add :target_path, :text, null: false
      add :take_in, :integer, null: false
      add :declined_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :declined_at, :utc_datetime_usec
    end

    execute("""
    ALTER TABLE work_items ADD CONSTRAINT work_items_connection_id_fkey
      FOREIGN KEY (connection_id, organisation_id, adapter_id)
      REFERENCES adapter_connections (id, organisation_id, adapter_id) MATCH FULL
    """)

    execute("""
    ALTER TABLE work_items ADD CONSTRAINT work_items_item_id_fkey
      FOREIGN KEY (item_id, organisation_id, adapter_id)
      REFERENCES source_items (id, organisation_id, adapter_id)
      ON DELETE SET NULL (item_id)
    """)

    create unique_index(:work_items, [:organisation_id, :adapter_id, :external_ref])
    create unique_index(:work_items, [:id, :organisation_id])
    create index(:work_items, [:item_id])
    create index(:work_items, [:declined_by_id])

    create constraint(:work_items, :work_items_external_ref_check,
             check: "char_length(external_ref) BETWEEN 1 AND 200"
           )

    create constraint(:work_items, :work_items_url_check,
             check: "char_length(url) <= 2048 AND url ~ '#{@url}'"
           )

    create constraint(:work_items, :work_items_target_check,
             check: "target_system ~ '#{@system}' AND char_length(target_path) BETWEEN 1 AND 200"
           )

    create constraint(:work_items, :work_items_take_in_check, check: "take_in >= 1")

    create constraint(:work_items, :work_items_state_check,
             check: "state IN ('exploring', 'declined', 'closed', 'undone')"
           )

    create constraint(:work_items, :work_items_declined_check,
             check:
               "(state = 'declined') = (declined_at IS NOT NULL) AND " <>
                 "(declined_by_id IS NULL OR declined_at IS NOT NULL)"
           )

    drop constraint(:work_item_events, :work_item_events_kind_check)

    create constraint(:work_item_events, :work_item_events_kind_check,
             check: "kind IN ('taken_in', 'declined', 'closed', 'undone')"
           )

    execute("""
    ALTER TABLE work_item_events DROP CONSTRAINT work_item_events_work_item_id_fkey,
      ADD CONSTRAINT work_item_events_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    execute("""
    ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_work_item_id_fkey,
      ADD CONSTRAINT dispatch_runs_work_item_id_fkey
      FOREIGN KEY (work_item_id, organisation_id) REFERENCES work_items (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """)
  end

  # Rolled back, a work item names its ticket by its connection and ref alone, as before.
  # A run of the queue and an event name their work item by its workspace again, and
  # `declined` is no state and no kind of event, so the roll back refuses while a run of
  # the queue or an event names a work item of another workspace, and while a work item
  # is declined or an event is `declined`.
  def down do
    execute("""
    ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_work_item_id_fkey,
      ADD CONSTRAINT dispatch_runs_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE work_item_events DROP CONSTRAINT work_item_events_work_item_id_fkey,
      ADD CONSTRAINT work_item_events_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE
    """)

    drop constraint(:work_item_events, :work_item_events_kind_check)

    create constraint(:work_item_events, :work_item_events_kind_check,
             check: "kind IN ('taken_in', 'closed', 'undone')"
           )

    drop constraint(:work_items, :work_items_declined_check)
    drop constraint(:work_items, :work_items_state_check)
    drop constraint(:work_items, :work_items_take_in_check)
    drop constraint(:work_items, :work_items_target_check)
    drop constraint(:work_items, :work_items_url_check)
    drop constraint(:work_items, :work_items_external_ref_check)
    drop index(:work_items, [:declined_by_id])
    drop index(:work_items, [:item_id])
    drop index(:work_items, [:id, :organisation_id])
    drop index(:work_items, [:organisation_id, :adapter_id, :external_ref])
    drop constraint(:work_items, :work_items_item_id_fkey)
    drop constraint(:work_items, :work_items_connection_id_fkey)

    alter table(:work_items) do
      remove :declined_at
      remove :declined_by_id
      remove :take_in
      remove :target_path
      remove :target_system
      remove :item_id
      remove :adapter_id
      modify :url, :text, null: true
    end

    execute("""
    ALTER TABLE work_items ADD CONSTRAINT work_items_connection_id_fkey
      FOREIGN KEY (connection_id, organisation_id)
      REFERENCES adapter_connections (id, organisation_id) MATCH FULL
    """)

    create constraint(:work_items, :work_items_state_check,
             check: "state IN ('exploring', 'closed', 'undone')"
           )

    create constraint(:work_items, :work_items_url_check,
             check: "url IS NULL OR (char_length(url) <= 2048 AND url ~ '#{@old_url}')"
           )

    create constraint(:work_items, :work_items_external_ref_check,
             check: "char_length(external_ref) BETWEEN 1 AND 255"
           )
  end
end
