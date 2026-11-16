defmodule Apiary.Repo.Migrations.KeepTheEntriesAStagePassesOver do
  use Ecto.Migration

  # `stage_skips`: a workflow entry of a stage that the stage runner passed over, with no
  # run, because its condition `when: {input: T}` was not met (`Apiary.Stages.Skip`). It
  # has the take in, the entry's position (`stage_entry`, `loop_entry`, `round`), its
  # workflow, the input type of the condition, and `after_attempt`, the newest attempt of
  # the take in when the runner passed it over (0 for none), which places it among the
  # runs on the work item page. A skip follows its work item to another workspace, as the
  # stage's checks do.
  def up do
    create table(:stage_skips, primary_key: false) do
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

      add :take_in, :integer, null: false
      add :stage_entry, :integer, null: false
      add :loop_entry, :integer
      add :round, :integer, null: false
      add :workflow, :text, null: false
      add :input, :text, null: false
      add :after_attempt, :integer, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute("""
    ALTER TABLE stage_skips ADD CONSTRAINT stage_skips_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create index(:stage_skips, [:work_item_id, :take_in])
    create index(:stage_skips, [:organisation_id, :workspace_id])
    create index(:stage_skips, [:process_version_id])

    create constraint(:stage_skips, :stage_skips_position_check,
             check:
               "take_in >= 1 AND stage_entry >= 0 AND (loop_entry IS NULL OR loop_entry >= 0) " <>
                 "AND round >= 1 AND after_attempt >= 0"
           )
  end

  def down do
    drop table(:stage_skips)
  end
end
