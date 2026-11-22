defmodule Apiary.Repo.Migrations.ValidateTheCheckOfARunnerSMove do
  use Ecto.Migration

  # Validates the check that the migration before this one added NOT VALID: a scan that
  # takes no lock that blocks writes to `gate_decisions`. Down leaves it as it is; the
  # migration before this one puts back the earlier check.
  def up do
    execute "ALTER TABLE gate_decisions VALIDATE CONSTRAINT gate_decisions_automatic_check"
  end

  def down, do: :ok
end
