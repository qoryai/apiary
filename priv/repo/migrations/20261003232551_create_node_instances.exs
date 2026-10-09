defmodule Apiary.Repo.Migrations.CreateNodeInstances do
  use Ecto.Migration

  # An instance of a node (`Apiary.Nodes.Instance`): what Forager using the node's access
  # key reports itself as, by the instance id it signs. The id is a claim, kept for display,
  # the audit and the instance limit, never for authorisation, so the row carries no
  # integrity code.
  #
  # The node is the instance's by the composite key on `(node_id, workspace_id)`, so no row
  # can name a node of another workspace; the row goes with its node, which only a purge
  # deletes. `(node_id, instance_id)` is unique: an instance is the node's, not its key's,
  # so one that moves to the node's replacement key stays one instance, and
  # `access_key_id` is the key it last used, cleared should that key's row go. `name` is
  # what Forager said it is called, kept only when it matches the pattern of a name.
  # `cleared_at` and `cleared_by_id` say who last cleared it (Clear instance).
  #
  # The index on `(workspace_id, last_seen_at DESC)` serves the pages, which read the
  # instances seen last first, and the pruning, which reads those not seen for a while.
  def change do
    create table(:node_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :node_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :access_key_id, references(:access_keys, type: :binary_id, on_delete: :nilify_all)
      add :instance_id, :text, null: false
      add :name, :text
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :last_runner_version, :text
      add :last_contract_version, :integer
      add :cleared_at, :utc_datetime_usec
      add :cleared_by_id, references(:users, type: :binary_id, on_delete: :nothing)
    end

    create unique_index(:node_instances, [:node_id, :instance_id])
    create index(:node_instances, [:workspace_id, "last_seen_at DESC"])
    create index(:node_instances, [:organisation_id, :workspace_id])
    create index(:node_instances, [:access_key_id])
    create index(:node_instances, [:cleared_by_id])

    create constraint(:node_instances, :node_instances_instance_id_check,
             check: "char_length(instance_id) BETWEEN 1 AND 128"
           )

    create constraint(:node_instances, :node_instances_name_check,
             check: "name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'"
           )

    create constraint(:node_instances, :node_instances_seen_check,
             check: "last_seen_at >= first_seen_at"
           )

    create constraint(:node_instances, :node_instances_cleared_check,
             check: "cleared_by_id IS NULL OR cleared_at IS NOT NULL"
           )
  end
end
