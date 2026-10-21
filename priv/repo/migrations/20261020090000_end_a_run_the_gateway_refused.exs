defmodule Apiary.Repo.Migrations.EndARunTheGatewayRefused do
  use Ecto.Migration

  # The end cause `run_refused` of a run of the queue, and of its dispatch: the run's
  # gateway refused it before it started (`dev.qory.run.refused`), and the run is not
  # queued again. The run of the queue keeps the refusal's code as `end_detail`, a code of
  # at most 64 lower-case letters, digits and `_` that starts with a letter, and only a run
  # ended `run_refused` has one. A run ended `run_refused` has no `result_outcome`, so the
  # checks of `result_outcome` stay as they are
  # (`20261019080000_end_a_run_its_gateway_may_not_seal_for`).
  #
  # Rolled back, the column and its check go and the causes are as before. The roll back
  # refuses while a run of the queue or a dispatch has this cause.
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone secrets_not_allowed)
  @cause "run_refused"

  def up do
    causes(@before ++ [@cause])

    alter table(:dispatch_runs) do
      add :end_detail, :text
    end

    create constraint(:dispatch_runs, :dispatch_runs_end_detail_check,
             check:
               "end_detail IS NULL OR (COALESCE(end_cause = 'run_refused', false) " <>
                 "AND end_detail ~ '^[a-z][a-z0-9_]{0,63}$')"
           )
  end

  def down do
    causes(@before)
    drop constraint(:dispatch_runs, :dispatch_runs_end_detail_check)

    alter table(:dispatch_runs) do
      remove :end_detail
    end
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
end
