defmodule Apiary.Repo.Migrations.ValidateAKeySApiPaths do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `run_model_keys`. Down leaves it as it is; the migration
  # before this one replaces it.
  def up do
    execute "ALTER TABLE run_model_keys VALIDATE CONSTRAINT run_model_keys_api_check"
  end

  def down, do: :ok
end
