defmodule Apiary.Repo.Migrations.KeepWhenTheRecordedBuildWasQueued do
  use Ecto.Migration

  # `built_queued_at` on an environment record (`Apiary.Environments.Record`): when the
  # prebuild that made the recorded image was queued, its run of the queue's `queued_at`,
  # written with the image when its `prebuilt` is recorded. A `prebuilt`, or a failure, of
  # a prebuild queued before it then leaves the record as it is (V-804). It is set only
  # where an image is; a record with an image and none, of which nothing wrote one before,
  # is written as a record with no image is. Down drops the column.

  def up do
    alter table(:environments) do
      add :built_queued_at, :utc_datetime_usec
    end

    create constraint(:environments, :environments_built_queued_at_check,
             check: "built_queued_at IS NULL OR image IS NOT NULL"
           )
  end

  def down do
    drop constraint(:environments, :environments_built_queued_at_check)

    alter table(:environments) do
      remove :built_queued_at
    end
  end
end
