defmodule Apiary.Repo.Migrations.KeepHowAHandedOverRunEnded do
  use Ecto.Migration

  # How a run that a workspace's queue handed over (`runs.dispatch_run_id`) ends without
  # its outcome or its exit:
  #
  # - `runs.released_at`: when its starter released it after the handover. The run reads
  #   as cancelled, with the reason `released`, until its starter's outcome decides
  #   (`Apiary.Runs.Fold`); no outcome is recorded for it.
  # - `runs.backstop_at`: set at its attach, the attach and its step's limit
  #   (`Apiary.Dispatches.backstop_seconds/1`). A run with neither an outcome nor an exit
  #   by then is lost (`Apiary.Runs.Liveness`), and no heartbeat brings it back.
  #
  # Both are nil for every other run, and neither is folded: a rebuild keeps them. The
  # partial index holds the runs of the queues that are handed over, the few the lost-run
  # check looks at on every tick. Adding columns that may be empty, with no default,
  # rewrites no row.
  def change do
    alter table(:runs) do
      add :released_at, :utc_datetime_usec
      add :backstop_at, :utc_datetime_usec
    end

    create index(:dispatch_runs, [:id],
             where: "state = 'handed_over'",
             name: :dispatch_runs_handed_over_index
           )
  end
end
