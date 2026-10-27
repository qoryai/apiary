defmodule Apiary.Repo.Migrations.KeepTheAdapterAHarnessWalkCouldNotReach do
  use Ecto.Migration

  # The adapter a run's harness walk could not reach or got a failed call from
  # (`Apiary.Harnesses.RunHarness`), by its node: `failure_adapter_id` on `run_harnesses`,
  # beside `failure_adapter`, its name then. A page shows the adapter's title from the
  # node, and that name where the column is NULL: on every row there already, and once
  # the node's row is gone, which sets it to NULL. The index serves that delete.
  #
  # Adding a nullable column with no default rewrites no row.
  def change do
    alter table(:run_harnesses) do
      add :failure_adapter_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:run_harnesses, [:failure_adapter_id], where: "failure_adapter_id IS NOT NULL")
  end
end
