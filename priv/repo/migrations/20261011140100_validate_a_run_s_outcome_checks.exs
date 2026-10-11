defmodule Apiary.Repo.Migrations.ValidateARunSOutcomeChecks do
  use Ecto.Migration

  # Validates the checks the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `runs`. Down leaves them as they are; the migration before
  # this one drops them.
  def up do
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_outcome_check"
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_exit_state_check"
  end

  def down, do: :ok
end
