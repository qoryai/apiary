defmodule Apiary.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  # An invitation to an organisation: an email address and nothing else, into a workspace
  # of the organisation, by the composite key; the person joins as a member, and an owner
  # changes their level afterwards. The link carries a token whose hash alone is stored,
  # unique. One pending invitation per address and organisation, by the partial unique
  # index. The inviter is a plain reference, indexed so that a check of it never scans the
  # table: an account is never deleted, and the row keeps naming who sent it.
  def change do
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :email, :citext, null: false
      add :token_hash, :binary, null: false
      add :invited_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :accepted_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invitations, [:token_hash])

    create unique_index(:invitations, [:organisation_id, :email],
             where: "accepted_at IS NULL",
             name: :invitations_pending_email_index
           )

    create index(:invitations, [:organisation_id, :workspace_id])
    create index(:invitations, [:invited_by_id])
  end
end
