defmodule Apiary.Repo.Migrations.KeepTheStageARunReturnedTo do
  use Ecto.Migration

  # The return from a stage to an earlier one (`Apiary.Stages.Runner`, choice 10):
  #
  # - `dispatch_runs.returned_to`, the stage a run returned its work item to when the run
  #   of an entry with a return key asked for changes; nil for every other run. The stage
  #   runner counts an entry's returns by it.
  # - `escalations.cause` takes `return_limit`: the run after the most returns that the
  #   entry allows escalates instead.
  #
  # The column is new and may be empty, with no default, so no row is written again. Both
  # checks are added NOT VALID, so adding them takes no scan of the tables under their
  # locks; `20261116120100` validates them.
  @stage_id "^st_[0-9a-hjkmnp-tv-z]{10}$"
  @causes ~w(round_limit escalate check_failed run_stopped)

  def up do
    alter table(:dispatch_runs) do
      add :returned_to, :text
    end

    create constraint(:dispatch_runs, :dispatch_runs_returned_to_check,
             check: "returned_to IS NULL OR returned_to ~ '#{@stage_id}'",
             validate: false
           )

    drop constraint(:escalations, :escalations_cause_check)

    create constraint(:escalations, :escalations_cause_check,
             check: "cause IN (#{quoted(@causes ++ ["return_limit"])})",
             validate: false
           )
  end

  # Rolled back, an escalation at the return limit becomes an escalation of its run's
  # verdict, `escalate`, with its points, and the runs forget their returns.
  def down do
    drop constraint(:escalations, :escalations_cause_check)
    execute "UPDATE escalations SET cause = 'escalate' WHERE cause = 'return_limit'"

    create constraint(:escalations, :escalations_cause_check,
             check: "cause IN (#{quoted(@causes)})"
           )

    drop constraint(:dispatch_runs, :dispatch_runs_returned_to_check)

    alter table(:dispatch_runs) do
      remove :returned_to
    end
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
