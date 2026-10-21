defmodule Apiary.Repo.Migrations.KeepARunSSteps do
  use Ecto.Migration

  # The steps of a run's host work and joins, what the projector folds from its
  # `dev.qory.run.step_started` and `dev.qory.run.step_exited` (`Apiary.Runs.Step`), one
  # row per step number of a run:
  #
  # - `name`, `kind`, `started_sequence` and `started_at` are the start's, null until it is
  #   folded; `kind` is one of the contract's six or null;
  # - `state` is `running` until the step's exit or the run's exit is folded, then the
  #   exit's `succeeded`, `failed` or `cancelled`, or `cancelled` for a step the run ended
  #   during;
  # - `exit_code`, `duration_ms`, `exited_sequence` and `exited_at` are the exit's, null
  #   until it is folded.
  #
  # And `log_chunks.step`, the step a chunk is a log line of, null outside every step. The
  # index of a step's log lines is `20261022090100_index_a_step_s_log_lines`.
  def change do
    create table(:run_steps, primary_key: false) do
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

      add :run_id,
          references(:runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :step, :integer, null: false
      add :name, :text
      add :kind, :text
      add :state, :text, null: false, default: "running"
      add :exit_code, :integer
      add :duration_ms, :bigint
      add :started_sequence, :bigint
      add :started_at, :utc_datetime_usec
      add :exited_sequence, :bigint
      add :exited_at, :utc_datetime_usec
    end

    create unique_index(:run_steps, [:run_id, :step])
    create index(:run_steps, [:organisation_id, :workspace_id])

    create constraint(:run_steps, :run_steps_state_check,
             check: "state IN ('running', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:run_steps, :run_steps_kind_check,
             check: "kind IN ('fetch', 'compose', 'image', 'setup', 'join', 'wall')"
           )

    create constraint(:run_steps, :run_steps_step_check, check: "step >= 1")

    alter table(:log_chunks) do
      add :step, :integer
    end
  end
end
