defmodule Apiary.Dispatches.Sweep do
  @moduledoc false

  # Frees what is due on every node pool's claims (`Apiary.Dispatches.sweep/1`): a
  # dispatch whose lease lapsed before its handover, at or after `lease_until`, is marked
  # stale, its slot freed, and its run waits in its workspace's queue again, with the same
  # `run_id` and the same `queued_at`, so it takes back its place at the front of the
  # queue; an ended dispatch whose slot is still held has it freed. Whatever the state of
  # the pool or of the key that claimed it, so the run of a deleted pool or of a revoked
  # key waits for the workspace's other pools. A claim frees what is due on its pool
  # first too; the sweep frees the rest, of pools that claim nothing. Oban's cron plugin
  # enqueues it every minute, from the crontab the application starts Oban with; it is the
  # instance's work and names no organisation. Run twice, the second run frees nothing
  # more. Its clock is the queue's (`Apiary.Dispatches.now/0`).
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{}) do
    _workspaces = Apiary.Dispatches.sweep(Apiary.Dispatches.now())
    :ok
  end
end
