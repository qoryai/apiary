defmodule Apiary.Repo.Migrations.StoreEveryRunUnderItsNewState do
  use Ecto.Migration

  # Every run a release before 20261009233000 stored is stored under the state a rebuild
  # folds for it today (`Apiary.Runs.Fold.exit_state/2`), so the next migration can allow
  # the six states only:
  #
  # - `succeeded` is `completed`; `timed_out` and `ended` are `cancelled`.
  # - A run that exited `failed` with the reason `session_lost` or `gateway_lost`, with no
  #   outcome, is `lost`, lost since its exit unless `lost_at` is already set.
  # - A run that exited `failed` with the reason `timeout`, `quiet`, `credential_expired`
  #   or `run_ended_at_issuer`, with no outcome, is `cancelled`.
  #
  # A failed run that did not exit, a refused one among them, and a failed run with an
  # outcome are left as they are, and no row's `updated_at` changes. A run whose events
  # retention pruned is rewritten as well.
  #
  # Outside a transaction, in batches of 1,000 ids in the order of `id`, each batch
  # committed before the next starts, so none holds its rows for long on a large `runs`.
  #
  # Then the guard. A row still in `succeeded`, `timed_out` or `ended` after the batches
  # was written during them, by a build without 20261009233000 that still writes to the
  # database: the migration raises, and the boot stops before the endpoint serves. A
  # migration that raises is not recorded, so the next start rewrites and checks again.
  #
  # Rolled back, nothing changes: the rewrite is what a rebuild gives, and a release with
  # 20261009233000 reads the new names.
  @disable_ddl_transaction true

  @batch 1_000

  @lost_reasons "'session_lost', 'gateway_lost'"
  @stopped_reasons "'timeout', 'quiet', 'credential_expired', 'run_ended_at_issuer'"

  @stored_before """
  (state IN ('succeeded', 'timed_out', 'ended') OR
    (state = 'failed' AND outcome_state IS NULL AND exited_at IS NOT NULL AND
      reason IN (#{@lost_reasons}, #{@stopped_reasons})))
  """

  def up do
    rewrite(nil)

    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM runs WHERE state IN ('succeeded', 'timed_out', 'ended')"
      )

    if count > 0 do
      raise "runs holds #{count} rows in a state an earlier build wrote (succeeded, " <>
              "timed_out or ended): a build without migration 20261009233000 is still " <>
              "writing to this database. Stop it, then start this release again."
    end
  end

  def down, do: :ok

  defp rewrite(after_id) do
    {after_clause, params} = if after_id, do: {"AND id > $1", [after_id]}, else: {"", []}

    %{rows: rows} =
      repo().query!(
        "SELECT id FROM runs WHERE #{@stored_before} #{after_clause} " <>
          "ORDER BY id LIMIT #{@batch}",
        params
      )

    ids = List.flatten(rows)

    if ids != [] do
      repo().query!(
        """
        UPDATE runs SET
          state = CASE
            WHEN state = 'succeeded' THEN 'completed'
            WHEN state = 'failed' AND reason IN (#{@lost_reasons}) THEN 'lost'
            ELSE 'cancelled'
          END,
          lost_at = CASE
            WHEN state = 'failed' AND reason IN (#{@lost_reasons})
              THEN COALESCE(lost_at, exited_at)
            ELSE lost_at
          END
        WHERE id = ANY($1) AND #{@stored_before}
        """,
        [ids]
      )

      if length(ids) == @batch, do: rewrite(List.last(ids))
    end

    :ok
  end
end
