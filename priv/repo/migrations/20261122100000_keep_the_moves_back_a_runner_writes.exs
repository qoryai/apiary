defmodule Apiary.Repo.Migrations.KeepTheMovesBackARunnerWrites do
  use Ecto.Migration

  # A work item that goes back to an earlier stage withdraws the approvals of that stage
  # and of each later one (`Apiary.Stages.Withdrawals`), and a move back to Explore or
  # before it withdraws the confirmation of Explore's proposal.
  #
  # - `gate_decisions_automatic_check` allows `automatic` on a `:move` with no `user_id`:
  #   the move that the stage runner writes for a run's return, a return of Request
  #   changes, and a take in again.
  # - `work_item_confirmations` keeps any number of confirmations per take in: a member
  #   confirms again after a move back withdrew the confirmation. The unique index on
  #   (`work_item_id`, `take_in`) becomes a plain index.
  def up do
    drop constraint(:gate_decisions, :gate_decisions_automatic_check)

    create constraint(:gate_decisions, :gate_decisions_automatic_check,
             check: "NOT automatic OR (kind IN ('approve', 'move') AND user_id IS NULL)"
           )

    drop unique_index(:work_item_confirmations, [:work_item_id, :take_in])
    create index(:work_item_confirmations, [:work_item_id, :take_in])
  end

  # Down fails once a take in has two confirmations (the unique index), or once the stage
  # runner has written a move (the check). Delete the older confirmations of each take in
  # and the moves with `automatic` true first.
  def down do
    drop index(:work_item_confirmations, [:work_item_id, :take_in])
    create unique_index(:work_item_confirmations, [:work_item_id, :take_in])

    drop constraint(:gate_decisions, :gate_decisions_automatic_check)

    create constraint(:gate_decisions, :gate_decisions_automatic_check,
             check: "NOT automatic OR (kind = 'approve' AND user_id IS NULL)"
           )
  end
end
