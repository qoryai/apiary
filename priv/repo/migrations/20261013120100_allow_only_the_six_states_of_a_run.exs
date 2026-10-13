defmodule Apiary.Repo.Migrations.AllowOnlyTheSixStatesOfARun do
  use Ecto.Migration

  # The check on `runs.state` allows the six states only: pending, running, completed,
  # failed, cancelled and lost. It is created again NOT VALID: every write is held to it
  # at once, and no row is scanned under the table's lock; the next migration validates
  # it.
  #
  # Rolled back, the check allows the six states and the three old names again, as
  # 20261009233000 left it.
  def up do
    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check: "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost')",
             validate: false
           )
  end

  def down do
    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost', " <>
                 "'succeeded', 'timed_out', 'ended')"
           )
  end
end
