defmodule Apiary.Repo.Migrations.ValidateARunSGatewayChecks do
  use Ecto.Migration

  # Validates the checks and the reference the migration before this one added NOT VALID:
  # a scan that takes no lock that blocks writes to `runs`. Down leaves them as they are;
  # the migration before this one drops them.
  def up do
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_registration_check"
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_run_key_check"
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_attach_check"
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_gateway_id_fkey"
  end

  def down, do: :ok
end
