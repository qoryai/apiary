defmodule Apiary.Repo.Migrations.KeepWhatARunOfTheQueueGave do
  use Ecto.Migration

  # What a run of the queue gave (`Apiary.Dispatches.DispatchRun`), kept on its row once
  # Qory reads it as decided (`Apiary.Dispatches.Settle`), so a list can read and count
  # where Explore stands without reading the runs' events:
  #
  # - `result_outcome`: `proposal`, `questions`, `error`, `none` or `refused`, as
  #   `Apiary.Explore.Result` reads the run's result. Only a run that is not a prebuild has
  #   one, and only once it ended `run_ended`, or ended before its handover because the
  #   handover could not form what the run is made from (`variables_invalid`,
  #   `ticket_gone`, `inputs_invalid`), which is always `error`. NULL otherwise, and while
  #   the run is not decided.
  # - `result`: the run's result, a JSON object, 1 MiB at most as the database encodes it,
  #   kept for a `proposal` or `questions` only, so the page reads it after the run's
  #   events are pruned. Retention may clear it once its take in no longer waits for a
  #   member, and the outcome stays.
  #
  # Up sets `error` on the runs that ended for one of those three causes and are not
  # prebuilds, as the checks require; every other run is read again by the sweep of
  # `Apiary.Runs.Liveness`, through the partial index on the runs ended `run_ended` with
  # no outcome yet.
  #
  # Rolled back, the two columns, their checks and the index go.

  @handover_causes "('variables_invalid', 'ticket_gone', 'inputs_invalid')"

  def up do
    alter table(:dispatch_runs) do
      add :result_outcome, :text
      add :result, :jsonb
    end

    execute """
    UPDATE dispatch_runs SET result_outcome = 'error'
    WHERE step <> 'prebuild' AND end_cause IN #{@handover_causes}
    """

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_check,
             check:
               "result_outcome IS NULL OR (" <>
                 "result_outcome IN ('proposal', 'questions', 'error', 'none', 'refused') " <>
                 "AND step <> 'prebuild' AND COALESCE(end_cause IN ('run_ended', " <>
                 "'variables_invalid', 'ticket_gone', 'inputs_invalid'), false))"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check,
             check:
               "step = 'prebuild' OR NOT COALESCE(end_cause IN #{@handover_causes}, false) " <>
                 "OR COALESCE(result_outcome = 'error', false)"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_check,
             check:
               "result IS NULL OR (jsonb_typeof(result) = 'object' " <>
                 "AND octet_length(result::text) <= 1048576)"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_kept_check,
             check:
               "result IS NULL OR COALESCE(result_outcome IN ('proposal', 'questions'), false)"
           )

    create index(:dispatch_runs, [:id],
             name: :dispatch_runs_unsettled_index,
             where: "end_cause = 'run_ended' AND result_outcome IS NULL AND step <> 'prebuild'"
           )
  end

  def down do
    drop index(:dispatch_runs, [:id], name: :dispatch_runs_unsettled_index)
    drop constraint(:dispatch_runs, :dispatch_runs_result_kept_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_check)

    alter table(:dispatch_runs) do
      remove :result
      remove :result_outcome
    end
  end
end
