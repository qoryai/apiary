defmodule Apiary.Repo.Migrations.ValidateTheDecisionOfAVersion do
  use Ecto.Migration

  # Validates the check that the migration before this one added NOT VALID: a scan that
  # takes no lock that blocks writes to `artifact_versions`. Down leaves it as it is; the
  # migration before this one drops it.
  def up do
    execute "ALTER TABLE artifact_versions VALIDATE CONSTRAINT artifact_versions_decision_id_check"
  end

  def down, do: :ok
end
