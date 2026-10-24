defmodule Apiary.Repo.Migrations.ValidateABuildFailureCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `environments`. Every row the check before took passes
  # it. Down leaves the check as it is; the migration before this one restores the old
  # one.
  def up do
    execute "ALTER TABLE environments VALIDATE CONSTRAINT environments_failure_check"
  end

  def down, do: :ok
end
