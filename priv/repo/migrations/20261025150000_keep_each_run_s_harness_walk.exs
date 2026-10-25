defmodule Apiary.Repo.Migrations.KeepEachRunSHarnessWalk do
  use Ecto.Migration

  # The harness walk of an explore run of the queue (`Apiary.Harnesses.RunHarness`): one
  # row per run of the queue, deleted with it. `state` is `pending` until the walk's job
  # ends, then `resolved` or `failed`; a resolved walk has its `origin` (`file`, the
  # target's harness file; `setting`, a harness document of the stacks; `none`, a run
  # with no workflow), and a failed one its `failure`, a code of at most 64 lower-case
  # letters, digits and `_` that starts with a letter, and nothing else. `document` is
  # the harness section a setting gave, as a JSON object of at most 65,536 bytes, and only
  # a setting's walk has one. `target_version` is the version of the target at which the
  # walk read its harness file, in the run contract's grammar. `pins` and
  # `harness_links` are JSON objects, one per remote source's version and one per link.
  # `failed_source` is the source a failure shows, at most 512 characters; `attempts`
  # counts the job's attempts, at most 3.
  #
  # Rolled back, the table goes.
  def change do
    create table(:run_harnesses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :dispatch_run_id,
          references(:dispatch_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :state, :text, null: false
      add :origin, :text
      add :workflow, :text
      add :stack_id, references(:stacks, type: :binary_id, on_delete: :nilify_all)

      add :owner_organisation_id,
          references(:organisations, type: :binary_id, on_delete: :nilify_all)

      add :target_version, :text
      add :document, :map
      add :pins, {:array, :map}, null: false, default: []
      add :harness_links, {:array, :map}, null: false, default: []
      add :harness_hidden, :boolean, null: false, default: false
      add :failure, :text
      add :failed_source, :text
      add :failure_rule, :map
      add :failure_adapter, :text
      add :attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_harnesses, [:dispatch_run_id])
    create index(:run_harnesses, [:stack_id])
    create index(:run_harnesses, [:owner_organisation_id])

    create constraint(:run_harnesses, :run_harnesses_state_check,
             check: """
             (state = 'pending' AND origin IS NULL AND failure IS NULL)
             OR (state = 'resolved' AND origin IN ('file', 'setting', 'none') AND failure IS NULL)
             OR (state = 'failed' AND origin IS NULL
                 AND failure ~ '^[a-z][a-z0-9_]{0,63}$')
             """
           )

    create constraint(:run_harnesses, :run_harnesses_document_check,
             check: """
             (document IS NULL) = (origin IS DISTINCT FROM 'setting')
             AND (document IS NULL OR (jsonb_typeof(document) = 'object'
                  AND octet_length(document::text) <= 65536))
             """
           )

    create constraint(:run_harnesses, :run_harnesses_values_check,
             check: """
             (target_version IS NULL OR target_version ~ '^[A-Za-z0-9._/-]{1,255}$')
             AND (workflow IS NULL OR workflow ~ '^[a-z][a-z0-9-]{0,63}$')
             AND (failed_source IS NULL OR char_length(failed_source) <= 512)
             AND (failure_adapter IS NULL OR char_length(failure_adapter) <= 64)
             AND attempts BETWEEN 0 AND 3
             """
           )
  end
end
