defmodule Apiary.Repo.Migrations.ValidateTheSixStatesCheck do
  use Ecto.Migration

  # Validates the check on `runs.state` the migration before this one created NOT VALID:
  # a scan that takes no lock that blocks writes to `runs`. It fails while a row holds a
  # state outside the six, one an earlier build wrote after the guard. Down leaves the
  # check as it is; the migration before this one creates the wide one again.
  def up do
    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_state_check"
  end

  def down, do: :ok
end
