defmodule Apiary.Repo.Migrations.EndARunWhoseHarnessWalkFailed do
  use Ecto.Migration

  # The end cause `harness_unresolved` of a run of the queue and of its dispatch: the
  # run's harness walk failed before the run started (`Apiary.Harnesses.WalkJob`). Like
  # the causes a handover ends a run for, it comes with the outcome `error` on a run that
  # is not a prebuild. The run keeps the walk's failure code as `end_detail`, which a run
  # ended `run_refused` keeps too, and no other.
  #
  # Rolled back, the checks are as before. The roll back raises an error while a run of
  # the queue or a dispatch has this cause.
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
             run_refused build_failed)
  @handover_before ~w(variables_invalid ticket_gone inputs_invalid
                      provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
                      build_failed)
  @cause "harness_unresolved"

  def up do
    causes(@before ++ [@cause])
    outcomes(@handover_before ++ [@cause])
    end_detail(["run_refused", @cause])
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM dispatch_runs WHERE end_cause = 'harness_unresolved')
         OR EXISTS (SELECT 1 FROM dispatches WHERE end_cause = 'harness_unresolved') THEN
        RAISE EXCEPTION 'Delete the runs of the queue and dispatches ended harness_unresolved, then roll back again: the causes before this migration refuse it'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    end_detail(["run_refused"])
    outcomes(@handover_before)
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
  defp outcomes(handover) do
    list = Enum.map_join(handover, ", ", &"'#{&1}'")

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

  # The check of `end_detail`: a code, on a run ended for one of `causes` only.
  defp end_detail(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_end_detail_check)

    create constraint(:dispatch_runs, :dispatch_runs_end_detail_check,
             check:
               "end_detail IS NULL OR (COALESCE(end_cause IN (#{list}), false) " <>
                 "AND end_detail ~ '^[a-z][a-z0-9_]{0,63}$')"
           )
  end
end
