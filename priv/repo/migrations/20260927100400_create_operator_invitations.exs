defmodule Apiary.Repo.Migrations.CreateOperatorInvitations do
  use Ecto.Migration

  # An operator's invitation of its client's first owner: a row beside the core's invitation,
  # which makes the person who accepts it the client's owner, where every other invitation
  # makes a member. `organisation_id` is the client, the invitation's own organisation, and
  # `operator_id` the operator that sent it; the row goes with the invitation, with the
  # client and with the operator. The index serves an operator's invitations, and the purge
  # of an operator.
  def change do
    create table(:operator_invitations, primary_key: false) do
      add :invitation_id,
          references(:invitations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :operator_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:operator_invitations, [:operator_id])
  end
end
