defmodule Apiary.Repo.Migrations.CreateDeliveries do
  use Ecto.Migration

  def change do
    create table(:deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :hive_id,
          references(:hives,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      # A key is revoked, never deleted, and what it delivered is not to vanish with
      # it: no action, which still lets a hive go with everything in it.
      add :access_key_id, references(:access_keys, type: :binary_id, on_delete: :nothing),
        null: false

      add :delivery_id, :uuid, null: false
      # The subject of the batch. Not a foreign key: a delivery for a closed run
      # is recorded too, and the record outlives the run.
      add :run_id, :uuid, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :event_count, :integer, null: false, default: 0
      add :inserted_count, :integer, null: false, default: 0
      add :status, :integer, null: false
    end

    create unique_index(:deliveries, [:access_key_id, :delivery_id])
    create index(:deliveries, [:organisation_id, :hive_id])
    create index(:deliveries, [:hive_id, :run_id])
  end
end
