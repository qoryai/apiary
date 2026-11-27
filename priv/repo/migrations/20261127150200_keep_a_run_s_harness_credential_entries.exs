defmodule Apiary.Repo.Migrations.KeepARunSHarnessCredentialEntries do
  use Ecto.Migration

  # The harness entries of a run (`Apiary.Runs.RunCredentials`, `harness-<n>`): a row of
  # `run_credentials` with `purpose` `harness` and `access` `read`, which the entry check
  # already allows. A harness entry comes from a grant, which may be of the instance's
  # organisation when an assignment lets the run use it (`Apiary.Harnesses`), so its
  # connection is not one of the run's organisation:
  #
  #   * `grant_id`, the grant the entry's credential is issued under, set on a `harness`
  #     row and NULL on every other; `connection_id` NULL on a `harness` row and set on
  #     every other (`run_credentials_link_check`);
  #   * the key of `connection_id` to the run's organisation's connection is MATCH SIMPLE,
  #     so a NULL `connection_id` is allowed beside the row's `organisation_id`; a row
  #     with a connection still has one of the run's organisation;
  #   * `issued_apply` is allowed on a `harness` row as on a `work` or `push` one.
  #
  # The new key and the new check are added NOT VALID, so adding them takes no scan under
  # the lock; the next migration validates them. Every row there before is a `work` or
  # `push` row with a connection, which passes both. Rolled back, the table is as before,
  # and the rollback fails while a `harness` row exists.
  def up do
    alter table(:run_credentials) do
      add :grant_id, references(:adapter_grants, type: :binary_id, on_delete: :nothing)
    end

    execute "ALTER TABLE run_credentials ALTER COLUMN connection_id DROP NOT NULL"

    create index(:run_credentials, [:grant_id], where: "grant_id IS NOT NULL")

    execute "ALTER TABLE run_credentials DROP CONSTRAINT run_credentials_connection_id_fkey"

    execute """
    ALTER TABLE run_credentials ADD CONSTRAINT run_credentials_connection_id_fkey
    FOREIGN KEY (connection_id, organisation_id)
    REFERENCES adapter_connections (id, organisation_id) MATCH SIMPLE NOT VALID
    """

    execute """
    ALTER TABLE run_credentials ADD CONSTRAINT run_credentials_link_check CHECK (
      (purpose = 'harness' AND connection_id IS NULL AND grant_id IS NOT NULL)
      OR (purpose <> 'harness' AND connection_id IS NOT NULL AND grant_id IS NULL)
    ) NOT VALID
    """

    issued_apply_check("purpose IN ('work', 'push', 'harness')")
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM run_credentials WHERE purpose = 'harness') THEN
        RAISE EXCEPTION 'Delete the run_credentials rows with purpose harness, then roll back again'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    issued_apply_check("purpose IN ('work', 'push')")

    execute "ALTER TABLE run_credentials DROP CONSTRAINT run_credentials_link_check"
    execute "ALTER TABLE run_credentials DROP CONSTRAINT run_credentials_connection_id_fkey"

    execute """
    ALTER TABLE run_credentials ADD CONSTRAINT run_credentials_connection_id_fkey
    FOREIGN KEY (connection_id, organisation_id)
    REFERENCES adapter_connections (id, organisation_id) MATCH FULL
    """

    drop index(:run_credentials, [:grant_id], where: "grant_id IS NOT NULL")

    alter table(:run_credentials) do
      remove :grant_id
    end

    execute "ALTER TABLE run_credentials ALTER COLUMN connection_id SET NOT NULL"
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
