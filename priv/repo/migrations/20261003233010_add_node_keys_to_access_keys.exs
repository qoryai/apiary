defmodule Apiary.Repo.Migrations.AddNodeKeysToAccessKeys do
  use Ecto.Migration

  # Access keys of nodes (`Apiary.AccessKeys`): one Ed25519 public key each, on a node or a
  # node pool of the workspace, beside today's keys with a secret the server made, which
  # stay as they are until the contract that replaces them is in.
  #
  # `access_keys` gains a node's key's columns. A row is one or the other: today's key has
  # its secret and no public key, a node's key its public key and no secret, so the secret
  # is NULL now for a node's key. A row with a public key has a node, by the composite key
  # within its workspace (today's keys have none), a time it was received, how it arrived
  # (`code` or `paste`) and its integrity code (`Apiary.Integrity`). The node, the public
  # key, the stored-secrets flag and how the key arrived are fixed when the row is made: the
  # trigger refuses an UPDATE that changes them, whatever wrote it. A label is unique among
  # a node's keys in use, and today's keys keep theirs unique in the workspace.
  #
  # `access_key_enrolment_codes` holds the codes an owner or an admin makes for a node: the
  # code's SHA-256 only, the settings the key it brings gets, when it expires, and when it
  # was used or cancelled, with its integrity code.
  #
  # `access_key_public_keys` is the ledger: one public key, one access key, ever, on the
  # instance. It has no foreign key and no organisation, so it outlives the deletion of the
  # workspace and the organisation; a retired key's row stays as a tombstone.
  def up do
    create table(:access_key_enrolment_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :node_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :code_sha256, :binary, null: false
      add :allow_secrets, :boolean, null: false, default: false
      add :label_hint, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      add :used_by_key_id, :string
      add :public_key, :binary
      add :cancelled_at, :utc_datetime_usec
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :integrity_code, :binary, null: false
      add :integrity_key_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_key_enrolment_codes, [:code_sha256])
    create unique_index(:access_key_enrolment_codes, [:id, :workspace_id])
    create index(:access_key_enrolment_codes, [:organisation_id, :workspace_id])
    create index(:access_key_enrolment_codes, [:node_id])
    create index(:access_key_enrolment_codes, [:created_by_id])

    create constraint(:access_key_enrolment_codes, :access_key_enrolment_codes_sha256_check,
             check: "octet_length(code_sha256) = 32"
           )

    create constraint(:access_key_enrolment_codes, :access_key_enrolment_codes_public_key_check,
             check: "public_key IS NULL OR octet_length(public_key) = 32"
           )

    create constraint(:access_key_enrolment_codes, :access_key_enrolment_codes_used_check,
             check: "(used_at IS NULL) = (used_by_key_id IS NULL)"
           )

    create constraint(:access_key_enrolment_codes, :access_key_enrolment_codes_label_hint_check,
             check: "label_hint IS NULL OR char_length(label_hint) BETWEEN 1 AND 64"
           )

    alter table(:access_keys) do
      modify :secret_primary, :binary, null: true, from: {:binary, null: false}

      add :node_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: :nothing
          )

      add :public_key, :binary
      add :received_at, :utc_datetime_usec
      add :approved_at, :utc_datetime_usec
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :allow_secrets, :boolean, null: false, default: false
      add :rate, :integer
      add :burst, :integer
      add :arrived_by, :string

      add :enrolment_code_id,
          references(:access_key_enrolment_codes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: :nothing
          )

      add :revoked_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :integrity_code, :binary
      add :integrity_key_id, :string
      add :last_pending_at, :utc_datetime_usec
    end

    create index(:access_keys, [:node_id])
    create index(:access_keys, [:approved_by_id])
    create index(:access_keys, [:revoked_by_id])
    create index(:access_keys, [:enrolment_code_id])

    drop index(:access_keys, [:organisation_id, :workspace_id, :label],
           name: :access_keys_active_label_index
         )

    create unique_index(:access_keys, [:organisation_id, :workspace_id, :label],
             where: "revoked_at IS NULL AND node_id IS NULL",
             name: :access_keys_active_label_index
           )

    create unique_index(:access_keys, [:node_id, :label],
             where: "revoked_at IS NULL AND node_id IS NOT NULL",
             name: :access_keys_node_label_index
           )

    create constraint(:access_keys, :access_keys_credential_check,
             check: "(public_key IS NULL) <> (secret_primary IS NULL)"
           )

    create constraint(:access_keys, :access_keys_node_key_check,
             check:
               "public_key IS NULL OR (node_id IS NOT NULL AND octet_length(public_key) = 32 " <>
                 "AND received_at IS NOT NULL AND arrived_by IS NOT NULL " <>
                 "AND integrity_code IS NOT NULL AND integrity_key_id IS NOT NULL)"
           )

    create constraint(:access_keys, :access_keys_arrived_by_check,
             check:
               "arrived_by IS NULL OR arrived_by = 'paste' OR " <>
                 "(arrived_by = 'code' AND enrolment_code_id IS NOT NULL)"
           )

    create constraint(:access_keys, :access_keys_approval_check,
             check: "approved_by_id IS NULL OR approved_at IS NOT NULL"
           )

    create constraint(:access_keys, :access_keys_revocation_check,
             check: "revoked_by_id IS NULL OR revoked_at IS NOT NULL"
           )

    create constraint(:access_keys, :access_keys_rate_check,
             check: "(rate IS NULL OR rate > 0) AND (burst IS NULL OR burst > 0)"
           )

    execute("""
    CREATE FUNCTION access_keys_fixed_at_insert() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.node_id IS DISTINCT FROM OLD.node_id
         OR NEW.public_key IS DISTINCT FROM OLD.public_key
         OR NEW.allow_secrets IS DISTINCT FROM OLD.allow_secrets
         OR NEW.arrived_by IS DISTINCT FROM OLD.arrived_by
         OR NEW.enrolment_code_id IS DISTINCT FROM OLD.enrolment_code_id THEN
        RAISE EXCEPTION 'an access key''s node, public key, stored-secrets flag and arrival are fixed when it is made'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'access_keys_fixed_at_insert';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER access_keys_fixed_at_insert
    BEFORE UPDATE OF node_id, public_key, allow_secrets, arrived_by, enrolment_code_id
    ON access_keys
    FOR EACH ROW EXECUTE FUNCTION access_keys_fixed_at_insert()
    """)

    create table(:access_key_public_keys, primary_key: false) do
      add :public_key, :binary, primary_key: true
      add :key_id, :string, null: false
      add :state, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :retired_at, :utc_datetime_usec
      add :retired_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_key_public_keys, [:key_id])

    create constraint(:access_key_public_keys, :access_key_public_keys_public_key_check,
             check: "octet_length(public_key) = 32"
           )

    create constraint(:access_key_public_keys, :access_key_public_keys_state_check,
             check:
               "(state IN ('current', 'pending') AND retired_at IS NULL AND " <>
                 "retired_reason IS NULL) OR " <>
                 "(state = 'tombstone' AND retired_at IS NOT NULL AND retired_reason IN " <>
                 "('revoked', 'rejected', 'expired', 'node_deleted', 'workspace_deleted'))"
           )
  end

  # Rolling back drops what the keys of nodes are made of, so it drops those keys first:
  # a row without a secret cannot stay once the secret is required again.
  def down do
    drop table(:access_key_public_keys)

    execute("DROP TRIGGER access_keys_fixed_at_insert ON access_keys")
    execute("DROP FUNCTION access_keys_fixed_at_insert()")

    execute("DELETE FROM access_keys WHERE public_key IS NOT NULL")

    drop constraint(:access_keys, :access_keys_rate_check)
    drop constraint(:access_keys, :access_keys_revocation_check)
    drop constraint(:access_keys, :access_keys_approval_check)
    drop constraint(:access_keys, :access_keys_arrived_by_check)
    drop constraint(:access_keys, :access_keys_node_key_check)
    drop constraint(:access_keys, :access_keys_credential_check)

    drop index(:access_keys, [:node_id, :label], name: :access_keys_node_label_index)

    drop index(:access_keys, [:organisation_id, :workspace_id, :label],
           name: :access_keys_active_label_index
         )

    create unique_index(:access_keys, [:organisation_id, :workspace_id, :label],
             where: "revoked_at IS NULL",
             name: :access_keys_active_label_index
           )

    drop index(:access_keys, [:enrolment_code_id])
    drop index(:access_keys, [:revoked_by_id])
    drop index(:access_keys, [:approved_by_id])
    drop index(:access_keys, [:node_id])

    alter table(:access_keys) do
      remove :last_pending_at
      remove :integrity_key_id
      remove :integrity_code
      remove :revoked_by_id
      remove :enrolment_code_id
      remove :arrived_by
      remove :burst
      remove :rate
      remove :allow_secrets
      remove :approved_by_id
      remove :approved_at
      remove :received_at
      remove :public_key
      remove :node_id
      modify :secret_primary, :binary, null: false, from: {:binary, null: true}
    end

    drop table(:access_key_enrolment_codes)
  end
end
