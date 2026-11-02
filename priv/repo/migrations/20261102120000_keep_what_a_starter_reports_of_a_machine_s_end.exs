defmodule Apiary.Repo.Migrations.KeepWhatAStarterReportsOfAMachineSEnd do
  use Ecto.Migration

  # What a node pool's starter last reported about the removal of the machine it created
  # for a dispatch (the provisioner contract's `machine-end.schema.json`,
  # `Apiary.Dispatches.MachineEnds`):
  #
  # - `dispatches.machine_end_state`: `deleting`, `gone` or `delete_failed`, nil until
  #   the first report;
  # - `dispatches.machine_end_at`: when Qory Apiary accepted that report, set with the
  #   state.
  #
  # Adding columns that may be empty, with no default, rewrites no row: every dispatch
  # has neither until its starter reports.
  def change do
    alter table(:dispatches) do
      add :machine_end_state, :text
      add :machine_end_at, :utc_datetime_usec
    end

    create constraint(:dispatches, :dispatches_machine_end_check,
             check:
               "(machine_end_state IS NULL AND machine_end_at IS NULL) OR " <>
                 "(machine_end_state IN ('deleting', 'gone', 'delete_failed') AND " <>
                 "machine_end_at IS NOT NULL)"
           )
  end
end
