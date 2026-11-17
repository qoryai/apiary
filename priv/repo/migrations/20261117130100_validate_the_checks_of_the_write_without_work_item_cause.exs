defmodule Apiary.Repo.Migrations.ValidateTheChecksOfTheWriteWithoutWorkItemCause do
  use Ecto.Migration

  # Validates the checks that the migration before this one added NOT VALID: scans that
  # take no lock that blocks writes to `dispatch_runs` and `dispatches`. Every row passes
  # them, as the checks before took fewer causes. Down leaves the checks as they are; the
  # migration before this one replaces them.
  def up do
    for {table, check} <- [
          dispatch_runs: "dispatch_runs_end_cause_check",
          dispatch_runs: "dispatch_runs_result_outcome_check",
          dispatch_runs: "dispatch_runs_result_outcome_error_check",
          dispatches: "dispatches_end_cause_check"
        ] do
      execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{check}"
    end
  end

  def down, do: :ok
end
