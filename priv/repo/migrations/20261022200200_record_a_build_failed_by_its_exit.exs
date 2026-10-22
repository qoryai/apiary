defmodule Apiary.Repo.Migrations.RecordABuildFailedByItsExit do
  use Ecto.Migration

  # A prebuild whose run exits `failed` records its last build's failure as `failed`
  # (`Apiary.Dispatches.RunEnd`), apart from `lost`. `environments_failure_check` is
  # re-created to take it, with no reason, as `lost` and `timed_out` are. It is added NOT
  # VALID, so the change scans no row under the lock that blocks writes to `environments`;
  # the next migration validates it. Every row the check before took passes it.
  #
  # Down first reads the records whose failure is `failed`, a scan that blocks no write,
  # and stops while there is one: the check before refuses `failed`. It then re-creates
  # that check NOT VALID. A record given `failed` between the read and the re-creation
  # keeps it, and the check refuses every later update of that row that keeps `failed`.
  @ref_check "BETWEEN 1 AND 200"

  def up do
    drop constraint(:environments, :environments_failure_check)
    execute check("('lost', 'timed_out', 'failed')")
  end

  def down do
    execute """
    DO $$
    DECLARE
      records text;
    BEGIN
      SELECT string_agg(id::text, ', ' ORDER BY id) INTO records
      FROM environments WHERE failure_cause = 'failed';

      IF records IS NOT NULL THEN
        RAISE EXCEPTION 'Set failure_cause to lost on the environment records %, then roll back again: the check before this migration refuses failed', records
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    drop constraint(:environments, :environments_failure_check)
    execute check("('lost', 'timed_out')")
  end

  defp check(causes) do
    """
    ALTER TABLE environments ADD CONSTRAINT environments_failure_check CHECK (
      (failure_cause IS NULL AND failure_reason IS NULL AND failed_at IS NULL) OR
      (failure_cause IS NOT NULL AND failed_at IS NOT NULL AND (
        (failure_cause = 'released' AND failure_reason IS NOT NULL AND
         char_length(failure_reason) #{@ref_check}) OR
        (failure_cause IN #{causes} AND failure_reason IS NULL)))
    ) NOT VALID
    """
  end
end
