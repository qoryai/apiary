defmodule Apiary.Repo.Migrations.NameTheNodeAndInstanceOfRuns do
  use Ecto.Migration

  # A run names the node it ran on and the instance it ran as; a delivery, the instance
  # that posted it.
  #
  # `runs.node_id` is the node of the access key the run's ping came with, copied when the
  # run is created and never moved: it serves the instance limit's count, the runs list's
  # `node:` filter and a node's runs. The node is of the run's workspace, by the composite
  # key; a node is deleted softly, so the run keeps its link, and should the node's row go
  # with a purge only `node_id` is cleared. `runs.instance_id` is the claim of the ping's
  # delivery; `deliveries.instance_id` the claim of the POST that carried the batch. Both
  # are claims, kept as they were said whatever happens to the instance's row.
  #
  # All three are NULL for a run whose key names no node, which is every run today.
  def change do
    alter table(:runs) do
      add :node_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:node_id]}
          )

      add :instance_id, :text
    end

    alter table(:deliveries) do
      add :instance_id, :text
    end

    create constraint(:runs, :runs_instance_id_check,
             check: "instance_id IS NULL OR char_length(instance_id) BETWEEN 1 AND 128"
           )

    create constraint(:deliveries, :deliveries_instance_id_check,
             check: "instance_id IS NULL OR char_length(instance_id) BETWEEN 1 AND 128"
           )
  end
end
