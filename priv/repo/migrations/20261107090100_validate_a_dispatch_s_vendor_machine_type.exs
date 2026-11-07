defmodule Apiary.Repo.Migrations.ValidateADispatchSVendorMachineType do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `dispatches`. Down leaves it as it is; the migration
  # before this one drops it.
  def up do
    execute "ALTER TABLE dispatches VALIDATE CONSTRAINT dispatches_vendor_machine_type_check"
  end

  def down, do: :ok
end
