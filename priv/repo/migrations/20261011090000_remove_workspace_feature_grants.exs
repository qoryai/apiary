defmodule Apiary.Repo.Migrations.RemoveWorkspaceFeatureGrants do
  use Ecto.Migration

  # A workspace has its organisation's features: no owner takes features away from one any
  # more. The grants that named a workspace are deleted, and `feature_grants` loses
  # `workspace_id` with what stood on it: its foreign key, the unique index of a
  # workspace's rows, the check that a workspace's row is never granted, and the partial
  # unique index of an organisation's rows, which only held where `workspace_id` was
  # empty. That index comes back whole, one row per organisation and feature.
  #
  # Rolling back gives the table its column, its key, its indexes and its check again; the
  # grants deleted do not come back, so every workspace keeps its organisation's features.
  def up do
    execute "DELETE FROM feature_grants WHERE workspace_id IS NOT NULL"

    drop constraint(:feature_grants, :feature_grants_workspace_narrows_check)
    drop index(:feature_grants, [], name: :feature_grants_workspace_feature_index)
    drop index(:feature_grants, [], name: :feature_grants_organisation_feature_index)

    alter table(:feature_grants) do
      remove :workspace_id
    end

    create unique_index(:feature_grants, [:organisation_id, :feature],
             name: :feature_grants_organisation_feature_index
           )
  end

  def down do
    drop index(:feature_grants, [], name: :feature_grants_organisation_feature_index)

    alter table(:feature_grants) do
      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: :delete_all
          )
    end

    create unique_index(:feature_grants, [:organisation_id, :feature],
             where: "workspace_id IS NULL",
             name: :feature_grants_organisation_feature_index
           )

    create unique_index(:feature_grants, [:organisation_id, :workspace_id, :feature],
             where: "workspace_id IS NOT NULL",
             name: :feature_grants_workspace_feature_index
           )

    create constraint(:feature_grants, :feature_grants_workspace_narrows_check,
             check: "workspace_id IS NULL OR NOT granted"
           )
  end
end
