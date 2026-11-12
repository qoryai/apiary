defmodule Apiary.Repo.Migrations.CreateFeatureGrants do
  use Ecto.Migration

  # What each link below the instance says of a feature: a row per organisation and feature,
  # and per workspace and feature.
  #
  # - An organisation's row, `workspace_id` empty: `granted` true, the feature granted to an
  #   operator by an instance admin or to a client by its operator (opt-in: what has no row
  #   is off); `granted` false, the feature an instance admin took away from an organisation
  #   with no operator (opt-out: what has no row follows the instance).
  # - A workspace's row: the feature its organisation's owner took away from it. A workspace
  #   only narrows, so its rows are never granted, which a check says.
  #
  # `organisation_id`, and `workspace_id` under the composite key against `workspaces`,
  # matched simple since it is empty for the organisation's own rows. One row per
  # organisation and feature, and per workspace and feature, by two partial unique indexes.
  # The feature check lists the features there are.
  def change do
    create table(:feature_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: :delete_all
          )

      add :feature, :text, null: false
      add :granted, :boolean, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:feature_grants, [:organisation_id, :feature],
             where: "workspace_id IS NULL",
             name: :feature_grants_organisation_feature_index
           )

    create unique_index(:feature_grants, [:organisation_id, :workspace_id, :feature],
             where: "workspace_id IS NOT NULL",
             name: :feature_grants_workspace_feature_index
           )

    create constraint(:feature_grants, :feature_grants_feature_check,
             check: "feature IN ('observability', 'security', 'managed_organisations', 'factory')"
           )

    create constraint(:feature_grants, :feature_grants_workspace_narrows_check,
             check: "workspace_id IS NULL OR NOT granted"
           )
  end
end
