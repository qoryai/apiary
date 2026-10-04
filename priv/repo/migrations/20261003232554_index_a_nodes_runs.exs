defmodule Apiary.Repo.Migrations.IndexANodesRuns do
  use Ecto.Migration

  # A node's runs, two ways:
  #
  # - the runs alive on each instance of a node, partial so that a run leaves the index
  #   when it ends: what the instance limit counts under the node's lock, and what Clear
  #   instance marks lost (`Apiary.Nodes`);
  # - a node's runs, newest first by when they started (a run that has only pinged by when
  #   the workspace first heard of it), in the order of the runs list's index: what a
  #   node's page and the runs list's `node:` filter read.
  #
  # Concurrently, since `runs` is the largest table an instance has: outside a transaction
  # and without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:runs, [:node_id, :instance_id],
             where: "state IN ('pending', 'running')",
             name: :runs_node_id_instance_id_alive_index,
             concurrently: true
           )

    create index(
             :runs,
             [:workspace_id, :node_id, "COALESCE(started_at, inserted_at) DESC", "id DESC"],
             name: :runs_workspace_id_node_id_started_index,
             concurrently: true
           )
  end
end
