defmodule Apiary.Repo.Migrations.KeepWhenAPrebuildTookItsRef do
  use Ecto.Migration

  # `environment_ref_at` on a run of the queue (`Apiary.Dispatches.DispatchRun`): when a
  # prebuild took the `environment_ref` it builds. It is set when the prebuild is queued,
  # and again whenever its `environment_ref` changes: a change of the collection's
  # `environment_ref` while it waits (`Apiary.Dispatches.queue_prebuild/3`), and a wait
  # again that takes its environment record's `queued_ref` (`Apiary.Dispatches.Slots`).
  # `queued_at`, which orders the queue, stays as it was then, so it does not say how new
  # the ref is. An environment record keeps the one of the prebuild that made its image
  # (`built_queued_at`) to compare, so an older build never replaces a newer one.
  #
  # A run with an `environment_ref` has one, and a run without has none. Up gives every
  # prebuild its `queued_at`. Down drops the column.

  def up do
    alter table(:dispatch_runs) do
      add :environment_ref_at, :utc_datetime_usec
    end

    execute """
    UPDATE dispatch_runs SET environment_ref_at = queued_at WHERE environment_ref IS NOT NULL
    """

    create constraint(:dispatch_runs, :dispatch_runs_environment_ref_at_check,
             check: "(environment_ref IS NULL) = (environment_ref_at IS NULL)"
           )
  end

  def down do
    drop constraint(:dispatch_runs, :dispatch_runs_environment_ref_at_check)

    alter table(:dispatch_runs) do
      remove :environment_ref_at
    end
  end
end
