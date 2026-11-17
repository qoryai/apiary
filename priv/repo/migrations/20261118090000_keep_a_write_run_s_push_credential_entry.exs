defmodule Apiary.Repo.Migrations.KeepAWriteRunSPushCredentialEntry do
  use Ecto.Migration

  # The credential entry of a write run's push (`Apiary.Runs.RunCredentials`): a row of
  # `run_credentials` with `purpose` `push`, `access` `write` and the name `push-<n>`, n
  # from 1 to 9, at most one per run, as `work` has. The run's `work` entry no longer needs
  # `write` access, but the check does not require `read`: a `work` row stored with `write`
  # before this migration stays valid. `issued_apply`, the apply items of the first
  # credential sealed for an entry, is allowed on a `push` entry as on a `work` one.
  #
  # Each check is dropped and added again, and the new check scans the table as it is
  # added. Every stored row has the purpose `work` or `harness` and passes both. Rolled
  # back, the checks and the index are as before, and the rollback fails while a `push`
  # row exists.
  def up do
    entry_check("""
    purpose IN ('work', 'harness', 'push')
    AND access IN ('read', 'write')
    AND (purpose <> 'harness' OR access = 'read')
    AND (purpose <> 'push' OR access = 'write')
    AND name ~ '^(work|harness|push)-[1-9]$'
    AND starts_with(name, purpose || '-')
    """)

    issued_apply_check("purpose IN ('work', 'push')")

    create unique_index(:run_credentials, [:run_id],
             where: "purpose = 'push'",
             name: :run_credentials_push_index
           )
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM run_credentials WHERE purpose = 'push') THEN
        RAISE EXCEPTION 'Delete the run_credentials rows with purpose push, then roll back again'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    drop index(:run_credentials, [:run_id], name: :run_credentials_push_index)

    issued_apply_check("purpose = 'work'")

    entry_check("""
    purpose IN ('work', 'harness')
    AND access IN ('read', 'write')
    AND (purpose = 'work' OR access = 'read')
    AND name ~ '^(work|harness)-[1-9]$'
    AND starts_with(name, purpose || '-')
    """)
  end

  defp entry_check(check) do
    drop constraint(:run_credentials, :run_credentials_entry_check)
    create constraint(:run_credentials, :run_credentials_entry_check, check: check)
  end

  defp issued_apply_check(purposes) do
    drop constraint(:run_credentials, :run_credentials_issued_apply_check)

    create constraint(:run_credentials, :run_credentials_issued_apply_check,
             check: """
             issued_apply IS NULL OR (
               #{purposes}
               AND jsonb_typeof(issued_apply) = 'array'
               AND jsonb_array_length(issued_apply) BETWEEN 1 AND 16
               AND NOT jsonb_path_exists(issued_apply, '$[*] ? (@.type() != "object")')
             )
             """
           )
  end
end
