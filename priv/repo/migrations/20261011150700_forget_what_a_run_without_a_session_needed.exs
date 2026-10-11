defmodule Apiary.Repo.Migrations.ForgetWhatARunWithoutASessionNeeded do
  use Ecto.Migration

  # A run is opened by a Forager session alone, and its clock offset is its heartbeats'.
  # What only a run opened with no session needed goes:
  #
  # - `opened_by`, what opened the run, and its check `runs_opened_by_check`;
  # - `registration_time`, the registration's `time`, and its check
  #   `runs_registration_time_check`;
  # - `attach_time`, the attach's `time`. `runs_attach_check` is re-created without it,
  #   NOT VALID, so the change scans no row under a lock that blocks writes to `runs`; the
  #   next migration validates it.
  #
  # Down puts the columns and the checks back, each column empty but `attach_time`, which
  # takes `attached_at` so the old check holds.
  def up do
    drop constraint(:runs, :runs_opened_by_check)
    drop constraint(:runs, :runs_registration_time_check)
    drop constraint(:runs, :runs_attach_check)

    alter table(:runs) do
      remove :opened_by
      remove :registration_time
      remove :attach_time
    end

    create constraint(:runs, :runs_attach_check,
             check:
               "(attached_at IS NULL AND attach_interval_seconds IS NULL AND " <>
                 "attach_answer_digest IS NULL) OR " <>
                 "(attached_at IS NOT NULL AND attach_interval_seconds BETWEEN 1 AND 300 AND " <>
                 "attach_answer_digest IS NOT NULL AND run_key_payload IS NOT NULL)",
             validate: false
           )
  end

  def down do
    drop constraint(:runs, :runs_attach_check)

    alter table(:runs) do
      add :opened_by, :text
      add :registration_time, :utc_datetime_usec
      add :attach_time, :utc_datetime_usec
    end

    execute "UPDATE runs SET attach_time = attached_at WHERE attached_at IS NOT NULL"

    create constraint(:runs, :runs_opened_by_check, check: "opened_by IN ('session', 'gateway')")

    create constraint(:runs, :runs_registration_time_check,
             check: "registration_time IS NULL OR registered_at IS NOT NULL"
           )

    create constraint(:runs, :runs_attach_check,
             check:
               "(attached_at IS NULL AND attach_time IS NULL AND " <>
                 "attach_interval_seconds IS NULL AND attach_answer_digest IS NULL) OR " <>
                 "(attached_at IS NOT NULL AND attach_time IS NOT NULL AND " <>
                 "attach_interval_seconds BETWEEN 1 AND 300 AND " <>
                 "attach_answer_digest IS NOT NULL AND run_key_payload IS NOT NULL)"
           )
  end
end
