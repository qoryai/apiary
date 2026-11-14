defmodule Apiary.Repo.Migrations.ValidateWhoCancelledARun do
  use Ecto.Migration

  # Validates the key to `users` that the migration before this one added NOT VALID: a
  # scan that takes no lock that blocks writes to `runs`. Down leaves it as it is; the
  # migration before this one drops it.
  def up do
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_cancel_requested_by_id_fkey"
  end

  def down, do: :ok
end
