defmodule Apiary.Repo.Migrations.KeepTheMachineTypeOfARun do
  use Ecto.Migration

  # `dispatch_runs.machine_spec`: the spec of the machine type in `machine_type`, as the
  # run was queued, so that a later change of the type changes no queued run. Null for a
  # run queued before machine types, which a claim reads as the default type.
  #
  # Adding a column that may be empty, with no default, rewrites no row.
  #
  # This migration and the next two change one table each. A claim locks `nodes` before
  # `dispatch_runs`, and the end of a deleted pool's prebuild locks `dispatch_runs` before
  # it reads `nodes` (`end_deleted/2` in lib/apiary/dispatches.ex), so one transaction that
  # changes both tables could deadlock with one of them on a live instance.
  def change do
    alter table(:dispatch_runs) do
      add :machine_spec, :jsonb
    end
  end
end
