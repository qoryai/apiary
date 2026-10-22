defmodule Apiary.Repo.Migrations.ValidateTheHeldRunChecks do
  use Ecto.Migration

  # Validates the checks the migration before this one added NOT VALID: scans that take no
  # lock that blocks writes to `environments` or `dispatch_runs`. Every row takes them:
  # `built_ref` is set where an image is, and every other column is new and empty, or
  # false. Down leaves the checks as they are; the
  # migration before this one removes them.
  def up do
    execute "ALTER TABLE environments VALIDATE CONSTRAINT environments_built_ref_check"
    execute "ALTER TABLE environments VALIDATE CONSTRAINT environments_lost_ref_check"
    execute "ALTER TABLE dispatch_runs VALIDATE CONSTRAINT dispatch_runs_image_requeue_check"
  end

  def down, do: :ok
end
