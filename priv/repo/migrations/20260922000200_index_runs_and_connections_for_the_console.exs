defmodule Apiary.Repo.Migrations.IndexRunsAndConnectionsForTheConsole do
  use Ecto.Migration

  # Built concurrently, so writes to `runs` and `connections` go on while they build; that
  # cannot happen inside a transaction, and the migration lock is a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The runs list orders and ranges on when a run started, or, for a run that has only
  # pinged, on when the hive first heard of it: this is that expression, in that order.
  @runs_by_start "runs_hive_id_started_or_first_heard_index"

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@runs_by_start}
    ON runs (hive_id, (COALESCE(started_at, inserted_at)) DESC, id DESC)
    """

    # The hive's connections in a range.
    create_if_not_exists index(:connections, [:hive_id, :last_seen_at], concurrently: true)

    # An earlier revision of 20260922000100 created these two; no query reads by them.
    drop_if_exists index(:runs, [:hive_id, :started_at], concurrently: true)
    drop_if_exists index(:runs, [:hive_id, :repository_id, :started_at], concurrently: true)
  end

  def down do
    drop_if_exists index(:connections, [:hive_id, :last_seen_at], concurrently: true)
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@runs_by_start}"
  end
end
