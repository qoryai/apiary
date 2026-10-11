defmodule Apiary.Repo.Migrations.DropTheClosedStateOfARun do
  use Ecto.Migration

  # A run has no state `closed`. Qory Apiary records what a run reports and never ends a run
  # it did not start; it starts none today. `closed_at` and `closed_by_id` (with its index
  # and foreign key) go, and the check on `runs.state` no longer allows `closed`. A run in
  # that state is `lost` first.
  def up do
    execute(
      "UPDATE runs SET state = 'lost', lost_at = COALESCE(lost_at, closed_at, now()) " <>
        "WHERE state = 'closed'"
    )

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('succeeded', 'pending', 'running', 'failed', 'timed_out', 'lost', " <>
                 "'ended')"
           )

    drop index(:runs, [:closed_by_id])

    alter table(:runs) do
      remove :closed_by_id
      remove :closed_at
    end
  end

  # Rolled back, the columns are back, empty, and the check allows `closed` again.
  def down do
    alter table(:runs) do
      add :closed_at, :utc_datetime_usec
      add :closed_by_id, references(:users, type: :binary_id, on_delete: :nothing)
    end

    create index(:runs, [:closed_by_id])

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('succeeded', 'pending', 'running', 'failed', 'timed_out', 'lost', " <>
                 "'closed', 'ended')"
           )
  end
end
