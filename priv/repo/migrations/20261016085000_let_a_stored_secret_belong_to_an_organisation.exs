defmodule Apiary.Repo.Migrations.LetAStoredSecretBelongToAnOrganisation do
  use Ecto.Migration

  # A stored secret (`Apiary.Secrets`) belongs to a workspace, as before, or to an
  # organisation: `secrets.workspace_id` NULL. A workspace's secrets, their values and its
  # data key stay as they are, byte for byte: this migration moves no row, encrypts no
  # value again and wraps no data key again.
  #
  # - `organisation_data_keys`: an organisation's data key, 32 random bytes, kept only
  #   wrapped under the instance's values key, as a workspace's is (`workspace_data_keys`);
  #   one per organisation (unique on `organisation_id`), made with its first secret.
  # - `secrets`: `workspace_id` may be NULL, and the key to `workspaces` is `MATCH SIMPLE`.
  #   A name is unique in its workspace whatever its case, as before
  #   (`secrets_name_index`), and an organisation's secrets' names are unique among them
  #   (`secrets_organisation_name_index`); a workspace's secret may have the name of its
  #   organisation's.
  # - `secret_values`: `workspace_id` and `data_key_id` may be NULL, and a value of an
  #   organisation's secret names its organisation's data key (`organisation_data_key_id`).
  #   A value's secret is of its organisation (`MATCH FULL`) and of its workspace, when it
  #   has one; a value has exactly one data key, its workspace's or its organisation's
  #   (`secret_values_one_key`). `secret_value_scope_matches` refuses a value without a
  #   workspace whose secret has one, and a secret's change of level while it has values.
  #
  # The checks and keys on the rows already there are added NOT VALID, so adding them scans
  # no row under a lock that blocks writes; the next migration validates them.
  #
  # `down` refuses while an organisation's secret, value or data key is there, rather than
  # delete them, then puts the tables back as they were.

  def up do
    create table(:organisation_data_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :wrapped_key, :binary, null: false
      add :wrapping_key_id, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:organisation_data_keys, :organisation_data_keys_wrapped_key_check,
             check: "octet_length(wrapped_key) = 60"
           )

    create unique_index(:organisation_data_keys, [:organisation_id])
    create unique_index(:organisation_data_keys, [:id, :organisation_id])

    # secrets
    execute "ALTER TABLE secrets ALTER COLUMN workspace_id DROP NOT NULL"
    execute "ALTER TABLE secrets DROP CONSTRAINT secrets_workspace_id_fkey"

    execute """
    ALTER TABLE secrets ADD CONSTRAINT secrets_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    create unique_index(:secrets, [:id, :organisation_id])

    create unique_index(:secrets, [:organisation_id, "lower(name)"],
             where: "workspace_id IS NULL",
             name: :secrets_organisation_name_index
           )

    # secret_values
    execute "ALTER TABLE secret_values ALTER COLUMN workspace_id DROP NOT NULL"
    execute "ALTER TABLE secret_values ALTER COLUMN data_key_id DROP NOT NULL"

    alter table(:secret_values) do
      add :organisation_data_key_id, :binary_id
    end

    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_workspace_id_fkey"
    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_secret_id_fkey"

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_secret_id_fkey
      FOREIGN KEY (secret_id, workspace_id) REFERENCES secrets (id, workspace_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_secret_organisation_fkey
      FOREIGN KEY (secret_id, organisation_id) REFERENCES secrets (id, organisation_id)
      MATCH FULL ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_organisation_data_key_id_fkey
      FOREIGN KEY (organisation_data_key_id, organisation_id)
      REFERENCES organisation_data_keys (id, organisation_id)
      MATCH SIMPLE ON DELETE NO ACTION NOT VALID
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_one_key CHECK (
      (workspace_id IS NOT NULL AND data_key_id IS NOT NULL
        AND organisation_data_key_id IS NULL)
      OR (workspace_id IS NULL AND data_key_id IS NULL
        AND organisation_data_key_id IS NOT NULL)
    ) NOT VALID
    """

    create index(:secret_values, [:organisation_data_key_id])

    # A value without a workspace is of a secret without one; a value with one is of a
    # secret of that workspace by `secret_values_secret_id_fkey`.
    execute """
    CREATE FUNCTION secret_value_scope_matches() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.workspace_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM secrets WHERE id = NEW.secret_id AND workspace_id IS NULL
      ) THEN
        RAISE EXCEPTION 'a value without a workspace is of a secret without one'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secret_value_scope_matches';
      END IF;
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER secret_values_scope_matches
    BEFORE INSERT OR UPDATE OF secret_id, workspace_id ON secret_values
    FOR EACH ROW EXECUTE FUNCTION secret_value_scope_matches()
    """

    # A secret's level is the level of its values: a secret with values keeps its workspace,
    # or keeps none.
    execute """
    CREATE FUNCTION secret_scope_matches_values() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM secret_values
        WHERE secret_id = NEW.id AND workspace_id IS DISTINCT FROM NEW.workspace_id
      ) THEN
        RAISE EXCEPTION 'a secret with values keeps their level'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'secret_value_scope_matches';
      END IF;
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER secrets_scope_matches_values
    BEFORE UPDATE OF workspace_id ON secrets
    FOR EACH ROW EXECUTE FUNCTION secret_scope_matches_values()
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM secrets WHERE workspace_id IS NULL)
         OR EXISTS (SELECT 1 FROM secret_values WHERE workspace_id IS NULL)
         OR EXISTS (SELECT 1 FROM organisation_data_keys) THEN
        RAISE EXCEPTION 'secrets holds secrets of organisations: delete them and organisation_data_keys before rolling this back';
      END IF;
    END
    $$
    """

    execute "DROP TRIGGER secrets_scope_matches_values ON secrets"
    execute "DROP FUNCTION secret_scope_matches_values()"
    execute "DROP TRIGGER secret_values_scope_matches ON secret_values"
    execute "DROP FUNCTION secret_value_scope_matches()"

    drop index(:secret_values, [:organisation_data_key_id])

    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_one_key"

    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_organisation_data_key_id_fkey"

    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_secret_organisation_fkey"
    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_secret_id_fkey"
    execute "ALTER TABLE secret_values DROP CONSTRAINT secret_values_workspace_id_fkey"

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_secret_id_fkey
      FOREIGN KEY (secret_id, workspace_id) REFERENCES secrets (id, workspace_id)
      MATCH FULL ON DELETE CASCADE
    """

    alter table(:secret_values) do
      remove :organisation_data_key_id
    end

    execute "ALTER TABLE secret_values ALTER COLUMN data_key_id SET NOT NULL"
    execute "ALTER TABLE secret_values ALTER COLUMN workspace_id SET NOT NULL"

    drop index(:secrets, [:organisation_id, "lower(name)"],
           name: :secrets_organisation_name_index
         )

    drop index(:secrets, [:id, :organisation_id])

    execute "ALTER TABLE secrets DROP CONSTRAINT secrets_workspace_id_fkey"

    execute """
    ALTER TABLE secrets ADD CONSTRAINT secrets_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute "ALTER TABLE secrets ALTER COLUMN workspace_id SET NOT NULL"

    drop table(:organisation_data_keys)
  end
end
