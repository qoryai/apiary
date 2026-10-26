defmodule Apiary.Repo.Migrations.KeepOneLiveTestWorkItem do
  use Ecto.Migration

  # A workspace has at most one live test work item (`test` set, `state` `exploring`): a
  # take in of a test closes that one first once its runs have ended, and is refused while
  # one of them is in progress (`Apiary.WorkItems.take_in_test/2`). The partial unique
  # index holds it when two take ins of a test run at once. Ended test work items are not
  # counted.
  def change do
    create unique_index(:work_items, [:workspace_id],
             where: "test AND state = 'exploring'",
             name: :work_items_workspace_id_live_test_index
           )
  end
end
