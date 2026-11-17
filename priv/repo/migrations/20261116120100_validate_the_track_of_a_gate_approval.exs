defmodule Apiary.Repo.Migrations.ValidateTheTrackOfAGateApproval do
  use Ecto.Migration

  # Validates the checks that the migration before this one added NOT VALID: a scan that
  # takes no lock that blocks writes to `gate_decisions` and `stage_skips`. Down leaves
  # them as they are; the migration before this one drops them.
  def up do
    execute "ALTER TABLE gate_decisions VALIDATE CONSTRAINT gate_decisions_track_check"
    execute "ALTER TABLE stage_skips VALIDATE CONSTRAINT stage_skips_condition_check"
  end

  def down, do: :ok
end
