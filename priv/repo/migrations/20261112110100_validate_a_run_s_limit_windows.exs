defmodule Apiary.Repo.Migrations.ValidateARunSLimitWindows do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `runs`. Down leaves it as it is; the migration before
  # this one replaces it.
  def up do
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_provider_api_check"
  end

  def down, do: :ok
end
