defmodule Apiary.Repo.Migrations.ValidateTheChangeKindsCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `nodes`. Every row passes it, as the column is NULL on
  # every row there before. Down leaves the check as it is; the migration before this one
  # drops it.
  def up do
    execute "ALTER TABLE nodes VALIDATE CONSTRAINT nodes_change_kinds_check"
  end

  def down, do: :ok
end
