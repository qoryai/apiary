defmodule Apiary.Repo.Migrations.KeepWhetherARunWasOnTheDefaultType do
  use Ecto.Migration

  # `dispatch_runs.machine_type_was_default`: true for a run queued on the type that was
  # the instance's default type then, so that a pool without offers, which starts its
  # default machine, takes the run after another type becomes the default. False for any
  # other run, and for a run queued before this column; a run queued before machine types
  # has no spec, and such a pool takes it in any case.
  #
  # A column with a constant default rewrites no row.
  def change do
    alter table(:dispatch_runs) do
      add :machine_type_was_default, :boolean, null: false, default: false
    end
  end
end
