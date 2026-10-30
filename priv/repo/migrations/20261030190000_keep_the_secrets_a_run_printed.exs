defmodule Apiary.Repo.Migrations.KeepTheSecretsARunPrinted do
  use Ecto.Migration

  # The secrets found in a run's text as it was stored (`Apiary.Runs.LeakedSecrets`): where
  # each one is, never the secret. A secret in the run's output or events is the run's row;
  # one in a machine log or a release reason is the dispatch's. At most 1,000 rows for a
  # run, and for each of a dispatch's two texts; the rest are counted beside them.
  def change do
    create table(:leaked_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all)
      add :dispatch_id, references(:dispatches, type: :binary_id, on_delete: :delete_all)
      add :kind, :text, null: false
      add :place, :text, null: false
      add :step, :integer
      # The sequence of the log chunk or of the event the secret starts in; none for a
      # machine log or a release reason, which a dispatch has one of.
      add :source_sequence, :bigint
      add :offset, :integer, null: false
      add :length, :integer, null: false
      add :matched_id, :text
      add :at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:leaked_secrets, :leaked_secrets_place_check,
             check:
               "(place IN ('step', 'log', 'event') AND run_id IS NOT NULL " <>
                 "AND dispatch_id IS NULL AND source_sequence IS NOT NULL " <>
                 "AND (place = 'step') = (step IS NOT NULL)) OR " <>
                 "(place IN ('machine_log', 'release_reason') AND dispatch_id IS NOT NULL " <>
                 "AND run_id IS NULL AND source_sequence IS NULL AND step IS NULL)"
           )

    create constraint(:leaked_secrets, :leaked_secrets_kind_check,
             check: "kind ~ '^[a-z][a-z0-9_]{0,63}$'"
           )

    create constraint(:leaked_secrets, :leaked_secrets_span_check,
             check: "\"offset\" >= 0 AND length > 0"
           )

    # One row for one secret at one place: a text stored again, as a rebuild of the run's
    # projection stores its log, adds none.
    create unique_index(:leaked_secrets, [:run_id, :source_sequence, :offset],
             where: "run_id IS NOT NULL",
             name: :leaked_secrets_run_index
           )

    create unique_index(:leaked_secrets, [:dispatch_id, :place, :offset],
             where: "dispatch_id IS NOT NULL",
             name: :leaked_secrets_dispatch_index
           )

    # The purge of an organisation or a workspace deletes the rows by these, in batches.
    create index(:leaked_secrets, [:organisation_id])
    create index(:leaked_secrets, [:workspace_id])

    alter table(:runs) do
      add :leaked_secrets_omitted, :integer, null: false, default: 0
    end

    alter table(:dispatches) do
      add :machine_log_secrets_omitted, :integer, null: false, default: 0
      add :release_reason_secrets_omitted, :integer, null: false, default: 0
    end
  end
end
