defmodule Apiary.Repo.Migrations.RecordABuildFailedByItsExit do
  use Ecto.Migration

  # A prebuild whose run exits `failed` records its last build's failure as `failed`
  # (`Apiary.Dispatches.RunEnd`), apart from `lost`. `environments_failure_check` is
  # re-created to take it, with no reason, as `lost` and `timed_out` are: NOT VALID, so the
  # change scans no row under a lock that blocks writes to `environments`, then validated,
  # a scan that takes no such lock. Every row the check before took passes it. Down
  # stops while a record holds `failed`, which the check before refuses.
  @ref_check "BETWEEN 1 AND 200"

  def up do
    drop constraint(:environments, :environments_failure_check)
    execute check("('lost', 'timed_out', 'failed')")
    execute "ALTER TABLE environments VALIDATE CONSTRAINT environments_failure_check"
  end

  def down do
    drop constraint(:environments, :environments_failure_check)
    execute check("('lost', 'timed_out')")
    execute "ALTER TABLE environments VALIDATE CONSTRAINT environments_failure_check"
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
