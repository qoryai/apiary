defmodule Apiary.Repo.Migrations.KeepWhereAMoveBackLeft do
  use Ecto.Migration

  # `stage_departures`: a person's entry of the work item into an earlier stage than the one
  # it was in (a move back, an escalation's move back, or any later resolution that enters an
  # earlier stage), recorded by `Apiary.Stages` before `work_items.stage_entered_at` is set
  # to the entry into the earlier stage. It has the stage that the work item left
  # (`stage_id`), the take in, when the work item had last entered that stage
  # (`entered_at`; nil for a work item placed before `work_items.stage_entered_at`), and when
  # it left (`inserted_at`). `Apiary.Stages.inputs/1` lists the newest versions that the
  # stage's outputs have from `entered_at` to `inserted_at`. A departure follows its work
  # item to another workspace, as the stage's checks do.
  def up do
    create table(:stage_departures, primary_key: false) do
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
      add :take_in, :integer, null: false
      add :entered_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute("""
    ALTER TABLE stage_departures ADD CONSTRAINT stage_departures_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create index(:stage_departures, [:work_item_id, :take_in])
    create index(:stage_departures, [:organisation_id, :workspace_id])

    create constraint(:stage_departures, :stage_departures_take_in_check, check: "take_in >= 1")
  end

  def down do
    drop table(:stage_departures)
  end
end
