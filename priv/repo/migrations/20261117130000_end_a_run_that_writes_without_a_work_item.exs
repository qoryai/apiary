defmodule Apiary.Repo.Migrations.EndARunThatWritesWithoutAWorkItem do
  use Ecto.Migration

  # The end cause `write_without_work_item` of a run of the queue and of its dispatch: a
  # claimed run with write access and no work item, which has no branch to limit its push
  # credential to (`Apiary.Runs.RunCredentials`). Like the other causes of a handover that
  # cannot form a run, it comes with the outcome `error` (`result_outcome`) on a run that
  # is not a prebuild.
  #
  # The checks are added NOT VALID, so adding them takes no scan of the tables under their
  # locks; the next migration validates them. No stored row has the cause, so every row
  # passes. Rolled back, the checks are as before, and the rollback fails while a run of
  # the queue or a dispatch has the cause.
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
             run_refused build_failed harness_unresolved target_access_gone)
  @outcome_before ~w(variables_invalid ticket_gone inputs_invalid
                     provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
                     build_failed harness_unresolved target_access_gone)
  @cause "write_without_work_item"

  def up do
    causes(@before ++ [@cause])
    outcomes(@outcome_before ++ [@cause])
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM dispatch_runs WHERE end_cause = 'write_without_work_item')
         OR EXISTS (SELECT 1 FROM dispatches WHERE end_cause = 'write_without_work_item') THEN
        RAISE EXCEPTION 'Delete the runs of the queue and dispatches ended write_without_work_item, then roll back again: the causes before this migration refuse it'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    outcomes(@outcome_before)
    causes(@before)
  end

  defp causes(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    for table <- [:dispatch_runs, :dispatches] do
      drop constraint(table, :"#{table}_end_cause_check")

      create constraint(table, :"#{table}_end_cause_check",
               check: "end_cause IS NULL OR end_cause IN (#{list})",
               validate: false
             )
    end
  end

  # The checks of `result_outcome` that list the causes a run ends with the outcome `error`
  # for, before it started. The first allows the outcome `questions` on a run ended `lost`,
  # as `KeepTheQuestionsOfALostRun` made it.
  defp outcomes(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check)

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_check,
             check:
               "result_outcome IS NULL OR (" <>
                 "result_outcome IN ('proposal', 'questions', 'error', 'none', 'refused') " <>
                 "AND step <> 'prebuild' AND (COALESCE(end_cause IN ('run_ended', " <>
                 "#{list}), false) OR (end_cause = 'lost' AND result_outcome = 'questions')))",
             validate: false
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check,
             check:
               "step = 'prebuild' OR NOT COALESCE(end_cause IN (#{list}), false) " <>
                 "OR COALESCE(result_outcome = 'error', false)",
             validate: false
           )
  end
end
