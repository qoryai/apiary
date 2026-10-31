defmodule Apiary.Repo.Migrations.KeepGateDecisionsAndEscalations do
  use Ecto.Migration

  # What people decide at a stage of a work item's process (`Apiary.Stages`).
  #
  # `gate_decisions`: a person's approval of a stage's gate, or their request for
  # changes, with the stage and the process version it was made under. `versions` is the
  # list of the public ids of the artifact versions an approval covers (`av_…`);
  # `artifact_version_id` the public id of the version a request for changes points at,
  # nil for none; `note` what the person wrote.
  #
  # `escalations`: a stage that waits for a person, with its round, its cause
  # (`round_limit`, `escalate`, `check_failed` or `run_stopped`), its gaps and the run it
  # came from. Once a person acts on it, `resolution` is what they chose (`accept`,
  # `another_round`, `move_back`, `close` or `decline`), with who, when and their note.
  # At most one escalation of a work item is open.
  #
  # Both follow their work item to another workspace, as its answers and confirmations do.
  @causes ~w(round_limit escalate check_failed run_stopped)
  @resolutions ~w(accept another_round move_back close decline)

  def up do
    create table(:gate_decisions, primary_key: false) do
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

      add :work_item_id, :binary_id, null: false
      add :stage_id, :text, null: false

      add :process_version_id,
          references(:process_versions, type: :binary_id, on_delete: :nothing),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :kind, :text, null: false
      add :versions, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :artifact_version_id, :text
      add :note, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    work_item_key(:gate_decisions)
    create index(:gate_decisions, [:work_item_id, :stage_id])
    create index(:gate_decisions, [:organisation_id, :workspace_id])
    create index(:gate_decisions, [:process_version_id])
    create index(:gate_decisions, [:user_id])

    create constraint(:gate_decisions, :gate_decisions_kind_check,
             check: "kind IN ('approve', 'request_changes')"
           )

    create constraint(:gate_decisions, :gate_decisions_versions_check,
             check: "jsonb_typeof(versions) = 'array'"
           )

    create constraint(:gate_decisions, :gate_decisions_note_check,
             check: "note IS NULL OR char_length(note) BETWEEN 1 AND 4000"
           )

    create table(:escalations, primary_key: false) do
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

      add :work_item_id, :binary_id, null: false
      add :stage_id, :text, null: false

      add :process_version_id,
          references(:process_versions, type: :binary_id, on_delete: :nothing),
          null: false

      add :round, :integer, null: false
      add :cause, :text, null: false
      add :gaps, :text
      add :run_id, references(:dispatch_runs, type: :binary_id, on_delete: :nilify_all)
      add :resolved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :resolution, :text
      add :note, :text
      add :resolved_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    work_item_key(:escalations)
    create index(:escalations, [:work_item_id, :stage_id])
    create index(:escalations, [:organisation_id, :workspace_id])
    create index(:escalations, [:process_version_id])
    create index(:escalations, [:run_id])
    create index(:escalations, [:resolved_by_id])

    create unique_index(:escalations, [:work_item_id],
             where: "resolved_at IS NULL",
             name: :escalations_one_open_index
           )

    create constraint(:escalations, :escalations_cause_check,
             check: "cause IN (#{quoted(@causes)})"
           )

    create constraint(:escalations, :escalations_resolution_check,
             check:
               "(resolved_at IS NULL AND resolution IS NULL) OR " <>
                 "(resolved_at IS NOT NULL AND resolution IN (#{quoted(@resolutions)}))"
           )

    create constraint(:escalations, :escalations_round_check, check: "round >= 0")

    create constraint(:escalations, :escalations_note_check,
             check: "note IS NULL OR char_length(note) BETWEEN 1 AND 4000"
           )
  end

  def down do
    drop table(:escalations)
    drop table(:gate_decisions)
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp work_item_key(table) do
    execute("""
    ALTER TABLE #{table} ADD CONSTRAINT #{table}_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)
  end
end
