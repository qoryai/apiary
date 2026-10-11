defmodule Apiary.Repo.Migrations.ValidateAnEventSInstanceCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `events`. Down leaves it as it is; the migration before
  # this one drops it.
  def up, do: execute("ALTER TABLE events VALIDATE CONSTRAINT events_instance_id_check")

  def down, do: :ok
end
