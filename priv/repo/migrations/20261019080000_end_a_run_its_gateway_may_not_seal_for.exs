defmodule Apiary.Repo.Migrations.EndARunItsGatewayMayNotSealFor do
  use Ecto.Migration

  # One end cause joins the causes of a run of the queue and of its dispatch:
  # `secrets_not_allowed`, an explore run whose model choice has a provider, handed over
  # to a gateway one of whose active keys was made without the stored-secrets flag
  # (`access_keys.allow_secrets`), so the run never gets its model key
  # (`Apiary.Dispatches.Handover`). Like the other causes of a handover that cannot form
  # a run, it comes with the outcome `error` (`result_outcome`) on a run that is not a
  # prebuild.
  #
  # Rolled back, the causes are as before; the roll back refuses while a run of the queue
  # or a dispatch has the cause.
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone)
  @handover_before ~w(variables_invalid ticket_gone inputs_invalid
                      provider_gone runtime_unserved key_gone model_gone)
  @cause "secrets_not_allowed"

  def up do
    causes(@before ++ [@cause])
    outcomes(@handover_before ++ [@cause])
  end

  def down do
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

  # The checks of `result_outcome` that name the causes a handover ends a run for.
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
end
