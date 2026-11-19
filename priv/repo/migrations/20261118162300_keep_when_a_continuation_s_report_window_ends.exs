defmodule Apiary.Repo.Migrations.KeepWhenAContinuationSReportWindowEnds do
  use Ecto.Migration

  # `dispatch_runs.report_wait_until`: on the run of the queue that continues a run that
  # paused with `model_key_switch`, the end of the window after the paused run's exit in
  # which Qory Apiary still records the run's model keys report. A claim takes the
  # continuation only once this time has passed (`Apiary.Dispatches`). Null for every
  # other run of the queue. Adding a column that may be empty, with no default, rewrites
  # no row.
  def change do
    alter table(:dispatch_runs) do
      add :report_wait_until, :utc_datetime_usec
    end
  end
end
