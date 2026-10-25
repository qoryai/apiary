defmodule Apiary.Repo.Migrations.ValidateTheCallUrlCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `nodes`. Every row takes it, as both columns are new and
  # NULL. Down leaves the check as it is; the migration before this one removes it.
  def up do
    execute "ALTER TABLE nodes VALIDATE CONSTRAINT nodes_call_url_check"
  end

  def down, do: :ok
end
