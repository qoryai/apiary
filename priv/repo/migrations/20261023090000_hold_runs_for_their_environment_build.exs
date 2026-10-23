defmodule Apiary.Repo.Migrations.HoldRunsForTheirEnvironmentBuild do
  use Ecto.Migration

  # A run waits for the build of its target's environment instead of a build queued ahead
  # of it (`Apiary.Environments`): a pool builds an `environment_ref` when a run needs it,
  # and no longer when a collection's `environment_ref` changes.
  #
  # - `environments`: `queued_ref`, `queued_at`, `queued_target_system`,
  #   `queued_target_path` and `retired_at` go, with their checks: nothing queues a build
  #   ahead of a run any more. `built_ref` is the `environment_ref` the prebuild that
  #   made the image was queued for, set with the image or not at all, which an image
  #   needs to serve a run: it serves one only while `built_ref` is its collection's
  #   `environment_ref`. A record that keeps an image takes its `reported_ref`, the ref
  #   its job reported, as its `built_ref`. `lost_ref` is the `environment_ref` whose build
  #   was lost once and queued again, 1 to 200 characters, or none.
  # - The waiting prebuilds: one per collection, node pool and `environment_ref`
  #   (`dispatch_runs_waiting_prebuild_ref_index`), in place of one per collection and
  #   node pool, so a build of a new `environment_ref` waits beside the one of the ref
  #   before it, and a claim ends the one whose ref is no longer its collection's.
  # - `dispatch_runs.image_requeue`: true for a run queued again because the run before
  #   it in its take in found its image missing from the registry; only a run of a work
  #   item past its first attempt has it.
  # - The end cause `build_failed` of a run of the queue and of its dispatch: a run that
  #   waited for a build that failed, or that was lost twice. Like the causes a handover
  #   ends a run for, it comes with the outcome `error` on a run that is not a prebuild.
  #
  # Adding the checks NOT VALID scans no row; the next migration validates them.
  #
  # Rolled back, the causes are as before, `image_requeue`, `built_ref` and `lost_ref`
  # go, one waiting prebuild per collection and node pool comes back, and the queued
  # columns come back, each record queued for its collection's
  # `environment_ref`, or for its `reported_ref` where the collection has none, at the
  # record's `updated_at`, for the collection's target. The roll back raises an error
  # while a run of the queue or a dispatch has the cause `build_failed`, while two
  # prebuilds of one collection and node pool wait, or while a record has neither ref.
  @ref_check "BETWEEN 1 AND 200"
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt
             provider_gone runtime_unserved key_gone model_gone secrets_not_allowed
             run_refused)
  @handover_before ~w(variables_invalid ticket_gone inputs_invalid
                      provider_gone runtime_unserved key_gone model_gone secrets_not_allowed)
  @cause "build_failed"

  def up do
    causes(@before ++ [@cause])
    outcomes(@handover_before ++ [@cause])

    drop constraint(:environments, :environments_queued_ref_check)
    drop constraint(:environments, :environments_queued_target_check)

    alter table(:environments) do
      remove :queued_ref
      remove :queued_at
      remove :queued_target_system
      remove :queued_target_path
      remove :retired_at
      add :built_ref, :text
      add :lost_ref, :text
    end

    execute "UPDATE environments SET built_ref = reported_ref WHERE image IS NOT NULL"

    execute """
    ALTER TABLE environments ADD CONSTRAINT environments_built_ref_check
    CHECK ((built_ref IS NULL) = (image IS NULL) AND
      (built_ref IS NULL OR char_length(built_ref) #{@ref_check})) NOT VALID
    """

    execute """
    ALTER TABLE environments ADD CONSTRAINT environments_lost_ref_check
    CHECK (lost_ref IS NULL OR char_length(lost_ref) #{@ref_check}) NOT VALID
    """

    create unique_index(:dispatch_runs, [:source_collection_id, :pool_id, :environment_ref],
             where: "step = 'prebuild' AND state = 'waiting'",
             name: :dispatch_runs_waiting_prebuild_ref_index
           )

    drop index(:dispatch_runs, [:source_collection_id, :pool_id],
           name: :dispatch_runs_waiting_prebuild_index
         )

    alter table(:dispatch_runs) do
      add :image_requeue, :boolean, null: false, default: false
    end

    execute """
    ALTER TABLE dispatch_runs ADD CONSTRAINT dispatch_runs_image_requeue_check
    CHECK (NOT image_requeue OR (work_item_id IS NOT NULL AND attempt > 1)) NOT VALID
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM dispatch_runs WHERE end_cause = 'build_failed')
         OR EXISTS (SELECT 1 FROM dispatches WHERE end_cause = 'build_failed') THEN
        RAISE EXCEPTION 'Delete the runs of the queue and dispatches ended build_failed, then roll back again: the causes before this migration refuse it'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1 FROM dispatch_runs
        WHERE step = 'prebuild' AND state = 'waiting'
        GROUP BY source_collection_id, pool_id HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'End all but one waiting prebuild of each collection and node pool, then roll back again: the index before this migration takes one'
          USING ERRCODE = 'unique_violation';
      END IF;
    END
    $$
    """

    create unique_index(:dispatch_runs, [:source_collection_id, :pool_id],
             where: "step = 'prebuild' AND state = 'waiting'",
             name: :dispatch_runs_waiting_prebuild_index
           )

    drop index(:dispatch_runs, [:source_collection_id, :pool_id, :environment_ref],
           name: :dispatch_runs_waiting_prebuild_ref_index
         )

    drop constraint(:dispatch_runs, :dispatch_runs_image_requeue_check)

    alter table(:dispatch_runs) do
      remove :image_requeue
    end

    drop constraint(:environments, :environments_lost_ref_check)
    drop constraint(:environments, :environments_built_ref_check)

    alter table(:environments) do
      remove :lost_ref
      remove :built_ref
      add :queued_ref, :text
      add :queued_at, :utc_datetime_usec
      add :queued_target_system, :text
      add :queued_target_path, :text
      add :retired_at, :utc_datetime_usec
    end

    execute """
    UPDATE environments AS e
    SET queued_ref = COALESCE(c.environment_ref, e.reported_ref),
        queued_at = e.updated_at,
        queued_target_system = c.target_system,
        queued_target_path = c.target_path
    FROM source_collections AS c
    WHERE c.id = e.source_collection_id
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM environments WHERE queued_ref IS NULL) THEN
        RAISE EXCEPTION 'Delete the environment records whose collection has no environment_ref and that keep no image, then roll back again: queued_ref is required before this migration'
          USING ERRCODE = 'not_null_violation';
      END IF;
    END
    $$
    """

    execute "ALTER TABLE environments ALTER COLUMN queued_ref SET NOT NULL"
    execute "ALTER TABLE environments ALTER COLUMN queued_at SET NOT NULL"

    create constraint(:environments, :environments_queued_ref_check,
             check: "char_length(queued_ref) #{@ref_check}"
           )

    create constraint(:environments, :environments_queued_target_check,
             check: "(queued_target_system IS NULL) = (queued_target_path IS NULL)"
           )

    outcomes(@handover_before)
    causes(@before)
  end

  defp causes(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    for table <- [:dispatch_runs, :dispatches] do
      drop constraint(table, :"#{table}_end_cause_check")

      create constraint(table, :"#{table}_end_cause_check",
               check: "end_cause IS NULL OR end_cause IN (#{list})"
             )
    end
  end

  # The checks of `result_outcome` that name the causes a run ends with the outcome
  # `error` for, before it started.
  defp outcomes(handover) do
    list = Enum.map_join(handover, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check)

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_check,
             check:
               "result_outcome IS NULL OR (" <>
                 "result_outcome IN ('proposal', 'questions', 'error', 'none', 'refused') " <>
                 "AND step <> 'prebuild' AND COALESCE(end_cause IN ('run_ended', " <>
                 "#{list}), false))"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check,
             check:
               "step = 'prebuild' OR NOT COALESCE(end_cause IN (#{list}), false) " <>
                 "OR COALESCE(result_outcome = 'error', false)"
           )
  end
end
