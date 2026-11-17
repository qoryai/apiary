defmodule Apiary.Repo.Migrations.KeepWhyAnEntryWasPassedOver do
  use Ecto.Migration

  # An entry of a stage's sequence can be passed over because the first attempt before it
  # passed (`Apiary.Stages.Runner`), with no condition that held it back. `stage_skips.reason`
  # is `first_attempt_passed` for such a row, null for a row of a condition, and
  # `cause_entry` is the name of the first attempt's entry, else its workflow. A row has one
  # of `input`, `track` and `reason`, and a reason has its cause.
  #
  # Each new column is nullable, so adding it rewrites no row. The check is added NOT VALID,
  # so adding it takes no scan of the table under its lock; the migration after this one
  # validates it. No stored row breaks it: each has an input or a track and no reason.
  def up do
    alter table(:stage_skips) do
      add :reason, :text
      add :cause_entry, :text
    end

    drop constraint(:stage_skips, :stage_skips_condition_check)

    create constraint(:stage_skips, :stage_skips_condition_check,
             check:
               "num_nonnulls(input, track, reason) = 1 " <>
                 "AND (reason IS NULL OR reason = 'first_attempt_passed') " <>
                 "AND (reason IS NULL) = (cause_entry IS NULL)",
             validate: false
           )
  end

  # Rolled back, the rows of a first attempt are deleted: they have no input or track.
  def down do
    drop constraint(:stage_skips, :stage_skips_condition_check)
    execute "DELETE FROM stage_skips WHERE reason IS NOT NULL"

    create constraint(:stage_skips, :stage_skips_condition_check,
             check: "num_nonnulls(input, track) = 1",
             validate: false
           )

    alter table(:stage_skips) do
      remove :cause_entry
      remove :reason
    end
  end
end
