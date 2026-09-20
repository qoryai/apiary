defmodule Apiary.Repo.Migrations.CreateRunConfigurations do
  use Ecto.Migration

  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  # The run configurations as served: immutable rows, one per version, of the hive's
  # baseline (no repository) or of a repository. `document` is the exact bytes a runner
  # was given and `digest` is `sha256=` and the hex of those bytes.
  def change do
    create table(:run_configurations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :hive_id,
          references(:hives,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :repository_id,
          references(:repositories,
            type: :binary_id,
            with: [hive_id: :hive_id],
            on_delete: :delete_all
          )

      add :version, :integer, null: false
      add :document, :text, null: false
      add :digest, :text, null: false
      add :rendered_at, :utc_datetime_usec, null: false
      add :changed_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :policy_change_id, references(:policy_changes, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:run_configurations, :run_configurations_version_check,
             check: "version >= 1"
           )

    # The current one is the highest version: read from this index, newest first.
    create unique_index(
             :run_configurations,
             [:hive_id, "COALESCE(repository_id, #{@nobody})", :version],
             name: :run_configurations_version_index
           )

    create index(:run_configurations, [:hive_id, :digest])
    create index(:run_configurations, [:organisation_id, :hive_id])
    create index(:run_configurations, [:repository_id])
    create index(:run_configurations, [:changed_by_id])
    create index(:run_configurations, [:policy_change_id])
  end
end
