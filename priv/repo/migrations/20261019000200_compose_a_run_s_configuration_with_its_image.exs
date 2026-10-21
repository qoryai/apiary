defmodule Apiary.Repo.Migrations.ComposeARunSConfigurationWithItsImage do
  use Ecto.Migration

  # A run configuration composed for a run (`Apiary.Policy.ComposedConfiguration`), and the
  # image a run is given:
  #
  # - `composed_run_configurations`: the documents composed from a workspace's run
  #   configuration, or from none, with an image beside its `security_policy`, or with the
  #   policy's `image` left out of a prebuild's. Immutable rows, one per document, keyed by
  #   the digest of its bytes within the workspace: `document` is the exact bytes served,
  #   `digest` is `sha256=` and the hex of them, `run_configuration_id` the policy row it
  #   was composed from, nil for none, and `image` the image it names, nil for none. A row
  #   goes with its policy row, and with its workspace;
  # - `runs.configured_image`: the image a run was given at its attach, which every later
  #   answer for the run names, nil for a run given none.
  #
  # Nothing exists to fill: no run was given an image before. Down drops the table and the
  # column.

  def change do
    create table(:composed_run_configurations, primary_key: false) do
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

      add :run_configuration_id,
          references(:run_configurations, type: :binary_id, on_delete: :delete_all)

      add :image, :text
      add :document, :text, null: false
      add :digest, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:composed_run_configurations, [:organisation_id, :workspace_id, :digest])
    create index(:composed_run_configurations, [:workspace_id])
    create index(:composed_run_configurations, [:run_configuration_id])

    alter table(:runs) do
      add :configured_image, :text
    end
  end
end
