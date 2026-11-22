defmodule Apiary.Repo.Migrations.KeepTheLevelOfEachWorkflowOfARunHarness do
  use Ecto.Migration

  # `run_harnesses.workflow_levels`: the access level that the stack file the walk read
  # declares for each workflow of its `workflows`, by name, as `read`, `write-no-push` or
  # `write` (`Apiary.Harnesses.Reader.workflow_access/2`). A run of a stage whose
  # workflows share one run takes the level of its other workflows from it. Null for a
  # walk made before the column, which counts each other workflow as `read`.
  #
  # One nullable column with no default and no check: no row is written again.
  def change do
    alter table(:run_harnesses) do
      add :workflow_levels, :map
    end
  end
end
