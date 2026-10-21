defmodule Apiary.Repo.Migrations.EndAPrebuildByItsPrebuilt do
  use Ecto.Migration

  # The end cause `prebuilt` of a run of the queue, and of its dispatch: a prebuild whose
  # starter reported the image it built (`Apiary.Dispatches.Prebuilt`). The run of the
  # queue and its dispatch end, and the slot is freed; the registered run is left to its
  # starter's outcome, which decides its state as any outcome does.
  #
  # Rolled back, the causes are as before, and the roll back refuses while a run of the
  # queue or a dispatch has this one.
  @end_causes ~w(released closed undone run_ended lost collection_ended superseded
                 variables_invalid ticket_gone inputs_invalid)
  @prebuilt_causes @end_causes ++ ~w(prebuilt)

  def up, do: causes(@prebuilt_causes)
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
