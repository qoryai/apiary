defmodule Apiary.Repo.Migrations.KeepARunSTargetWrites do
  use Ecto.Migration

  # The writes a run sent to its targets, what the projector folds from its
  # `dev.qory.run.target_write` events (`Apiary.Runs.TargetWrite`), one row per event:
  #
  # - `sequence` and `at` are the event's;
  # - `system` and `path` are the place the write went to, as the event has them;
  # - `state` is `started`, `changed`, `refused` or `cut`;
  # - `request_id` is the proxy's id of the request, null when the event has none;
  # - `target_id` is the workspace's target with that system and path, null for none.
  #
  # A new table: no row of another table is written again.
  def change do
    create table(:run_target_writes, primary_key: false) do
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

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:target_id]}
          )

      add :sequence, :bigint, null: false
      add :at, :utc_datetime_usec, null: false
      add :system, :text, null: false
      add :path, :text, null: false
      add :state, :text, null: false
      add :request_id, :text
    end

    create unique_index(:run_target_writes, [:run_id, :sequence])
    create index(:run_target_writes, [:organisation_id, :workspace_id])
    create index(:run_target_writes, [:workspace_id, :target_id])

    create constraint(:run_target_writes, :run_target_writes_state_check,
             check: "state IN ('started', 'changed', 'refused', 'cut')"
           )
  end
end
