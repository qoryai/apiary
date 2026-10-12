defmodule Apiary.Repo.Migrations.AllowTheSixStatesOfARun do
  use Ecto.Migration

  # A run is pending, running, completed, failed, cancelled or lost. The check on
  # `runs.state` allows those six and still the three names a release before this one
  # writes, `succeeded`, `timed_out` and `ended`, so that both releases can write while a
  # deploy rolls out; `Apiary.Runs.Run` reads each old name as its new state. No row is
  # rewritten.
  def up do
    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost', " <>
                 "'succeeded', 'timed_out', 'ended')"
           )
  end

  # Rolled back, the check allows the seven states of before again. A completed run is
  # succeeded; a cancelled one is timed out when it reached its time limit, and ended
  # otherwise.
  def down do
    execute("UPDATE runs SET state = 'succeeded' WHERE state = 'completed'")

    execute(
      "UPDATE runs SET state = CASE WHEN reason = 'timeout' THEN 'timed_out' ELSE 'ended' END " <>
        "WHERE state = 'cancelled'"
    )

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('succeeded', 'pending', 'running', 'failed', 'timed_out', 'lost', " <>
                 "'ended')"
           )
  end
end
