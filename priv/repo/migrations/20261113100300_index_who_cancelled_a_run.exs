defmodule Apiary.Repo.Migrations.IndexWhoCancelledARun do
  use Ecto.Migration

  # The runs a member cancelled, by the member (`cancel_requested_by_id`, from
  # `20261113100000`). When a user's row is deleted, its key sets the column to NULL in
  # each of those runs; without this index Postgres scans `runs` to find them. Only the
  # cancelled runs have a member, so the index leaves the other rows out.
  #
  # Concurrently, since `runs` is the largest table an instance has: outside a transaction
  # and without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:runs, [:cancel_requested_by_id],
             where: "cancel_requested_by_id IS NOT NULL",
             concurrently: true
           )
  end
end
