defmodule Apiary.Repo.Migrations.CreateRetentionRuns do
  use Ecto.Migration

  # What the retention job did to a hive, one row per hive per run of the job: the
  # settings and the cut-offs it ran under and what it deleted.
  def change do
    create table(:retention_runs, primary_key: false) do
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

      # `schedule` for the nightly job, `manual` for `mix apiary.prune`.
      add :trigger, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec, null: false
      add :events_retention_days, :integer
      add :log_retention_days, :integer
      add :events_cutoff, :utc_datetime_usec
      add :log_cutoff, :utc_datetime_usec
      add :runs_pruned, :integer, null: false, default: 0
      add :events_deleted, :bigint, null: false, default: 0
      add :log_chunks_deleted, :bigint, null: false, default: 0
      add :log_bytes_deleted, :bigint, null: false, default: 0
      add :deliveries_deleted, :bigint, null: false, default: 0
      # False when the job stopped before it was through: the next night goes on.
      add :complete, :boolean, null: false, default: true
    end

    create constraint(:retention_runs, :retention_runs_trigger_check,
             check: "trigger IN ('schedule', 'manual')"
           )

    create index(:retention_runs, [:hive_id, :started_at])
    create index(:retention_runs, [:organisation_id, :hive_id])
  end
end
