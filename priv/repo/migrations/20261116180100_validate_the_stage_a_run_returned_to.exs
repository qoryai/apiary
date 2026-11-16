defmodule Apiary.Repo.Migrations.ValidateTheStageARunReturnedTo do
  use Ecto.Migration

  # Validates the checks the migration before this one added NOT VALID: scans that take
  # no lock that blocks writes to `dispatch_runs` and `escalations`. Down leaves them as
  # they are; the migration before this one replaces them.
  def up do
    execute "ALTER TABLE dispatch_runs VALIDATE CONSTRAINT dispatch_runs_returned_to_check"
    execute "ALTER TABLE escalations VALIDATE CONSTRAINT escalations_cause_check"
  end

  def down, do: :ok
end
