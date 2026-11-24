defmodule Apiary.Repo.Migrations.ValidateTheDeliveryFailureCheck do
  use Ecto.Migration

  # Validates the delivery failure check that the migration before this one added NOT
  # VALID: a scan that takes no lock that blocks writes to `artifact_versions`. Down
  # leaves it as it is; the migration before this one puts back the earlier check.
  def up do
    execute "ALTER TABLE artifact_versions VALIDATE CONSTRAINT artifact_versions_delivery_failure_check"
  end

  def down, do: :ok
end
