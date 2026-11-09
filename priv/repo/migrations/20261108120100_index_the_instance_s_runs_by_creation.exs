defmodule Apiary.Repo.Migrations.IndexTheInstanceSRunsByCreation do
  use Ecto.Migration

  # The runs of the whole instance in the order of the run list, `GET /v1/runs`
  # (`Apiary.Runs.RunList`): the last created first, then the `rn_` id, the greatest
  # first, compared byte by byte. A page without a workspace reads it in that order, and
  # `before` starts the read inside it, so no page sorts the table.
  #
  # Concurrently, since `runs` is the largest table an instance has: outside a transaction
  # and without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:runs, ["inserted_at DESC", ~s|(public_id COLLATE "C") DESC|],
             name: :runs_inserted_at_public_id_index,
             concurrently: true
           )
  end
end
