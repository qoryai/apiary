defmodule Apiary.Repo.Migrations.KeepWhenAWorkItemEnteredItsStage do
  use Ecto.Migration

  # `work_items.stage_entered_at` is when the stage runner last entered the work item into
  # its stage (`Apiary.Stages`): by a gate, a person's move, a move back, or a take in. The
  # track that the runs of the stage propose is read only from the runs since then, so a run
  # of an earlier visit to the stage proposes nothing.
  #
  # A nullable column with no default rewrites no row. A work item placed before has none;
  # the runs of its take in count then.
  def up do
    alter table(:work_items) do
      add :stage_entered_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:work_items) do
      remove :stage_entered_at
    end
  end
end
