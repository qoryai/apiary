defmodule Apiary.Repo.Migrations.RecordARunSOutcome do
  use Ecto.Migration

  # A run's outcome, as its starter gave it (`Apiary.Runs.Outcome`), on its own row of
  # `runs`:
  #
  # `outcome_state`, `succeeded`, `failed` or `cancelled`; `outcome_reason`, its code, nil
  # when it gave none; `outcome_time`, the `time` its body was built at, on the starter's
  # clock; `outcome_received_at`, when this server took it; `outcome_digest`, the SHA-256 of
  # the body's bytes, 32 bytes. All of the first outcome's: a repeat changes none of them.
  # All NULL for a run that was given none, every existing row among them, and the four
  # but the reason all set for one that was. The projector does not fold them, so a rebuild
  # keeps them; the fold reads them (`Apiary.Runs.Fold`).
  #
  # `exit_state` and `exit_reason`, folded from the run's `dev.qory.run.exited`: the state
  # its exit means and Forager's reason, kept beside the outcome, which decides `state` and
  # `reason` once there is one. NULL until an exit is folded, and for every existing row
  # until it is rebuilt.
  #
  # The checks are added NOT VALID, so adding them takes no scan of the table under its
  # lock; the next migration validates them.
  def change do
    alter table(:runs) do
      add :outcome_state, :text
      add :outcome_reason, :text
      add :outcome_time, :utc_datetime_usec
      add :outcome_received_at, :utc_datetime_usec
      add :outcome_digest, :binary
      add :exit_state, :text
      add :exit_reason, :text
    end

    create constraint(:runs, :runs_outcome_check,
             check:
               "(outcome_state IS NULL AND outcome_reason IS NULL AND outcome_time IS NULL AND " <>
                 "outcome_received_at IS NULL AND outcome_digest IS NULL) OR " <>
                 "(outcome_state IN ('succeeded', 'failed', 'cancelled') AND " <>
                 "outcome_time IS NOT NULL AND outcome_received_at IS NOT NULL AND " <>
                 "octet_length(outcome_digest) = 32)",
             validate: false
           )

    create constraint(:runs, :runs_exit_state_check,
             check:
               "exit_state IS NULL OR exit_state IN ('completed', 'failed', 'cancelled', 'lost')",
             validate: false
           )
  end
end
