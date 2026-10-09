defmodule Apiary.Repo.Migrations.SayWhatOpenedARun do
  use Ecto.Migration

  # A run says what opened it: `opened_by` of its `dev.qory.run.started`, `session` or
  # `gateway`, NULL until a start says it. A run a gateway opened has no session, and ends
  # with a reason and no exit status; one that ended quiet says the quiet period,
  # `quiet_seconds` of its `dev.qory.run.exited`. Both are folded from the events
  # (`Apiary.Runs.Fold`) like every other field. Such a run's end is the state `ended`,
  # which the check on `runs.state` now allows.
  def up do
    alter table(:runs) do
      add :opened_by, :text
      add :quiet_seconds, :integer
    end

    create constraint(:runs, :runs_opened_by_check, check: "opened_by IN ('session', 'gateway')")

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('succeeded', 'pending', 'running', 'failed', 'timed_out', 'lost', " <>
                 "'closed', 'ended')"
           )
  end

  # Rolled back, a run that `ended` is `failed`, as the fold before this migration reads an
  # exit without a state.
  def down do
    execute("UPDATE runs SET state = 'failed' WHERE state = 'ended'")

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('succeeded', 'pending', 'running', 'failed', 'timed_out', 'lost', " <>
                 "'closed')"
           )

    drop constraint(:runs, :runs_opened_by_check)

    alter table(:runs) do
      remove :opened_by
      remove :quiet_seconds
    end
  end
end
