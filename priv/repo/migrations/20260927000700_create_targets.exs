defmodule Apiary.Repo.Migrations.CreateTargets do
  use Ecto.Migration

  # What a run changes: a target, by its path in a system, the engine's words (the software
  # body calls them a repository on a forge). One row per system and path in a workspace,
  # first seen when a run named it. `egress_mode` is the target's own mode, `observe` or
  # `enforce`; NULL, the default, follows the workspace's.
  #
  # `(id, workspace_id)` is unique: what a run, a policy rule and a run configuration
  # reference, so the database holds each to a target of its own workspace.
  def change do
    create table(:targets, primary_key: false) do
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

      add :system, :text, null: false
      add :path, :text, null: false
      add :egress_mode, :text
      add :first_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:targets, [:workspace_id, :system, :path])
    create unique_index(:targets, [:id, :workspace_id])
    create index(:targets, [:organisation_id, :workspace_id])

    create constraint(:targets, :targets_egress_mode_check,
             check: "egress_mode IS NULL OR egress_mode IN ('observe', 'enforce')"
           )
  end
end
