defmodule Apiary.Repo.Migrations.IndexAGatewaySRuns do
  use Ecto.Migration

  # A gateway's runs by their run id, unique: a run id names at most one run through a
  # gateway, so the gateway's batches, which name their run by its id alone, find exactly
  # one (`Apiary.Runs.Ingest`). It also serves the reference to the gateway's row.
  #
  # Concurrently, since `runs` is the largest table an instance has: outside a transaction
  # and without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create unique_index(:runs, [:gateway_id, :run_id],
             where: "gateway_id IS NOT NULL",
             name: :runs_gateway_id_run_id_index,
             concurrently: true
           )
  end
end
