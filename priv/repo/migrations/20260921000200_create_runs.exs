defmodule Apiary.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
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

      add :run_id, :uuid, null: false

      add :access_key_id, references(:access_keys, type: :binary_id, on_delete: :nilify_all)
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :nilify_all)

      add :forge, :text
      add :repository, :text
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

      add :last_event_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :elapsed_seconds, :integer
      add :heartbeat_interval_seconds, :integer

      add :policy_digest, :text
      add :run_configuration_digest, :text
      add :reported_run_configuration_digest, :text

      add :closed_at, :utc_datetime_usec
      add :closed_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :lost_at, :utc_datetime_usec

      add :event_count, :integer, null: false, default: 0
      add :projected_sequence, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('pending', 'running', 'exited', 'failed', 'timed_out', 'lost', 'closed')"
           )

    create unique_index(:runs, [:hive_id, :run_id])
    create index(:runs, [:hive_id, :state])
    create index(:runs, [:hive_id, :inserted_at])
    create index(:runs, [:hive_id, :repository_id])
    create index(:runs, [:access_key_id])
    create index(:runs, [:organisation_id, :hive_id])
    create index(:runs, [:closed_by_id])
  end
end
