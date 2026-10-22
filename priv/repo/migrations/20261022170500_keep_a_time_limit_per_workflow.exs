defmodule Apiary.Repo.Migrations.KeepATimeLimitPerWorkflow do
  use Ecto.Migration

  # A time limit for the runs of one workflow (`Apiary.TimeLimits.TimeLimit`): the whole
  # minutes, 15 to 1440, a run of that workflow may take. A row is at one of two places,
  # by the columns it has set: the workspace (`workspace_id`), or a target of it
  # (`workspace_id` and `target_id`). `workflow` is the workflow's name in the machines
  # file (`Apiary.Dispatches.MachinesFile`). One row per place and workflow: the unique
  # index reads a missing target as the nil UUID. A target or a workspace takes its rows
  # with it.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def change do
    create table(:time_limits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :simple,
            on_delete: :delete_all
          ),
          null: false

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :simple,
            on_delete: :delete_all
          )

      add :workflow, :text, null: false
      add :minutes, :integer, null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:time_limits, :time_limits_workflow_format,
             check: "workflow ~ '^[a-z][a-z0-9-]{0,63}$'"
           )

    create constraint(:time_limits, :time_limits_minutes_range,
             check: "minutes BETWEEN 15 AND 1440"
           )

    create unique_index(
             :time_limits,
             [:workspace_id, "COALESCE(target_id, #{@nobody})", :workflow],
             name: :time_limits_place_index
           )

    create index(:time_limits, [:organisation_id])
    create index(:time_limits, [:target_id])
    create index(:time_limits, [:created_by_id])
    create index(:time_limits, [:updated_by_id])
  end
end
