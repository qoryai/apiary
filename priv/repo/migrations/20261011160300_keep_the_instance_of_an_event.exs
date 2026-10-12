defmodule Apiary.Repo.Migrations.KeepTheInstanceOfAnEvent do
  use Ecto.Migration

  # `events.instance_id`, the instance id of the request that delivered the event, as
  # `deliveries.instance_id` keeps it: the fold counts a heartbeat of a run through a
  # gateway towards the run's liveness only when it came from the instance that attached
  # the run (`Apiary.Runs.Fold`), and a rebuild folds it the same. NULL for every existing
  # row, which counts as it did. 1 to 128 characters (`events_instance_id_check`, added
  # NOT VALID, so it scans no row under a lock that blocks writes; the next migration
  # validates it). A nullable column with no default: adding it rewrites no row.
  def up do
    alter table(:events) do
      add :instance_id, :text
    end

    execute """
    ALTER TABLE events ADD CONSTRAINT events_instance_id_check CHECK (
      instance_id IS NULL OR char_length(instance_id) BETWEEN 1 AND 128
    ) NOT VALID
    """
  end

  def down do
    drop constraint(:events, :events_instance_id_check)

    alter table(:events) do
      remove :instance_id
    end
  end
end
