defmodule Apiary.Repo.Migrations.KeepTheStageAMoveEnters do
  use Ecto.Migration

  # `gate_decisions.to_stage_id` (`Apiary.Stages.GateDecision`): the stage a move went
  # to, nil for every other decision. The notes for a work item's next run
  # (`Apiary.Stages.notes/1`) leave out a move once that stage is approved after it. A
  # move written before has no `to_stage_id` and stays open.
  #
  # The column has no default, so adding it rewrites no row. The check is added NOT
  # VALID, so adding it takes no scan of the table under its lock; `20261116140100`
  # validates it. It changes no row.
  def up do
    alter table(:gate_decisions) do
      add :to_stage_id, :text
    end

    create constraint(:gate_decisions, :gate_decisions_to_stage_check,
             check: "to_stage_id IS NULL OR kind = 'move'",
             validate: false
           )
  end

  def down do
    drop constraint(:gate_decisions, :gate_decisions_to_stage_check)

    alter table(:gate_decisions) do
      remove :to_stage_id
    end
  end
end
