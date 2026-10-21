defmodule Apiary.Repo.Migrations.NameAWorkItemSTicketByItsConnection do
  use Ecto.Migration

  # A work item's ticket is named as an external id: the ticket's ref at its source,
  # `external_ref` (was `ref`), and the connection it came through, `connection_id`, an
  # organisation's connection to an adapter (`adapter_connections`,
  # `Apiary.Adapters.Connection`), which says what system the ref is of. The ids Qory
  # gives a work item stay `id`, `public_id` and `number`.
  #
  # - `external_ref` keeps the bounds `ref` had, 1 to 255 characters; its check is
  #   renamed with it, `work_items_external_ref_check`.
  # - `connection_id` is required, and of the work item's organisation (the composite key
  #   on `organisation_id`, as the work item's workspace is). A connection ends by its
  #   state and is never deleted alone: its rows go only with its organisation, whose
  #   purge deletes the work items first (`Apiary.Deletion.Tables`). The key refuses
  #   deleting a connection a work item names, so that a work item stays when its
  #   connection ends. It is NO ACTION, not RESTRICT: checked at the end of the statement,
  #   so one that deletes an organisation removes both, whatever order its cascades run in.
  # - Nothing is unique on (`connection_id`, `external_ref`); a ticket has one work item,
  #   which 20261017144000's unique index holds. The index serves the key.
  #
  # The table starts empty: no work item names a connection yet, so this migration
  # refuses to run while `work_items` holds a row.
  @refusal "Qory names each work item''s ticket by the connection it came through, " <>
             "which no work item kept so far, so this migration runs only while " <>
             "work_items is empty. It holds rows."

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

    rename table(:work_items), :ref, to: :external_ref

    execute(
      "ALTER TABLE work_items RENAME CONSTRAINT work_items_ref_check " <>
        "TO work_items_external_ref_check"
    )

    alter table(:work_items) do
      add :connection_id,
          references(:adapter_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false
    end

    create index(:work_items, [:connection_id, :external_ref])
  end

  def down do
    drop index(:work_items, [:connection_id, :external_ref])

    alter table(:work_items) do
      remove :connection_id
    end

    execute(
      "ALTER TABLE work_items RENAME CONSTRAINT work_items_external_ref_check " <>
        "TO work_items_ref_check"
    )

    rename table(:work_items), :external_ref, to: :ref
  end
end
