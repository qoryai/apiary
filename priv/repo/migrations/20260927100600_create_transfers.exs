defmodule Apiary.Repo.Migrations.CreateTransfers do
  use Ecto.Migration

  # A pending offer of an organisation's ownership, one row per organisation at most,
  # deleted when it is accepted or withdrawn; the trail keeps what happened. Two kinds, which
  # the check keeps apart:
  #
  # - `to_admin`: an organisation whose owners are all suspended offered to one of its admins
  #   by an instance admin, the arbiter (`arbitrated`, with its `reason`). `recipient_id` is
  #   the admin, by a key against their membership, so their removal takes the offer with
  #   it. It names no operator.
  # - `to_operator`: an organisation that is no client offered to an operator by its owner.
  #   `operator_id` is the operator, whose purge takes the offer with it.
  #
  # `organisation_id` is unique: one pending offer per organisation. Only an arbitrated
  # offer has a reason.
  def change do
    create table(:transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :text, null: false

      add :recipient_id,
          references(:memberships,
            column: :user_id,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: :delete_all
          )

      add :operator_id, references(:organisations, type: :binary_id, on_delete: :delete_all)
      add :offered_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :arbitrated, :boolean, null: false, default: false
      add :reason, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:transfers, [:organisation_id])
    create index(:transfers, [:operator_id], where: "operator_id IS NOT NULL")
    create index(:transfers, [:recipient_id], where: "recipient_id IS NOT NULL")

    create constraint(:transfers, :transfers_kind_check,
             check:
               "(kind = 'to_admin' AND recipient_id IS NOT NULL AND operator_id IS NULL " <>
                 "AND arbitrated) OR " <>
                 "(kind = 'to_operator' AND recipient_id IS NULL AND operator_id IS NOT NULL " <>
                 "AND NOT arbitrated)"
           )

    create constraint(:transfers, :transfers_reason_check, check: "arbitrated OR reason IS NULL")
  end
end
