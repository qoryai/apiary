defmodule Apiary.Repo.Migrations.CreateAccessKeys do
  use Ecto.Migration

  def change do
    create table(:access_keys, primary_key: false) do
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

      add :key_id, :string, null: false
      add :label, :string, null: false
      add :secret_primary, :binary, null: false
      add :secret_secondary, :binary
      add :rotated_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :last_runner_version, :string
      add :last_contract_version, :integer
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_keys, [:key_id])

    create unique_index(:access_keys, [:organisation_id, :hive_id, :label],
             where: "revoked_at IS NULL",
             name: :access_keys_active_label_index
           )

    create index(:access_keys, [:organisation_id, :hive_id])
  end
end
