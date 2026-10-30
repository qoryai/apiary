defmodule Apiary.Repo.Migrations.KeepARunThatFailedToStart do
  use Ecto.Migration

  # A run registered at a node pool's claim whose machine never started it is kept, failed,
  # where it was deleted before (`Apiary.Dispatches.Handover.fail_start/3`):
  #
  # - `runs.start_failure`: why, one of `machine_not_made` (the pool's starter released
  #   the dispatch), `lease_lapsed` (the dispatch's lease lapsed before its handover) and
  #   `machine_stopped` (the machine's log arrived before it redeemed the run code); and
  #   `runs.start_failed_at`, when. Set together, nil for every other run. Not folded: a
  #   rebuild keeps them, and the fold reads them (`Apiary.Runs.Fold.settle/1`).
  # - `runs.dispatch_id`: the dispatch whose claim registered the run, set when its start
  #   failed; nil for every other run, and once the dispatch is deleted.
  # - `dispatches.release_reason`: the starter's reason of a release, 1 to 200
  #   characters as the provisioner contract's `release.schema.json` has it; nil for a
  #   dispatch that was not released.
  # - `runs_run_settings_check`: a run released or lapsed leaves its run of the queue
  #   (`dispatch_run_id` nil) and keeps its run settings, so the settings need a run of
  #   the queue or a start failure.
  #
  # Adding columns that may be empty, with no default, rewrites no row.
  @settings "jsonb_typeof(run_settings) = 'object' AND octet_length(run_settings::text) <= 65536"

  def up do
    alter table(:runs) do
      add :start_failure, :text
      add :start_failed_at, :utc_datetime_usec
      add :dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:runs, :runs_start_failure_check,
             check:
               "start_failure IS NULL OR " <>
                 "start_failure IN ('machine_not_made', 'lease_lapsed', 'machine_stopped')"
           )

    create constraint(:runs, :runs_start_failed_check,
             check: "(start_failure IS NULL) = (start_failed_at IS NULL)"
           )

    drop_if_exists constraint(:runs, :runs_run_settings_check)

    create constraint(:runs, :runs_run_settings_check,
             check:
               "run_settings IS NULL OR (#{@settings} " <>
                 "AND (dispatch_run_id IS NOT NULL OR start_failure IS NOT NULL))"
           )

    alter table(:dispatches) do
      add :release_reason, :text
    end

    create constraint(:dispatches, :dispatches_release_reason_check,
             check: "release_reason IS NULL OR char_length(release_reason) BETWEEN 1 AND 200"
           )
  end

  # Rolled back, a run whose start failed has no run of the queue to keep its settings
  # by: they are cleared, with the provider fields `runs_provider_check` ties to them.
  def down do
    drop constraint(:dispatches, :dispatches_release_reason_check)

    alter table(:dispatches) do
      remove :release_reason
    end

    execute("""
    UPDATE runs SET run_settings = NULL, provider_connection_id = NULL,
      provider_secret_id = NULL, provider_value_id = NULL, provider_chain = NULL,
      provider_api = NULL
    WHERE run_settings IS NOT NULL AND dispatch_run_id IS NULL
    """)

    drop_if_exists constraint(:runs, :runs_run_settings_check)

    create constraint(:runs, :runs_run_settings_check,
             check: "run_settings IS NULL OR (#{@settings} AND dispatch_run_id IS NOT NULL)"
           )

    drop constraint(:runs, :runs_start_failed_check)
    drop constraint(:runs, :runs_start_failure_check)

    alter table(:runs) do
      remove :dispatch_id
      remove :start_failed_at
      remove :start_failure
    end
  end
end
