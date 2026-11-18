defmodule Apiary.Repo.Migrations.KeepTheSessionsOfASharedRun do
  use Ecto.Migration

  # `shared_run_sessions`: the sessions of a run of a stage with `shared_run: true`
  # (`Apiary.Stages.Session`), one row per session that the stage runner started in the run:
  #
  # - `sequence` is Qory Apiary's number for the session in the run, from 1;
  # - `forager_session` is the number of the session as the run reported it at the
  #   session's end, nil until then;
  # - `stage_entry`, `loop_entry` and `round` are the session's position in the stage, and
  #   `workflow` its workflow;
  # - `state` and `reason` are the session's end as the run reported it;
  # - `verdict_number` is the number of the run's newest `verdict` version when the stage
  #   runner stepped on the session's end, nil for none;
  # - `response` is what the step returned: the next session, or the end of the run.
  #
  # A new table: no row of another table is written again, and its keys and its checks
  # are part of its creation.
  def change do
    create table(:shared_run_sessions, primary_key: false) do
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

      add :dispatch_run_id,
          references(:dispatch_runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :sequence, :integer, null: false
      add :forager_session, :integer
      add :stage_entry, :integer, null: false
      add :loop_entry, :integer
      add :round, :integer, null: false
      add :workflow, :text, null: false
      add :state, :text
      add :reason, :text
      add :verdict_number, :integer
      add :response, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:shared_run_sessions, [:dispatch_run_id, :sequence])

    create unique_index(:shared_run_sessions, [:dispatch_run_id, :forager_session],
             where: "forager_session IS NOT NULL"
           )

    create index(:shared_run_sessions, [:organisation_id, :workspace_id])

    create constraint(:shared_run_sessions, :shared_run_sessions_sequence_check,
             check: "sequence >= 1"
           )

    create constraint(:shared_run_sessions, :shared_run_sessions_forager_session_check,
             check: "forager_session IS NULL OR forager_session >= 1"
           )

    create constraint(:shared_run_sessions, :shared_run_sessions_state_check,
             check: "state IS NULL OR state IN ('succeeded', 'failed', 'cancelled')"
           )
  end
end
