defmodule Apiary.Repo.Migrations.KeepWhereAMoveWentAndWhatItLeft do
  use Ecto.Migration

  # A move of the work item out of a stage (`gate_decisions.kind` `move`) keeps the stage it
  # moved to (`to_stage_id`) and when the work item had last entered the stage it left
  # (`left_stage_entered_at`, the work item's `stage_entered_at` before the move overwrites
  # it). `Apiary.Stages.inputs/1` lists the outputs the stage made in between to the stage
  # moved to, until the left stage's gate passes or a later move goes past it. Nullable
  # columns with no default rewrite no row; a move written before has neither.
  def up do
    alter table(:gate_decisions) do
      add :to_stage_id, :text
      add :left_stage_entered_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:gate_decisions) do
      remove :to_stage_id
      remove :left_stage_entered_at
    end
  end
end
