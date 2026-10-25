defmodule Apiary.Repo.Migrations.KeepInstanceSecrets do
  use Ecto.Migration

  # The instance's secrets (`Apiary.Secrets.Instance`): secrets of no organisation and no
  # workspace, each belonging to one adapter, which no query of an organisation's or a
  # workspace's secrets reads.
  #
  # - `instance_secrets`: a secret, with its public id (`sec_`), its adapter (a node of
  #   kind `adapter`, `instance_secrets_adapter_check`), its name, unique for its adapter
  #   whatever its case, and its revision, 1 when it is made and one more at each
  #   replacement of its values.
  # - `instance_secret_values`: its values, each with its value id, unique in its secret,
  #   encrypted under the instance's data key (`instance_data_keys`): the nonce, then the
  #   ciphertext with its 16-byte tag.
  # - `nodes.secret_store` and `nodes.secret_entry`: where an adapter's secret is, both set
  #   or both NULL, and set on an adapter only. The store is `builtin`, the instance's
  #   built-in store, and the entry is the secret's public id there. NULL on every row
  #   there already: adding a column with no default rewrites no row.
  #
  # The tables and columns start empty; this migration moves no row.
  @value_id "'^[a-z0-9][a-z0-9_.-]{0,63}$'"

  def up do
    create table(:instance_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false

      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :text, null: false
      add :revision, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instance_secrets, [:public_id])
    create unique_index(:instance_secrets, [:adapter_id, "lower(name)"])

    create constraint(:instance_secrets, :instance_secrets_public_id_format,
             check: "public_id ~ '^sec_[0-9a-hjkmnp-tv-z]{16}$'"
           )

    create constraint(:instance_secrets, :instance_secrets_name_format,
             check: "name ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$'"
           )

    create constraint(:instance_secrets, :instance_secrets_revision_check, check: "revision >= 1")

    execute """
    CREATE FUNCTION instance_secrets_adapter_check() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND NEW.adapter_id IS NOT DISTINCT FROM OLD.adapter_id THEN
        RETURN NEW;
      END IF;

      PERFORM 1 FROM nodes
        WHERE id = NEW.adapter_id AND kind = 'adapter' AND organisation_id IS NULL
          AND workspace_id IS NULL;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'an instance secret belongs to an adapter'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_secrets_adapter_check';
      END IF;

      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER instance_secrets_adapter_check
    BEFORE INSERT OR UPDATE OF adapter_id ON instance_secrets
    FOR EACH ROW EXECUTE FUNCTION instance_secrets_adapter_check()
    """

    create table(:instance_secret_values, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :secret_id, references(:instance_secrets, type: :binary_id, on_delete: :delete_all),
        null: false

      add :value_id, :text, null: false
      add :nonce, :binary, null: false
      add :ciphertext, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:instance_secret_values, [:secret_id, :value_id])

    create constraint(:instance_secret_values, :instance_secret_values_value_id_format,
             check: "value_id ~ #{@value_id}"
           )

    create constraint(:instance_secret_values, :instance_secret_values_nonce_check,
             check: "octet_length(nonce) = 12"
           )

    create constraint(:instance_secret_values, :instance_secret_values_ciphertext_check,
             check: "octet_length(ciphertext) BETWEEN 17 AND 16400"
           )

    alter table(:nodes) do
      add :secret_store, :text
      add :secret_entry, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_secret_reference_check CHECK (
      (secret_store IS NULL AND secret_entry IS NULL) OR (
        kind = 'adapter' AND
        secret_store IS NOT NULL AND secret_entry IS NOT NULL AND
        secret_store IN ('builtin') AND
        char_length(secret_entry) BETWEEN 1 AND 256 AND
        secret_entry ~ '^[ -~]+$'
      )
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_secret_reference_check"

    alter table(:nodes) do
      remove :secret_store
      remove :secret_entry
    end

    drop table(:instance_secret_values)
    execute "DROP TRIGGER instance_secrets_adapter_check ON instance_secrets"
    execute "DROP FUNCTION instance_secrets_adapter_check()"
    drop table(:instance_secrets)
  end
end
