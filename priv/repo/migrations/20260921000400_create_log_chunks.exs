defmodule Apiary.Repo.Migrations.CreateLogChunks do
  use Ecto.Migration

  def change do
    create table(:log_chunks, primary_key: false) do
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
      add :stream, :text, null: false
      add :bytes, :binary, null: false
    end

    create unique_index(:log_chunks, [:run_id, :sequence])
    create index(:log_chunks, [:organisation_id, :hive_id])
  end
end
