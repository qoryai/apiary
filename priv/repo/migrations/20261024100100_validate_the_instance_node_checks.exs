defmodule Apiary.Repo.Migrations.ValidateTheInstanceNodeChecks do
  use Ecto.Migration

  # Validates the checks and keys `20261024100000_keep_a_pool_and_a_gateway_at_the_instance`
  # added NOT VALID: scans that take no lock that blocks writes to the tables. Down leaves
  # them as they are; that migration drops them.
  @constraints [
    nodes: ~w(nodes_place_check nodes_installed_as_check),
    dispatches: ~w(dispatches_pool_id_fkey),
    environments: ~w(environments_pool_id_fkey),
    dispatch_runs: ~w(dispatch_runs_pool_id_fkey),
    runs: ~w(runs_node_id_fkey),
    node_instances: ~w(node_instances_place_check node_instances_node_fkey)
  ]

  def up do
    for {table, names} <- @constraints, name <- names do
      execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
