defmodule Apiary.Repo.Migrations.KeepARunSAttachingInstance do
  use Ecto.Migration

  # `attach_instance_id`, the instance id of the gateway that attached a run, beside the
  # attach's stored answer: the one instance that may attach the run again and send its
  # batches, heartbeats and reloads (`Apiary.Runs.Attach`, `Apiary.Runs.Sender`). NULL for
  # every existing row, and nothing backfills it: a run attached with none takes the
  # instance id of the next attach, batch or heartbeat its gateway sends for it. A run that
  # has one is attached, and the id is 1 to 128 characters, as `runs.instance_id` is
  # (`runs_attach_instance_id_check`, added NOT VALID, so it scans no row under a lock that
  # blocks writes; the next migration validates it).
  def up do
    alter table(:runs) do
      add :attach_instance_id, :text
    end

    execute """
    ALTER TABLE runs ADD CONSTRAINT runs_attach_instance_id_check CHECK (
      attach_instance_id IS NULL OR
      (attached_at IS NOT NULL AND char_length(attach_instance_id) BETWEEN 1 AND 128)
    ) NOT VALID
    """
  end

  def down do
    drop constraint(:runs, :runs_attach_instance_id_check)

    alter table(:runs) do
      remove :attach_instance_id
    end
  end
end
