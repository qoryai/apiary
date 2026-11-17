defmodule Apiary.Repo.Migrations.ValidateASwitchAsAResolution do
  use Ecto.Migration

  # Validates the check that the migration before this one added NOT VALID: a scan that
  # takes no lock that blocks writes to `escalations`. Down leaves it as it is; the
  # migration before this one replaces it.
  def up do
    execute "ALTER TABLE escalations VALIDATE CONSTRAINT escalations_resolution_check"
  end

  def down, do: :ok
end
