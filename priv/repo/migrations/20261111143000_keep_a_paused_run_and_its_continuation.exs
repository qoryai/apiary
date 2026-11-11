defmodule Apiary.Repo.Migrations.KeepAPausedRunAndItsContinuation do
  use Ecto.Migration

  # A run that paused at its model keys' limit, and the run that continues it
  # (`Apiary.Dispatches.Pause`):
  #
  # - `runs.state` may be `paused`: the run ended with the reason `model_key_limit`, and
  #   its work goes on in the run that continues it. The check on `runs.state` allows it
  #   beside the six states, and the check on `runs.exit_state` beside the four states an
  #   exit means; that check stays unvalidated, as it was made.
  # - `dispatch_runs.continues_id`: the run of the queue that a continuation continues,
  #   the paused one, nil for every other run. At most one run continues a paused run. It
  #   becomes nil should the paused run be deleted.
  # - `dispatch_runs.paused_until`: for a paused run whose provider had every key in
  #   cooldown when the run ended, the earliest end of those cooldowns; nil for every
  #   other run.
  #
  # Nothing exists to fill. Rolled back, a paused run is cancelled, the state its exit
  # gave, its `exit_state` too, and the two columns go.
  def up do
    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check:
               "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost', " <>
                 "'paused')"
           )

    drop constraint(:runs, :runs_exit_state_check)

    create constraint(:runs, :runs_exit_state_check,
             check:
               "exit_state IS NULL OR " <>
                 "exit_state IN ('completed', 'failed', 'cancelled', 'lost', 'paused')",
             validate: false
           )

    alter table(:dispatch_runs) do
      add :continues_id, references(:dispatch_runs, type: :binary_id, on_delete: :nilify_all)
      add :paused_until, :utc_datetime_usec
    end

    create unique_index(:dispatch_runs, [:continues_id], where: "continues_id IS NOT NULL")
  end

  def down do
    drop index(:dispatch_runs, [:continues_id])

    alter table(:dispatch_runs) do
      remove :continues_id
      remove :paused_until
    end

    execute("UPDATE runs SET state = 'cancelled' WHERE state = 'paused'")
    execute("UPDATE runs SET exit_state = 'cancelled' WHERE exit_state = 'paused'")
    drop constraint(:runs, :runs_exit_state_check)

    create constraint(:runs, :runs_exit_state_check,
             check:
               "exit_state IS NULL OR exit_state IN ('completed', 'failed', 'cancelled', 'lost')",
             validate: false
           )

    drop constraint(:runs, :runs_state_check)

    create constraint(:runs, :runs_state_check,
             check: "state IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'lost')"
           )
  end
end
