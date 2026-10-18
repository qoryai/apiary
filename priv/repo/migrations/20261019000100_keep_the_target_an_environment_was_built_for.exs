defmodule Apiary.Repo.Migrations.KeepTheTargetAnEnvironmentWasBuiltFor do
  use Ecto.Migration

  # The target of an environment record (`Apiary.Environments.Record`), twice:
  #
  # - `queued_target_system` and `queued_target_path`: the collection's target the last
  #   prebuild for the pool was queued for, which the trigger compares with the
  #   collection's current target beside `queued_ref`, so a target that changes queues a
  #   prebuild as a changed `environment_ref` does;
  # - `built_target_system` and `built_target_path`: the target the last good build was
  #   built for, the registered run's target when its `prebuilt` was recorded, which a run
  #   is given the image for alone.
  #
  # Each pair is both or neither. Up fills the queued target of every record from its
  # collection's current target, where the collection has one, so a record queued before
  # this migration is not queued again for a target it was already queued for; no record
  # has a built target, as nothing recorded a build before. Down drops the four columns.

  def up do
    alter table(:environments) do
      add :queued_target_system, :text
      add :queued_target_path, :text
      add :built_target_system, :text
      add :built_target_path, :text
    end

    execute """
    UPDATE environments AS e
    SET queued_target_system = c.target_system, queued_target_path = c.target_path
    FROM source_collections AS c
    WHERE c.id = e.source_collection_id
      AND c.target_system IS NOT NULL AND c.target_path IS NOT NULL
    """

    create constraint(:environments, :environments_queued_target_check,
             check: "(queued_target_system IS NULL) = (queued_target_path IS NULL)"
           )

    create constraint(:environments, :environments_built_target_check,
             check: "(built_target_system IS NULL) = (built_target_path IS NULL)"
           )
  end

  def down do
    drop constraint(:environments, :environments_built_target_check)
    drop constraint(:environments, :environments_queued_target_check)

    alter table(:environments) do
      remove :built_target_path
      remove :built_target_system
      remove :queued_target_path
      remove :queued_target_system
    end
  end
end
