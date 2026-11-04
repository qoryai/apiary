defmodule Apiary.Repo.Migrations.IndexTheWorkItemsTheStageSweepReads do
  use Ecto.Migration

  # The stage sweep (`Apiary.Stages.sweep/3`) runs at each tick of the lost-run check and
  # reads the work items that are exploring with their stage running. Without an index for
  # that filter, each tick reads every row of `work_items`; this partial index has those
  # work items alone.
  def change do
    create index(:work_items, [:id],
             where: "state = 'exploring' AND stage_state = 'running'",
             name: :work_items_exploring_running_index
           )
  end
end
