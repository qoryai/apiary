defmodule Apiary.Repo.Migrations.ValidateTheSixStatesCheck do
  use Ecto.Migration

  # First a row an earlier build wrote between the two migrations before this one is
  # stored under its new state, as the first of them stores it: `succeeded` is
  # `completed`, `timed_out` and `ended` are `cancelled`, and `updated_at` does not
  # change. The check the migration before this one created NOT VALID refuses those
  # names in every write since, so none is left after this.
  #
  # Then the check on `runs.state` is validated: a scan that takes no lock that blocks
  # writes to `runs`. Down leaves the rows and the check as they are; the migration before
  # this one creates the wide check again.
  def up do
    execute """
    UPDATE runs SET state = CASE WHEN state = 'succeeded' THEN 'completed' ELSE 'cancelled' END
    WHERE state IN ('succeeded', 'timed_out', 'ended')
    """

    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_state_check"
  end

  def down, do: :ok
end
