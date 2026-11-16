defmodule Apiary.Repo.Migrations.KeepWhetherAGateApprovedAutomatically do
  use Ecto.Migration

  # A gate `none` records its approval (`Apiary.Stages`): `gate_decisions.automatic` is
  # true for the approval the runner wrote with no member, and false for every decision
  # a person made. A check keeps an automatic decision an approval with no `user_id`.
  #
  # The column has a constant default, so adding it rewrites no row. The check is added
  # NOT VALID, so adding it takes no scan of the table under its lock;
  # `20261116100100` validates it. It changes no row: every decision stored before is a
  # person's.
  def up do
    alter table(:gate_decisions) do
      add :automatic, :boolean, null: false, default: false
    end

    create constraint(:gate_decisions, :gate_decisions_automatic_check,
             check: "NOT automatic OR (kind = 'approve' AND user_id IS NULL)",
             validate: false
           )
  end

  # Rolled back, the approvals the runner wrote stay, each with no `user_id`, as the
  # approval of a member whose account is gone.
  def down do
    drop constraint(:gate_decisions, :gate_decisions_automatic_check)

    alter table(:gate_decisions) do
      remove :automatic
    end
  end
end
