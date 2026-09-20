defmodule Apiary.Repo.Migrations.IndexRunsByAccessKey do
  use Ecto.Migration

  # Built concurrently, so the receiver keeps writing to `runs` while it builds; that
  # cannot happen inside a transaction, and the migration lock is a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The overview's Machines card reads the last run of each key of the hive in one
  # `DISTINCT ON (access_key_id)` ordered by when the run started; this is that order.
  @by_key "runs_hive_id_access_key_id_started_index"

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@by_key}
    ON runs (hive_id, access_key_id, (COALESCE(started_at, inserted_at)) DESC, id DESC)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@by_key}"
  end
end
