defmodule Apiary.Repo.Migrations.EndARunWhoseSessionHasNoKey do
  use Ecto.Migration

  # An end cause of a run of the queue and of its dispatch, for a claimed run of a stage
  # whose workflows run as sessions of one run:
  #
  # - `session_key_missing`: a workflow's session would have no key in the run, as its
  #   provider has no model key, or its runtime uses another API of a provider that an
  #   earlier workflow uses, and one run keeps one API of each provider.
  #
  # Like the other causes of a handover that cannot form a run, it comes with the outcome
  # `error` (`result_outcome`) on a run that is not a prebuild.
  #
  # Each check is dropped and added again with the new cause, and the new check scans its
  # table as it is added. No stored row has the cause, so every row passes. Rolled back,
  # the checks are as before, and the rollback fails while a run of the queue or a
  # dispatch has the cause.

  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
             run_refused build_failed harness_unresolved target_access_gone
             write_without_work_item shared_access_differs
             model_choice_missing too_many_providers)
  @outcome_before ~w(variables_invalid ticket_gone inputs_invalid
                     provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
                     build_failed harness_unresolved target_access_gone
                     write_without_work_item shared_access_differs
                     model_choice_missing too_many_providers)
  @causes ~w(session_key_missing)

  def up do
    causes(@before ++ @causes)
    outcomes(@outcome_before ++ @causes)
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM dispatch_runs WHERE end_cause = 'session_key_missing')
         OR EXISTS (SELECT 1 FROM dispatches WHERE end_cause = 'session_key_missing') THEN
        RAISE EXCEPTION 'Delete the runs of the queue and dispatches ended session_key_missing, then roll back again: the causes before this migration do not include it.'
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
               check: "end_cause IS NULL OR end_cause IN (#{list})"
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
                 "#{list}), false) OR (end_cause = 'lost' AND result_outcome = 'questions')))"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check,
             check:
               "step = 'prebuild' OR NOT COALESCE(end_cause IN (#{list}), false) " <>
                 "OR COALESCE(result_outcome = 'error', false)"
           )
  end
end
