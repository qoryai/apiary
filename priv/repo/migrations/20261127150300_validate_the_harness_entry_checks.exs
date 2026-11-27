defmodule Apiary.Repo.Migrations.ValidateTheHarnessEntryChecks do
  use Ecto.Migration

  # Validates the key and the two checks the migration before this one added NOT VALID:
  # scans that take no lock that blocks writes to `run_credentials`. Every row there
  # before is a `work` or `push` row with a connection of the run's organisation, which
  # passes all three.
  # Down leaves them as they are; the migration before this one restores the old ones.
  def up do
    execute "ALTER TABLE run_credentials VALIDATE CONSTRAINT run_credentials_connection_id_fkey"
    execute "ALTER TABLE run_credentials VALIDATE CONSTRAINT run_credentials_link_check"
    execute "ALTER TABLE run_credentials VALIDATE CONSTRAINT run_credentials_issued_apply_check"
  end

  def down, do: :ok
end
