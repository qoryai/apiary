defmodule Apiary.Repo.Migrations.RecordExploreRunsAndFailedHarnessReads do
  use Ecto.Migration

  # `dispatch_runs.explore`: whether a run of the queue is a run of Explore, as the run
  # was queued (`Apiary.Stages.explore_run?/1`), so the answer does not wait on the stored
  # files of the Qory harness; NULL where it was not known then, and for every run queued
  # before this migration. A claim or the stage runner sets it on a run with NULL, from
  # the stored files, before it takes or reads the run (`Apiary.Stages.known_explore/1`).
  #
  # `run_harnesses.ref_kind`: whether the `ref` of a walk's base is a branch, a tag or a
  # commit, as the harness settings chose it (`Apiary.Stacks.Resolution`), so the claim
  # reads that kind of ref alone; NULL where the walk did not record one. A check keeps
  # it to those three.
  #
  # `run_harnesses.read_failed_at`: when a claim's read of the run's harness first timed
  # out, met the host's limit on reads or a server error
  # (`Apiary.Dispatches.HarnessReads`); the run stays queued, and ends once the reads
  # still fail 10 minutes after that. NULL for none, and again after a read that succeeds.
  def change do
    alter table(:dispatch_runs) do
      add :explore, :boolean
    end

    alter table(:run_harnesses) do
      add :ref_kind, :string
      add :read_failed_at, :utc_datetime_usec
    end

    create constraint(:run_harnesses, :run_harnesses_ref_kind_check,
             check: "ref_kind IS NULL OR ref_kind IN ('branch', 'tag', 'commit')"
           )
  end
end
