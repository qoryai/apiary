defmodule Apiary.Repo.Migrations.IndexRunsForRetention do
  use Ecto.Migration

  # Built concurrently, so the receiver keeps writing to `runs` while they build; that
  # cannot happen inside a transaction, and the migration lock is a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The retention job reads the runs of a hive last heard from before a cut-off that it
  # has not pruned yet. Partial, so a run leaves the index when it is pruned and a night's
  # read is the night's work, not the hive's history.
  @events "runs_retention_events_index"
  @log "runs_retention_log_index"

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@events}
    ON runs (hive_id, (COALESCE(last_event_at, inserted_at)), id)
    WHERE events_pruned_at IS NULL
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@log}
    ON runs (hive_id, (COALESCE(last_event_at, inserted_at)), id)
    WHERE log_pruned_at IS NULL
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@log}"
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@events}"
  end
end
