defmodule Apiary.Repo.Migrations.ValidateTheEscalationOfAMove do
  use Ecto.Migration

  # Validates the key that `20261117090000` added NOT VALID: a scan that takes no lock that
  # blocks writes to `gate_decisions`. Down leaves it as it is; the first migration drops
  # the column and the key with it.
  def up do
    execute "ALTER TABLE gate_decisions VALIDATE CONSTRAINT gate_decisions_escalation_id_fkey"
  end

  def down, do: :ok
end
