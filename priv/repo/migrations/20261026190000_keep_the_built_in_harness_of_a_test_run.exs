defmodule Apiary.Repo.Migrations.KeepTheBuiltInHarnessOfATestRun do
  use Ecto.Migration

  # The harness walk of a test work item's run (`Apiary.Harnesses.Builtin`): a resolved
  # walk may have the origin `builtin`, with its document, as `setting` has one. A
  # `builtin` walk has no stack, owner or link, is not hidden, and reads: its access level
  # is `read`. Every row before this migration has another origin, so each check holds.
  #
  # Rolled back, the checks are as before, and a `builtin` row fails them.
  def up do
    drop constraint(:run_harnesses, :run_harnesses_state_check)
    drop constraint(:run_harnesses, :run_harnesses_document_check)

    create constraint(:run_harnesses, :run_harnesses_state_check,
             check: """
             (state = 'pending' AND origin IS NULL AND failure IS NULL)
             OR (state = 'resolved' AND origin IN ('file', 'setting', 'builtin', 'none')
                 AND failure IS NULL)
             OR (state = 'failed' AND origin IS NULL
                 AND failure ~ '^[a-z][a-z0-9_]{0,63}$')
             """
           )

    create constraint(:run_harnesses, :run_harnesses_document_check,
             check: """
             (document IS NULL) = (origin IS NULL OR origin NOT IN ('setting', 'builtin'))
             AND (document IS NULL OR (jsonb_typeof(document) = 'object'
                  AND octet_length(document::text) <= 65536))
             """
           )

    create constraint(:run_harnesses, :run_harnesses_builtin_check,
             check: """
             origin IS DISTINCT FROM 'builtin'
             OR (access_level = 'read' AND stack_id IS NULL AND owner_organisation_id IS NULL
                 AND cardinality(harness_links) = 0 AND NOT harness_hidden)
             """
           )
  end

  def down do
    drop constraint(:run_harnesses, :run_harnesses_builtin_check)
    drop constraint(:run_harnesses, :run_harnesses_document_check)
    drop constraint(:run_harnesses, :run_harnesses_state_check)

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
  end
end
