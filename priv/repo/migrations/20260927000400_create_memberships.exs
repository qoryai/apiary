defmodule Apiary.Repo.Migrations.CreateMemberships do
  use Ecto.Migration

  # A person's membership of an organisation, at a level: `owner`, `admin` or `member`,
  # which the check keeps to those three. `(organisation_id, user_id)` is unique: one
  # membership per person and organisation, and a key an edition's table may reference.
  # The membership goes with the organisation and with the account.
  #
  # A membership can be suspended and activated again: `suspended_at`, when, and
  # `suspended_by_id`, by whom, both empty for one that is not suspended. The check keeps
  # the suspender with a suspension. What a suspension did and who ended it is the audit
  # trail's.
  def change do
    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :level, :string, null: false
      add :suspended_at, :utc_datetime_usec
      add :suspended_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:organisation_id, :user_id])
    create index(:memberships, [:user_id])

    create constraint(:memberships, :memberships_level_check,
             check: "level IN ('owner', 'admin', 'member')"
           )

    create constraint(:memberships, :memberships_suspension_check,
             check: "suspended_by_id IS NULL OR suspended_at IS NOT NULL"
           )
  end
end
