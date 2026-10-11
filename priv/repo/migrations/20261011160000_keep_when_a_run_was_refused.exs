defmodule Apiary.Repo.Migrations.KeepWhenARunWasRefused do
  use Ecto.Migration

  # `refused_at`, folded from the run's `dev.qory.run.refused`: the refusal's time, for a
  # run that did not start and whose exit, if any, has not decided over it. Its starter's
  # outcome, which decides `state` and `reason`, leaves it as it is, so a run refused and
  # then given an outcome is still known as one that never started (`Apiary.Runs.Fold`).
  #
  # NULL for every existing row until it is rebuilt. A nullable column with no check: adding
  # it rewrites no row and scans nothing under the table's lock.
  def change do
    alter table(:runs) do
      add :refused_at, :utc_datetime_usec
    end
  end
end
