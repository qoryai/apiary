defmodule Apiary.Repo.Migrations.CreateConnections do
  use Ecto.Migration

  def change do
    create table(:connections, primary_key: false) do
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

      add :host, :text, null: false
      add :port, :integer, null: false
      add :path, :text, null: false, default: ""
      add :method, :text
      add :attempts, :integer, null: false, default: 0
      add :allowed, :integer, null: false, default: 0
      add :denied, :integer, null: false, default: 0
      add :last_decision, :text
      add :last_rule, :text
      add :last_outcome, :text
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      # The sequence of the last event folded in: what "last" means, not the clock.
      add :last_sequence, :bigint, null: false, default: 0
    end

    create unique_index(:connections, [:run_id, :host, :port, :path])
    create index(:connections, [:organisation_id, :hive_id])
  end
end
