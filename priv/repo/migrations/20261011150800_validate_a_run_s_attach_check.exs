defmodule Apiary.Repo.Migrations.ValidateARunSAttachCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `runs`. Down leaves it as it is; the migration before
  # this one restores the old one.
  def up, do: execute("ALTER TABLE runs VALIDATE CONSTRAINT runs_attach_check")

  def down, do: :ok
end
