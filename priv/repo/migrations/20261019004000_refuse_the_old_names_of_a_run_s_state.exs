defmodule Apiary.Repo.Migrations.RefuseTheOldNamesOfARunSState do
  use Ecto.Migration

  # A run is pending, running, completed, failed, cancelled or lost, and the check on
  # `runs.state` allows these six and no other. A row stored under one of the three old
  # names the check allowed beside them (20261009233000) is rewritten to the state that took
  # the name in: `succeeded` to `completed`, `timed_out` and `ended` to `cancelled`.
  def up do
    execute("UPDATE runs SET state = 'completed' WHERE state = 'succeeded'")
    execute("UPDATE runs SET state = 'cancelled' WHERE state IN ('timed_out', 'ended')")

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check: "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost')"
           )
  end

  # Rolled back, the check allows the three old names again. No row gets an old name back:
  # `up` keeps no record of which completed or cancelled row had one.
  def down do
    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost', " <>
                 "'succeeded', 'timed_out', 'ended')"
           )
  end
end
