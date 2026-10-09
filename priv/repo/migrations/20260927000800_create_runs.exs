defmodule Apiary.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  # A run, as Forager reported it and the projector folded it from its events
  # (`Apiary.Runs.Projector`): what ran, where, under which policy and run configuration,
  # and how it ended. `run_id` is Forager's id, unique in the workspace.
  # `(id, workspace_id)` is unique: what the events, the log chunks and the connections of a
  # run reference, so the database holds each to its run's workspace.
  #
  # The target is of the run's workspace, by the composite key, and should a target go only
  # `target_id` is cleared; `target_system` and `target_path` are the run's own copy of what
  # it named. The access key is cleared should its row go, and the person who closed the run
  # is a plain reference. The check keeps `state` to the states a run can be in.
  #
  # The indexes are the pages' and the jobs': the lost-run check reads the runs alive,
  # oldest heartbeat first; the runs list orders and ranges on when a run started, or, for
  # one that has only pinged, on when the workspace first heard of it; the Machines card
  # reads the last run of each key in that order; and the retention job reads the runs last
  # heard from before a cut-off that it has not pruned yet, partial so that a run leaves the
  # index when it is pruned.
  def change do
    create table(:runs, primary_key: false) do
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

      add :run_id, :uuid, null: false

      add :access_key_id, references(:access_keys, type: :binary_id, on_delete: :nilify_all)

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:target_id]}
          )

      add :target_system, :text
      add :target_path, :text
      add :task, :text
      add :labels, :map, null: false, default: %{}
      add :runtime, :text
      add :runtime_version, :text
      add :runner_version, :text
      add :contract_version, :integer
      add :command, :text
      add :args, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :dir, :text
      add :interactive, :boolean
      add :terminal_cols, :integer
      add :terminal_rows, :integer
      add :host, :text
      add :wall, :text
      add :image, :text

      add :state, :text, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :exited_at, :utc_datetime_usec
      add :exit_code, :integer
      add :signal, :text
      add :reason, :text
      add :duration_ms, :bigint
      add :cost_usd, :numeric

      add :last_event_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :elapsed_seconds, :integer
      add :heartbeat_interval_seconds, :integer

      add :policy_digest, :text
      add :run_configuration_digest, :text
      add :reported_run_configuration_digest, :text

      add :closed_at, :utc_datetime_usec
      add :closed_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :lost_at, :utc_datetime_usec

      add :event_count, :integer, null: false, default: 0
      add :denied_count, :integer, null: false, default: 0
      add :projected_sequence, :bigint, null: false, default: 0
      add :events_pruned_at, :utc_datetime_usec
      add :log_pruned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('succeeded', 'pending', 'running', 'failed', 'timed_out', 'lost', " <>
                 "'closed')"
           )

    create unique_index(:runs, [:workspace_id, :run_id])
    create unique_index(:runs, [:id, :workspace_id])

    create index(:runs, [:state, :last_heartbeat_at],
             where: "state IN ('pending', 'running')",
             name: :runs_alive_index
           )

    create index(:runs, [:workspace_id, :state])
    create index(:runs, [:workspace_id, :inserted_at])
    create index(:runs, [:workspace_id, :target_id])
    create index(:runs, [:access_key_id])
    create index(:runs, [:organisation_id, :workspace_id])
    create index(:runs, [:closed_by_id])

    create index(:runs, [:workspace_id, "COALESCE(started_at, inserted_at) DESC", "id DESC"],
             name: :runs_workspace_id_started_or_first_heard_index
           )

    create index(
             :runs,
             [:workspace_id, :access_key_id, "COALESCE(started_at, inserted_at) DESC", "id DESC"],
             name: :runs_workspace_id_access_key_id_started_index
           )

    create index(:runs, [:workspace_id, "COALESCE(last_event_at, inserted_at)", :id],
             where: "events_pruned_at IS NULL",
             name: :runs_retention_events_index
           )

    create index(:runs, [:workspace_id, "COALESCE(last_event_at, inserted_at)", :id],
             where: "log_pruned_at IS NULL",
             name: :runs_retention_log_index
           )
  end
end
