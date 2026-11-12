defmodule Apiary.Repo.Migrations.CreatePeopleLocks do
  use Ecto.Migration

  # The people lock of an organisation, one row per tenant (`ApiaryPro.Tenants.PeopleLock`):
  # a row of pro's own for the edition to lock, to keep a change of the organisation's
  # people and a write that relies on someone's level there one after the other without
  # locking a membership. It holds nothing but its key and when it was written.
  #
  # `organisation_id` is the key, and a foreign key to the tenant's, so the row goes with
  # its tenant. No other table references it, so no write elsewhere takes a lock on it
  # through a key.
  #
  # Every tenant gets its row, written in the transaction that writes the tenant from now
  # on; the tenants there are already get theirs here.
  #
  # It runs again harmlessly where it ran before under another version, as it did beside
  # the core's migration of the same version: the table is created only where it is
  # missing, and only the tenants without their row get one.
  #
  # Rolling back drops the table and its rows; the tenants stay as they are.
  def up do
    create_if_not_exists table(:people_locks, primary_key: false) do
      add :organisation_id,
          references(:tenants,
            column: :organisation_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          primary_key: true

      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute """
    INSERT INTO people_locks (organisation_id, inserted_at)
    SELECT organisation_id, now() FROM tenants
    ON CONFLICT (organisation_id) DO NOTHING
    """
  end

  def down do
    drop table(:people_locks)
  end
end
