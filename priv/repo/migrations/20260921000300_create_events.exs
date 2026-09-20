defmodule Apiary.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
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

      # With the hive, so a row cannot name a run of another hive.
      add :run_id,
          references(:runs,
            type: :binary_id,
            with: [hive_id: :hive_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :sequence, :bigint, null: false
      add :event_id, :uuid, null: false
      add :type, :text, null: false
      add :time, :utc_datetime_usec, null: false
      add :data, :map, null: false, default: %{}
      add :received_at, :utc_datetime_usec, null: false
      add :projected_at, :utc_datetime_usec
    end

    create unique_index(:events, [:run_id, :sequence])
    create unique_index(:events, [:hive_id, :event_id])
    create index(:events, [:organisation_id, :hive_id])
    # The projector ranks the events of one type in a run by sequence.
    create index(:events, [:run_id, :type, :sequence])

    create index(:events, [:run_id, :projected_at],
             where: "projected_at IS NULL",
             name: :events_unprojected_index
           )
  end
end
