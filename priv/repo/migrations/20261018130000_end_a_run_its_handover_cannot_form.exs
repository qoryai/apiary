defmodule Apiary.Repo.Migrations.EndARunItsHandoverCannotForm do
  use Ecto.Migration

  # The end causes of a run of the queue, and of its dispatch, that its handover cannot
  # form (`Apiary.Dispatches.Handover`): the handover ends the run and its dispatch in its
  # transaction, and answers `410 gone`, so the starter stops the job it started.
  #
  # - `variables_invalid`: the run variables of the run's target break their rules
  #   (`Apiary.Runs.RunVariables`).
  # - `ticket_gone`: the ticket the run's work item was taken in from is no longer kept.
  # - `inputs_invalid`: the step's input breaks the contract's rules for it, such as a
  #   first instruction that holds a character the contract refuses.
  #
  # Rolled back, the causes are as before, and the roll back refuses while a run of the
  # queue or a dispatch has one of these.
  @end_causes ~w(released closed undone run_ended lost collection_ended superseded)
  @handover_causes @end_causes ++ ~w(variables_invalid ticket_gone inputs_invalid)

  def up, do: causes(@handover_causes)
  def down, do: causes(@end_causes)

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
