defmodule Apiary.Repo.Migrations.KeepThePlanTypeOfARun do
  use Ecto.Migration

  # `run_harnesses.plan_type`: the artifact type of the run's plan, the `plan` of the
  # run's workflow in its stack file's `workflows`
  # (`Apiary.Harnesses.Reader.workflow_plan/2`). Null for a run whose stack file sets
  # none, sets an invalid value, or was not read, and for a walk made before the column.
  #
  # One nullable column with no default and no check: no row is written again.
  def change do
    alter table(:run_harnesses) do
      add :plan_type, :text
    end
  end
end
