defmodule Apiary.Repo.Migrations.ValidateAStageThatATrackPassesOver do
  use Ecto.Migration

  # Validates the check that the migration before this one added NOT VALID: a scan that
  # takes no lock that blocks writes to `stage_skips`. Down leaves it as it is; the
  # migration before this one drops it.
  def up do
    execute "ALTER TABLE stage_skips VALIDATE CONSTRAINT stage_skips_stage_check"
  end

  def down, do: :ok
end
