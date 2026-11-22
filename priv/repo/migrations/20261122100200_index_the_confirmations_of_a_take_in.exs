defmodule Apiary.Repo.Migrations.IndexTheConfirmationsOfATakeIn do
  use Ecto.Migration

  # `work_item_confirmations` keeps any number of confirmations per take in: a member
  # confirms again after a move back withdrew the confirmation. A plain index on
  # (`work_item_id`, `take_in`) replaces the unique one; it is built before the unique one
  # is dropped, so reads of a take in's confirmations always have an index.
  #
  # Concurrently, so neither step blocks writes to the table: outside a transaction and
  # without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:work_item_confirmations, [:work_item_id, :take_in],
             name: :work_item_confirmations_of_a_take_in_index,
             concurrently: true
           )

    drop index(:work_item_confirmations, [:work_item_id, :take_in], concurrently: true)
  end

  # Down builds the unique index again, which fails once a take in has two confirmations:
  # delete the older ones first, keeping the newest of each take in.
  def down do
    create unique_index(:work_item_confirmations, [:work_item_id, :take_in], concurrently: true)

    drop index(:work_item_confirmations, [:work_item_id, :take_in],
           name: :work_item_confirmations_of_a_take_in_index,
           concurrently: true
         )
  end
end
