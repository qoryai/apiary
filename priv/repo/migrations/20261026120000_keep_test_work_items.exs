defmodule Apiary.Repo.Migrations.KeepTestWorkItems do
  use Ecto.Migration

  # A work item may be a test (`test`): one Qory Apiary makes from a line a person types,
  # with no ticket and no work source behind it (`Apiary.WorkItems.take_in_test/2`).
  #
  # - `test` is false for every work item there is, and for every work item taken in from
  #   a ticket.
  # - `connection_id`, `adapter_id`, `external_ref` and `url` become nullable, and one
  #   check holds them instead (`work_items_test_check`): a test work item has none of
  #   them and no ticket (`item_id`); any other has all four, as before. `item_id` stays
  #   nullable for any other, as its ticket's row may go.
  # - The key to the connection keeps its columns (`connection_id`, `organisation_id`,
  #   `adapter_id`) and NO ACTION, and becomes MATCH SIMPLE: MATCH FULL refuses a row
  #   whose `organisation_id` is set while the other two are null, which a test work item
  #   is. MATCH SIMPLE checks a row whose three columns are set, which the check makes of
  #   every work item that is not a test, so it is held to its connection as before.
  #
  # Rolled back, the four columns are required again and the key is MATCH FULL. The roll
  # back refuses while a test work item is there, and changes nothing.
  @refusal "Qory Apiary keeps test work items, which have no ticket, so this migration " <>
             "rolls back only while no work item is a test. One is."

  def up do
    alter table(:work_items) do
      add :test, :boolean, null: false, default: false
    end

    execute "ALTER TABLE work_items ALTER COLUMN connection_id DROP NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN adapter_id DROP NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN external_ref DROP NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN url DROP NOT NULL"

    create constraint(:work_items, :work_items_test_check,
             check:
               "CASE WHEN test THEN connection_id IS NULL AND adapter_id IS NULL AND " <>
                 "item_id IS NULL AND external_ref IS NULL AND url IS NULL " <>
                 "ELSE connection_id IS NOT NULL AND adapter_id IS NOT NULL AND " <>
                 "external_ref IS NOT NULL AND url IS NOT NULL END"
           )

    execute("""
    ALTER TABLE work_items DROP CONSTRAINT work_items_connection_id_fkey,
      ADD CONSTRAINT work_items_connection_id_fkey
      FOREIGN KEY (connection_id, organisation_id, adapter_id)
      REFERENCES adapter_connections (id, organisation_id, adapter_id) MATCH SIMPLE
    """)
  end

  def down do
    execute("LOCK TABLE work_items IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM work_items WHERE test) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    execute("""
    ALTER TABLE work_items DROP CONSTRAINT work_items_connection_id_fkey,
      ADD CONSTRAINT work_items_connection_id_fkey
      FOREIGN KEY (connection_id, organisation_id, adapter_id)
      REFERENCES adapter_connections (id, organisation_id, adapter_id) MATCH FULL
    """)

    drop constraint(:work_items, :work_items_test_check)

    execute "ALTER TABLE work_items ALTER COLUMN url SET NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN external_ref SET NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN adapter_id SET NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN connection_id SET NOT NULL"

    alter table(:work_items) do
      remove :test
    end
  end
end
