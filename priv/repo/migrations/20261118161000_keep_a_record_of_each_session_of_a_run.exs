defmodule Apiary.Repo.Migrations.KeepARecordOfEachSessionOfARun do
  use Ecto.Migration

  # `session_records`: one row for each session of a run (`Apiary.Runs.SessionRecord`),
  # kept after the run's events are deleted:
  #
  # - `run_id` and `session_number` are the run and Forager's number of the session in
  #   it, from 1; the pair is unique;
  # - `dispatch_run_id`, `work_item_id`, `stage_id`, `workflow` and `attempt` come from the
  #   run of the queue the run belongs to and, for a shared run, from the session's row in
  #   `shared_run_sessions`; all null for a run the queue did not start;
  # - `target_id` is the run's target, null for none;
  # - `started_at` and `ended_at` are the times of the session's `dev.qory.session.started`
  #   and `dev.qory.session.exited`, null until the event is projected;
  # - `duration_ms`, `turns`, the four token counts, `cost_usd` and `error` come from the
  #   session's `dev.qory.runtime.result` events, null where no result carried the value
  #   (unknown, never 0), and `model` from its `dev.qory.runtime.started`.
  #
  # `session_key_windows`: for each session, key and limit window the first and the last
  # utilization that the gateway's key reports gave while the session ran, in whole percent,
  # the times they were observed, and `share`, the last less the first. `key_id` is the id
  # of the key's value (`secret_values.id`, `model_key_states.secret_value_id`), kept
  # without a foreign key so a deleted key leaves the history of the sessions that used it.
  #
  # Two new tables: no row of another table is written again. The foreign keys, the
  # indexes and the checks are part of their creation.
  def change do
    create table(:session_records, primary_key: false) do
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

      add :dispatch_run_id,
          references(:dispatch_runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:dispatch_run_id]}
          )

      # A work item names its runs by the organisation, as `dispatch_runs` does: it can
      # move to another workspace.
      add :work_item_id,
          references(:work_items,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: {:nilify, [:work_item_id]}
          )

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:target_id]}
          )

      add :stage_id, :text
      add :workflow, :text
      add :attempt, :integer
      add :session_number, :integer, null: false
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :turns, :integer
      add :input_tokens, :bigint
      add :output_tokens, :bigint
      add :cache_read_tokens, :bigint
      add :cache_write_tokens, :bigint
      add :cost_usd, :decimal, precision: 15, scale: 6
      add :model, :text
      add :error, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_records, [:run_id, :session_number])
    create unique_index(:session_records, [:id, :workspace_id])
    create index(:session_records, [:organisation_id, :workspace_id])
    create index(:session_records, [:work_item_id])
    create index(:session_records, [:dispatch_run_id])
    create index(:session_records, [:workspace_id, :target_id])

    create constraint(:session_records, :session_records_session_number_check,
             check: "session_number >= 1"
           )

    create constraint(:session_records, :session_records_attempt_check,
             check: "attempt IS NULL OR attempt >= 1"
           )

    create constraint(:session_records, :session_records_turns_check,
             check: "turns IS NULL OR turns >= 0"
           )

    create constraint(:session_records, :session_records_duration_check,
             check: "duration_ms IS NULL OR duration_ms >= 0"
           )

    create constraint(:session_records, :session_records_tokens_check,
             check:
               "(input_tokens IS NULL OR input_tokens >= 0) AND " <>
                 "(output_tokens IS NULL OR output_tokens >= 0) AND " <>
                 "(cache_read_tokens IS NULL OR cache_read_tokens >= 0) AND " <>
                 "(cache_write_tokens IS NULL OR cache_write_tokens >= 0)"
           )

    create constraint(:session_records, :session_records_cost_check,
             check: "cost_usd IS NULL OR cost_usd >= 0"
           )

    create table(:session_key_windows, primary_key: false) do
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

      add :session_record_id,
          references(:session_records,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :key_id, :binary_id, null: false
      add :window, :text, null: false
      add :first_utilization, :decimal, precision: 5, scale: 2
      add :first_observed_at, :utc_datetime_usec
      add :last_utilization, :decimal, precision: 5, scale: 2
      add :last_observed_at, :utc_datetime_usec
      add :share, :decimal, precision: 6, scale: 2

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_key_windows, [:session_record_id, :key_id, :window])
    create index(:session_key_windows, [:organisation_id, :workspace_id])

    create constraint(:session_key_windows, :session_key_windows_window_check,
             check: ~S("window" ~ '^[a-z][a-z0-9_]{0,63}$')
           )

    create constraint(:session_key_windows, :session_key_windows_utilization_check,
             check:
               "(first_utilization IS NULL OR first_utilization BETWEEN 0 AND 100) AND " <>
                 "(last_utilization IS NULL OR last_utilization BETWEEN 0 AND 100)"
           )

    # A window that reset during the session makes the share negative.
    create constraint(:session_key_windows, :session_key_windows_share_check,
             check: "share IS NULL OR share BETWEEN -100 AND 100"
           )
  end
end
