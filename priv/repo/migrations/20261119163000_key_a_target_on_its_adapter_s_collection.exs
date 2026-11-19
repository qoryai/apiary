defmodule Apiary.Repo.Migrations.KeyATargetOnItsAdapterSCollection do
  use Ecto.Migration

  # A target is one of an adapter's collections, as the integration contract has it
  # (`$defs/target` of `definitions.schema.json`): the collection's ref, and, when the
  # place has one, its address on a system, a host name and a path. A place that is not
  # on a host, such as a support queue, has a collection and no address.
  #
  # - `targets` (`Apiary.Runs.Target`): `adapter_id`, the adapter whose collection the
  #   target is, and `collection_external_ref`, the adapter's ref of that collection, 1 to
  #   200 characters. A target is unique per workspace on the two, in place of its system
  #   and path. `system` and `path` become optional, both or neither, with a plain index
  #   on them for the reads by address.
  # - `source_collections`, `source_items` and `work_items`: `target_collection_external_ref`,
  #   the ref of the target's collection, 1 to 200 characters, of the row's adapter. A row
  #   with a system has a ref: a row without a ref has no target.
  #
  # The migration moves no data. The new columns of `targets` are NOT NULL with no
  # default, and a row with a target system has a ref: on a database with a target, or a
  # collection, item or work item with a target system, Postgres refuses the migration and
  # nothing changes.
  #
  # Rolled back, the columns go, and a target's system and path are needed again, unique
  # per workspace.

  @tables [:source_collections, :source_items, :work_items]

  def up do
    alter table(:targets) do
      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :nothing), null: false
      add :collection_external_ref, :text, null: false
      modify :system, :text, null: true, from: {:text, null: false}
      modify :path, :text, null: true, from: {:text, null: false}
    end

    create constraint(:targets, :targets_collection_external_ref_check,
             check: "char_length(collection_external_ref) BETWEEN 1 AND 200"
           )

    create constraint(:targets, :targets_address_check,
             check: "(system IS NULL) = (path IS NULL)"
           )

    drop index(:targets, [:workspace_id, :system, :path])
    create index(:targets, [:workspace_id, :system, :path])
    create unique_index(:targets, [:workspace_id, :adapter_id, :collection_external_ref])

    for table <- @tables do
      alter table(table) do
        add :target_collection_external_ref, :text
      end

      create constraint(table, :"#{table}_target_collection_check",
               check: "target_system IS NULL OR target_collection_external_ref IS NOT NULL"
             )

      create constraint(table, :"#{table}_target_collection_external_ref_check",
               check: "char_length(target_collection_external_ref) BETWEEN 1 AND 200"
             )
    end
  end

  def down do
    for table <- @tables do
      drop constraint(table, :"#{table}_target_collection_external_ref_check")
      drop constraint(table, :"#{table}_target_collection_check")

      alter table(table) do
        remove :target_collection_external_ref
      end
    end

    drop index(:targets, [:workspace_id, :adapter_id, :collection_external_ref])
    drop index(:targets, [:workspace_id, :system, :path])
    create unique_index(:targets, [:workspace_id, :system, :path])

    drop constraint(:targets, :targets_address_check)
    drop constraint(:targets, :targets_collection_external_ref_check)

    alter table(:targets) do
      remove :collection_external_ref
      remove :adapter_id
      modify :system, :text, null: false, from: {:text, null: true}
      modify :path, :text, null: false, from: {:text, null: true}
    end
  end
end
