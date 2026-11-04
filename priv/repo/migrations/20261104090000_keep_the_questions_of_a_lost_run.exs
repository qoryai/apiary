defmodule Apiary.Repo.Migrations.KeepTheQuestionsOfALostRun do
  use Ecto.Migration

  # A run of Explore pushes its questions during the run, so a run that is lost may leave
  # questions that wait for an answer. Its run of the queue then keeps the outcome
  # `questions` (`result_outcome`, `Apiary.Dispatches.Settle`), and the work item waits
  # for answers. The check of `result_outcome` allows that outcome, and no other, on a run
  # ended `lost`.
  #
  # Rolled back, the check is as before. The roll back raises an error while a run of the
  # queue ended `lost` has an outcome.
  @outcome_causes ~w(variables_invalid ticket_gone inputs_invalid
                     provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
                     build_failed harness_unresolved target_access_gone)

  def up, do: check("OR (end_cause = 'lost' AND result_outcome = 'questions')")

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM dispatch_runs
                 WHERE end_cause = 'lost' AND result_outcome IS NOT NULL) THEN
        RAISE EXCEPTION 'Set result_outcome to NULL on the runs of the queue ended lost, then roll back again: the check before this migration refuses an outcome on them'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    check("")
  end

  defp check(lost) do
    list = Enum.map_join(@outcome_causes, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_check)

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_check,
             check:
               "result_outcome IS NULL OR (" <>
                 "result_outcome IN ('proposal', 'questions', 'error', 'none', 'refused') " <>
                 "AND step <> 'prebuild' AND (COALESCE(end_cause IN ('run_ended', " <>
                 "#{list}), false) #{lost}))"
           )
  end
end
