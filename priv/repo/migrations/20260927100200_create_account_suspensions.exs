defmodule Apiary.Repo.Migrations.CreateAccountSuspensions do
  use Ecto.Migration

  # The suspended accounts, one row per suspended account: suspending an account inserts
  # its row and activating it deletes the row, so the row is never updated. `suspended_at`
  # is when, and `suspended_by_id` who, empty when a release command suspended the account
  # with no person behind it. The audit trail holds the history: what a suspension did and
  # who ended it. The row goes with its account.
  def change do
    create table(:account_suspensions, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :suspended_at, :utc_datetime_usec, null: false
      add :suspended_by_id, references(:users, type: :binary_id, on_delete: :nothing)
    end
  end
end
