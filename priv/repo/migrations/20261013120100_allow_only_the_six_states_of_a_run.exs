defmodule Apiary.Repo.Migrations.AllowOnlyTheSixStatesOfARun do
  use Ecto.Migration

  # The check on `runs.state` allows the six states only: pending, running, completed,
  # failed, cancelled and lost.
  #
  # First the guard. The migration before this one rewrote every row in `succeeded`,
  # `timed_out` or `ended`, so a row in one of them now was written since, by a build
  # without 20261009233000 that still writes to the database: this migration raises, and
  # the boot stops before the endpoint serves. Then the check is created again NOT VALID:
  # every write is held to it at once, and no row is scanned under the table's lock; the
  # next migration validates it.
  #
  # Rolled back, the check allows the six states and the three old names again, as
  # 20261009233000 left it.
  def up do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM runs WHERE state IN ('succeeded', 'timed_out', 'ended')"
      )

    if count > 0 do
      raise "runs holds #{count} rows in a state an earlier build wrote (succeeded, " <>
              "timed_out or ended): a build without migration 20261009233000 is still " <>
              "writing to this database. Stop it, then start this release again."
    end

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
