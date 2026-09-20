defmodule Apiary.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations, primary_key: false) do
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

      add :email, :citext, null: false
      add :level, :string, null: false
      add :token_hash, :binary, null: false
      add :invited_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invitations, [:token_hash])

    create unique_index(:invitations, [:organisation_id, :email],
             where: "accepted_at IS NULL",
             name: :invitations_pending_email_index
           )

    create index(:invitations, [:organisation_id, :hive_id])
  end
end
