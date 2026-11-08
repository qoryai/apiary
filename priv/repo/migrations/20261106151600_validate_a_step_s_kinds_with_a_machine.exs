defmodule Apiary.Repo.Migrations.ValidateAStepSKindsWithAMachine do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `run_steps`. Down leaves it as it is; the migration
  # before this one replaces it.
  def up do
    execute "ALTER TABLE run_steps VALIDATE CONSTRAINT run_steps_kind_check"
  end

  def down, do: :ok
end
