defmodule Apiary.Repo.Migrations.IndexATargetsRunsByStart do
  use Ecto.Migration

  # A target's runs, newest first by when they started (a run that has only pinged by when
  # the workspace first heard of it), in the order of the runs list's index: what a
  # target's page lists and pages through, and the one read that finds each target's last
  # run for the targets' index (`Apiary.Targets`). It replaces the index on
  # `(workspace_id, target_id)`, which is its prefix and serves nothing it does not.
  #
  # Concurrently, since `runs` is the largest table an instance has: outside a transaction
  # and without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(
             :runs,
             [:workspace_id, :target_id, "COALESCE(started_at, inserted_at) DESC", "id DESC"],
             name: :runs_workspace_id_target_id_started_index,
             concurrently: true
           )

    drop index(:runs, [:workspace_id, :target_id], concurrently: true)
  end
end
