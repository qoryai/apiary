defmodule Apiary.Repo.Migrations.CreateMemberships do
  use Ecto.Migration

  def change do
    create table(:memberships, primary_key: false) do
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

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :level, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:organisation_id, :user_id])
    create index(:memberships, [:organisation_id, :hive_id])
    create index(:memberships, [:user_id])
  end
end
