defmodule Apiary.Repo.Migrations.GiveEachWaitingRunItsRunRecord do
  use Ecto.Migration

  # A run of a workspace's queue has its run record from the moment it is queued
  # (`Apiary.Dispatches.Queued`): `pending`, with no node and no registration, its `rn_`
  # id and the next number of its workspace. The Runs list and the run page show it as
  # queued. This release writes the record with every run it queues; the claim updates it.
  #
  # `up` writes the record of each run of the queue that still waits and has none: its
  # workspace's next numbers, in the order the runs were queued, after the workspace's
  # counter (`run_counters`) and its highest number, whichever is higher; `inserted_at`
  # when it was queued; `node_run_id` the run of the queue's `run_id`. The counters then
  # go on from the last number given. A run of the queue that ended, or that a claim took,
  # gets nothing. `id` is a random UUID, and `public_id` comes from the column's default,
  # `run_public_id()`.
  #
  # Locks, held until the migration's transaction ends, taken in the order a claim takes
  # them, so the migration and a claim never wait on each other in a cycle:
  #
  # 1. The waiting runs of the queue `FOR UPDATE`, so no claim takes one meanwhile. A
  #    claim locks the run it takes `FOR UPDATE SKIP LOCKED` first, then the counter
  #    (`Apiary.Runs.Number`): a claim that has locked a run finishes, and the migration
  #    then locks that run.
  # 2. `run_counters` in `SHARE ROW EXCLUSIVE` mode, so no run takes a number meanwhile:
  #    the trigger `runs_number_from_counter` and `Apiary.Runs.Number` both write the
  #    counter's row.
  #
  # `lock_timeout` is 5 seconds: a lock not granted by then fails the migration, which
  # changes nothing, and running it again takes the locks again.
  #
  # Only the waiting runs are read and written: the anti-join reads `runs` by its unique
  # index on `dispatch_run_id`, and the highest number of a workspace by the unique index
  # on (`workspace_id`, `number`).
  #
  # While a node of the previous release runs beside this one, its claim of a run whose
  # record this release wrote inserts a second record, which the unique index of
  # `runs.dispatch_run_id` refuses: the claim raises, its transaction rolls back and the
  # claim is answered 503 `unavailable`. The run stays queued with its record, and a claim
  # of this release takes it. The previous release claims the oldest waiting run first, so
  # while that run has a record, every claim of the previous release for that queue fails,
  # until the nodes run this release.
  #
  # `down` deletes the records of the runs that still wait, which the previous release
  # writes at the claim: pending, a run of the queue, with no node and no registration. A
  # record of a run that ended while it waited stays, with its number. The counters stay
  # as they are, so no number is given twice.
  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "SELECT id FROM dispatch_runs WHERE state = 'waiting' FOR UPDATE"
    execute "LOCK TABLE run_counters IN SHARE ROW EXCLUSIVE MODE"

    execute """
    WITH waiting AS (
      SELECT d.id, d.run_id, d.organisation_id, d.workspace_id, d.queued_at
      FROM dispatch_runs d
      WHERE d.state = 'waiting'
        AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.dispatch_run_id = d.id)
    ),
    numbered AS (
      SELECT w.*,
        GREATEST(
          COALESCE((SELECT c.last_number FROM run_counters c
                    WHERE c.workspace_id = w.workspace_id), 0),
          COALESCE((SELECT max(r.number) FROM runs r
                    WHERE r.workspace_id = w.workspace_id), 0)
        ) + row_number() OVER (
          PARTITION BY w.workspace_id ORDER BY w.queued_at, w.id
        ) AS number
      FROM waiting w
    )
    INSERT INTO runs (
      id, organisation_id, workspace_id, number, node_run_id, state, dispatch_run_id,
      inserted_at, updated_at
    )
    SELECT gen_random_uuid(), organisation_id, workspace_id, number, run_id, 'pending', id,
      queued_at, now()
    FROM numbered
    """

    execute """
    INSERT INTO run_counters (organisation_id, workspace_id, last_number)
    SELECT r.organisation_id, r.workspace_id, max(r.number)
    FROM runs r
    JOIN dispatch_runs d ON d.id = r.dispatch_run_id
    WHERE d.state = 'waiting' AND r.state = 'pending'
      AND r.node_id IS NULL AND r.registered_at IS NULL
    GROUP BY r.organisation_id, r.workspace_id
    ON CONFLICT (workspace_id) DO UPDATE
    SET last_number = GREATEST(run_counters.last_number, EXCLUDED.last_number)
    """
  end

  def down do
    execute """
    DELETE FROM runs
    WHERE state = 'pending' AND dispatch_run_id IS NOT NULL
      AND node_id IS NULL AND registered_at IS NULL
    """
  end
end
