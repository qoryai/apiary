defmodule Apiary.Repo.Migrations.KeepWhereAMoveWentAndWhatItLeft do
  use Ecto.Migration

  # A move of the work item out of a stage (`gate_decisions.kind` `move`) keeps the stage it
  # moved to (`to_stage_id`) and when the work item had last entered the stage it left
  # (`left_stage_entered_at`, the work item's `stage_entered_at` before the move overwrites
  # it). `Apiary.Stages.inputs/1` lists the outputs the stage made in between to the stage
  # moved to, until the left stage's gate passes or a later move goes past it. A move that
  # resolves an escalation keeps the escalation (`escalation_id`), so the notes of the work
  # item list the escalation and not a second entry for the move. A decision is deleted
  # before the escalation it names (`Apiary.Deletion.Tables`). Nullable columns with no
  # default rewrite no row; a move written before has neither. The index of `escalation_id`
  # is in the migration after this one.
  def up do
    alter table(:gate_decisions) do
      add :to_stage_id, :text
      add :left_stage_entered_at, :utc_datetime_usec
      add :escalation_id, references(:escalations, type: :binary_id, on_delete: :nothing)
    end
  end

  def down do
    alter table(:gate_decisions) do
      remove :to_stage_id
      remove :left_stage_entered_at
      remove :escalation_id
    end
  end
end
