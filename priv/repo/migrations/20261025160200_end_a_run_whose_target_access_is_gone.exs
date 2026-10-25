defmodule Apiary.Repo.Migrations.EndARunWhoseTargetAccessIsGone do
  use Ecto.Migration

  # The end cause `target_access_gone` of a run of the queue and of its dispatch: a
  # claimed run that Qory Apiary could not give access to its target, because the
  # integration that brings in the target no longer reaches it. Like the other causes of a
  # handover that cannot form a run, it comes with the outcome `error`
  # (`result_outcome`) on a run that is not a prebuild. No code ends a run for it yet.
  #
  # Rolled back, the checks are as before. The roll back raises an error while a run of
  # the queue or a dispatch has this cause.
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
             run_refused build_failed harness_unresolved)
  @outcome_before ~w(variables_invalid ticket_gone inputs_invalid
                     provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
                     build_failed harness_unresolved)
  @cause "target_access_gone"

  def up do
    causes(@before ++ [@cause])
    outcomes(@outcome_before ++ [@cause])
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM dispatch_runs WHERE end_cause = 'target_access_gone')
         OR EXISTS (SELECT 1 FROM dispatches WHERE end_cause = 'target_access_gone') THEN
        RAISE EXCEPTION 'Delete the runs of the queue and dispatches ended target_access_gone, then roll back again: the causes before this migration refuse it'
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

  # The checks of `result_outcome` that name the causes a run ends with the outcome
  # `error` for, before it started.
  defp outcomes(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check)

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_check,
             check:
               "result_outcome IS NULL OR (" <>
                 "result_outcome IN ('proposal', 'questions', 'error', 'none', 'refused') " <>
                 "AND step <> 'prebuild' AND COALESCE(end_cause IN ('run_ended', " <>
                 "#{list}), false))"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check,
             check:
               "step = 'prebuild' OR NOT COALESCE(end_cause IN (#{list}), false) " <>
                 "OR COALESCE(result_outcome = 'error', false)"
           )
  end
end
