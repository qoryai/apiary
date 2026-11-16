defmodule Apiary.Repo.Migrations.KeepAStageThatATrackPassesOver do
  use Ecto.Migration

  # A stage passed over whole (`Apiary.Stages.Runner`: a condition on the stage holds it
  # back) is a row of `stage_skips` with no workflow: `workflow`, `stage_entry` and
  # `loop_entry` are null, `round` is 1, and `input`, `track` and `negated` say which
  # condition held the stage back. The check keeps the three together: a row has a workflow
  # and an entry, or neither, and a stage's row has no loop entry.
  #
  # Dropping a NOT NULL takes no scan. The check is added NOT VALID, so adding it takes no
  # scan of the table under its lock; `20261116120300` validates it. Every stored row has a
  # workflow and an entry.
  def up do
    alter table(:stage_skips) do
      modify :workflow, :text, null: true, from: {:text, null: false}
      modify :stage_entry, :integer, null: true, from: {:integer, null: false}
    end

    create constraint(:stage_skips, :stage_skips_stage_check,
             check:
               "(workflow IS NULL) = (stage_entry IS NULL) " <>
                 "AND (workflow IS NOT NULL OR loop_entry IS NULL)",
             validate: false
           )
  end

  # Rolled back, the rows of a stage passed over are deleted: they have no workflow, which
  # the column needs again.
  def down do
    drop constraint(:stage_skips, :stage_skips_stage_check)
    execute "DELETE FROM stage_skips WHERE workflow IS NULL"

    alter table(:stage_skips) do
      modify :stage_entry, :integer, null: false, from: {:integer, null: true}
      modify :workflow, :text, null: false, from: {:text, null: true}
    end
  end
end
