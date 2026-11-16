defmodule Apiary.Repo.Migrations.KeepAMoveSStageAndAGateSPass do
  use Ecto.Migration

  # `gate_decisions` (`Apiary.Stages.GateDecision`): a nullable column `to_stage_id`, the
  # stage a move went to, and a kind `pass`, a gate `none` that passed on, with no
  # person. With both, the notes for a work item's next run (`Apiary.Stages.notes/1`)
  # leave out a move once the stage it went to passes its gate, and a stage's other notes
  # once a gate `none` passes there. A move written before has no `to_stage_id`, and a
  # gate `none` that passed before has no row.
  #
  # The column has no default, so adding it rewrites no row. Each check scans
  # `gate_decisions` under a lock that blocks reads and writes, one row per decision.
  # Rolling back deletes every `pass` row and drops `to_stage_id`.

  def up do
    alter table(:gate_decisions) do
      add :to_stage_id, :text
    end

    drop constraint(:gate_decisions, :gate_decisions_kind_check)

    create constraint(:gate_decisions, :gate_decisions_kind_check,
             check: "kind IN ('approve', 'request_changes', 'move', 'pass')"
           )

    create constraint(:gate_decisions, :gate_decisions_to_stage_check,
             check: "to_stage_id IS NULL OR kind = 'move'"
           )
  end

  def down do
    execute("DELETE FROM gate_decisions WHERE kind = 'pass'")
    drop constraint(:gate_decisions, :gate_decisions_to_stage_check)
    drop constraint(:gate_decisions, :gate_decisions_kind_check)

    create constraint(:gate_decisions, :gate_decisions_kind_check,
             check: "kind IN ('approve', 'request_changes', 'move')"
           )

    alter table(:gate_decisions) do
      remove :to_stage_id
    end
  end
end
