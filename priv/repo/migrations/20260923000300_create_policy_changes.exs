defmodule Apiary.Repo.Migrations.CreatePolicyChanges do
  use Ecto.Migration

  # The history of the security policy: one row per change, of the hive's baseline (no
  # repository) or of a repository's rules, with the rule set before and after it.
  def change do
    create table(:policy_changes, primary_key: false) do
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

      add :action, :text, null: false
      # The host or the credential the change is about; null for a change of mode.
      add :subject, :text
      add :before, :map, null: false
      add :after, :map, null: false
      # The version of the run configuration in force for the target after the change.
      add :version_after, :integer
      add :changed_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:policy_changes, [:hive_id, :inserted_at])
    create index(:policy_changes, [:hive_id, :repository_id, :inserted_at])
    create index(:policy_changes, [:organisation_id, :hive_id])
    create index(:policy_changes, [:changed_by_id])
  end
end
