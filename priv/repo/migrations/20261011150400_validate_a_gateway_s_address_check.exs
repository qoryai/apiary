defmodule Apiary.Repo.Migrations.ValidateAGatewaySAddressCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `nodes`. Down leaves it as it is; the migration before
  # this one restores the old one.
  def up, do: execute("ALTER TABLE nodes VALIDATE CONSTRAINT nodes_url_check")

  def down, do: :ok
end
