defmodule Apiary.Repo.Migrations.KeepTheMovesBackARunnerWrites do
  use Ecto.Migration

  # A work item that goes back to an earlier stage withdraws the approvals of that stage
  # and of each later one (`Apiary.Stages.Withdrawals`), and a move back to Explore or
  # before it withdraws the confirmation of Explore's proposal.
  #
  # `gate_decisions_automatic_check` allows `automatic` on a `:move` with no `user_id`:
  # the move that the stage runner writes for a run's return, a return of Request changes,
  # and a take in again. The check is added NOT VALID, so adding it takes no scan of the
  # table under its lock; `20261122100100` validates it. `20261122100200` changes the
  # index of the confirmations.
  def up do
    drop constraint(:gate_decisions, :gate_decisions_automatic_check)

    create constraint(:gate_decisions, :gate_decisions_automatic_check,
             check: "NOT automatic OR (kind IN ('approve', 'move') AND user_id IS NULL)",
             validate: false
           )
  end

  # Down puts back the check that allows `automatic` only on an approval, and validates
  # it. It fails with a check violation once the stage runner has written a move: delete
  # those moves first (`automatic` and `kind` 'move').
  def down do
    drop constraint(:gate_decisions, :gate_decisions_automatic_check)

    create constraint(:gate_decisions, :gate_decisions_automatic_check,
             check: "NOT automatic OR (kind = 'approve' AND user_id IS NULL)"
           )
  end
end
