defmodule Apiary.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories, primary_key: false) do
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

      add :forge, :text, null: false
      add :path, :text, null: false
      add :first_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repositories, [:hive_id, :forge, :path])
    # What a run references, so the database holds a run to a repository of its hive.
    create unique_index(:repositories, [:id, :hive_id])
    create index(:repositories, [:organisation_id, :hive_id])
  end
end
