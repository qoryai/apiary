defmodule Apiary.Repo.Migrations.ValidateTheAdapterFailureCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `dispatch_runs`. Every row takes it, as the columns are
  # new and NULL. Down leaves the check as it is; the migration before this one removes it.
  def up do
    execute "ALTER TABLE dispatch_runs VALIDATE CONSTRAINT dispatch_runs_adapter_failure_check"
  end

  def down, do: :ok
end
