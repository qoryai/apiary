defmodule Apiary.Repo.Migrations.KeyAComposedRunConfigurationByItsPolicyRow do
  use Ecto.Migration

  # A composed run configuration (`Apiary.Policy.ComposedConfiguration`) is one row per
  # document and run configuration it was composed from, not per document alone: leaving
  # the policy's `image` out can give two run configurations the same bytes, and each
  # row then names the one it was composed from. The unique index becomes the
  # workspace, the digest and the run configuration, a row composed from none counted as
  # one. Rows already kept keep their run configuration. Down puts the index on the
  # digest back, which fails while two rows share a digest.

  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def up do
    drop unique_index(:composed_run_configurations, [:organisation_id, :workspace_id, :digest])

    create unique_index(
             :composed_run_configurations,
             [
               :organisation_id,
               :workspace_id,
               :digest,
               "COALESCE(run_configuration_id, #{@nobody})"
             ],
             name: :composed_run_configurations_policy_index
           )
  end

  def down do
    drop index(:composed_run_configurations, [], name: :composed_run_configurations_policy_index)
    create unique_index(:composed_run_configurations, [:organisation_id, :workspace_id, :digest])
  end
end
