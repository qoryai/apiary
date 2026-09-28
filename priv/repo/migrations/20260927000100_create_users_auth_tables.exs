defmodule Apiary.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  # The accounts and their tokens. An account is never deleted: deleting one erases its
  # personal data and keeps the row, a tombstone, so every row that names the person by id
  # keeps naming something (`Apiary.Accounts.delete_user/2`). `deleted_at` says when, and
  # the email address of a deleted account is NULL, which the unique index on `email`
  # allows any number of times, since Postgres counts NULLs as distinct: the address is
  # free for a new sign-up at once. The check allows an account without an address only
  # once it is deleted.
  #
  # A person's language, time zone and skin are checked by the application
  # (`Apiary.Accounts.Preferences`), not by the database: a new one is a release, never a
  # migration. An account's tokens go with its row.
  #
  # `citext` is created when it is missing and left in place on rollback, since it may have
  # been there before.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :language, :string, null: false, default: "en"
      add :time_zone, :string, null: false, default: "Etc/UTC"
      add :skin, :string, null: false, default: "standard"
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    create constraint(:users, :users_email_unless_deleted,
             check: "email IS NOT NULL OR deleted_at IS NOT NULL"
           )

    create table(:users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
