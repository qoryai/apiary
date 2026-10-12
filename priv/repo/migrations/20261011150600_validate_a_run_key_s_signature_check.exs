defmodule Apiary.Repo.Migrations.ValidateARunKeySSignatureCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `runs`. Down leaves it as it is; the migration before
  # this one drops it.
  def up, do: execute("ALTER TABLE runs VALIDATE CONSTRAINT runs_run_key_signature_check")

  def down, do: :ok
end
