defmodule Apiary.Repo.Migrations.KeepAnEntryPassedOverForNoFeedback do
  use Ecto.Migration

  # A workflow entry can be passed over by a condition `{feedback: new}`
  # (`Apiary.Stages.Runner`). `stage_skips.reason` is `feedback` for the row of such a
  # condition, with `negated` true for an `unless` that was met, and no `input`, `track`
  # or `cause_entry`. The check now allows that reason; `cause_entry` stays set only for
  # `first_attempt_passed`.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the migration after this one validates it. No stored row breaks it: each row keeps
  # the meaning the check before this one gave it.
  def up do
    drop constraint(:stage_skips, :stage_skips_condition_check)

    create constraint(:stage_skips, :stage_skips_condition_check,
             check:
               "num_nonnulls(input, track, reason) = 1 " <>
                 "AND (reason IS NULL OR reason IN ('first_attempt_passed', 'feedback')) " <>
                 "AND (reason IS NOT DISTINCT FROM 'first_attempt_passed') = " <>
                 "(cause_entry IS NOT NULL)",
             validate: false
           )
  end

  # Rolled back, the rows of the condition `{feedback: new}` are deleted: the check before
  # this one has no reason for them.
  def down do
    drop constraint(:stage_skips, :stage_skips_condition_check)
    execute "DELETE FROM stage_skips WHERE reason = 'feedback'"

    create constraint(:stage_skips, :stage_skips_condition_check,
             check:
               "num_nonnulls(input, track, reason) = 1 " <>
                 "AND (reason IS NULL OR reason = 'first_attempt_passed') " <>
                 "AND (reason IS NULL) = (cause_entry IS NULL)",
             validate: false
           )
  end
end
