defmodule Apiary.Repo.Migrations.CreateHives do
  use Ecto.Migration

  def change do
    create table(:hives, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The target of the composite foreign key (organisation_id, hive_id) on every
    # hive-owned table: no row can name a hive of another organisation.
    create unique_index(:hives, [:organisation_id, :id])
    create unique_index(:hives, [:organisation_id, :name])
  end
end
