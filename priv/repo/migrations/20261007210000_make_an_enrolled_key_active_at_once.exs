defmodule Apiary.Repo.Migrations.MakeAnEnrolledKeyActiveAtOnce do
  use Ecto.Migration

  # A node's key no longer awaits approval: the enrolment code an owner or an admin made is
  # the approval, so a key is active from the moment it is made until it is revoked
  # (`Apiary.AccessKeys`). The approval's columns go, with their check and index, and the
  # ledger of public keys loses its `pending` state and its `rejected` reason.
  #
  # No existing key can stay. A key's integrity code covered its approval
  # (`Apiary.AccessKeys.AccessKey.integrity_fields/1`, version 1); without those fields no
  # existing code verifies, and SQL cannot write a new one, since the key it is made under
  # is not the database's. So every node's key is deleted, with its rows of `deliveries`,
  # whose foreign key would refuse the deletion (`on_delete: :nothing`); a run and an
  # instance lose the key they name (`on_delete: :nilify_all`) and keep everything else;
  # an audit entry names its key by id, without a foreign key, and stays as it is. Every
  # enrolment code goes too: a used one names a key that is gone, and an outstanding one
  # was made for a key that would await approval, and its integrity code covers its
  # cancellation, which SQL cannot write either. Machines enrol again.
  #
  # Every public key the ledger holds stays refused, one public key, one access key, ever:
  # a row that is not a tombstone becomes one, `revoked`, now, and a `rejected` one is
  # `revoked` from now on.
  def up do
    clear_keys_and_codes()

    execute("""
    UPDATE access_key_public_keys
    SET retired_reason = 'revoked', updated_at = now()
    WHERE retired_reason = 'rejected'
    """)

    drop constraint(:access_keys, :access_keys_approval_check)
    drop index(:access_keys, [:approved_by_id])

    alter table(:access_keys) do
      remove :approved_at
      remove :approved_by_id
      remove :last_pending_at
    end

    drop constraint(:access_key_public_keys, :access_key_public_keys_state_check)

    create constraint(:access_key_public_keys, :access_key_public_keys_state_check,
             check:
               "(state = 'current' AND retired_at IS NULL AND retired_reason IS NULL) OR " <>
                 "(state = 'tombstone' AND retired_at IS NOT NULL AND retired_reason IN " <>
                 "('revoked', 'expired', 'node_deleted', 'workspace_deleted'))"
           )
  end

  # Rolling back gives the table its columns, index and checks again, and the ledger its
  # state and reason; the keys, codes and deliveries deleted do not come back, and the
  # ledger's tombstones stay tombstones. A key made since carries an integrity code of
  # version 2, which the code before this migration does not verify, and a code made since
  # names such a key or would bring one: they are cleared as `up` clears, for the same
  # reason.
  def down do
    clear_keys_and_codes()

    drop constraint(:access_key_public_keys, :access_key_public_keys_state_check)

    create constraint(:access_key_public_keys, :access_key_public_keys_state_check,
             check:
               "(state IN ('current', 'pending') AND retired_at IS NULL AND " <>
                 "retired_reason IS NULL) OR " <>
                 "(state = 'tombstone' AND retired_at IS NOT NULL AND retired_reason IN " <>
                 "('revoked', 'rejected', 'expired', 'node_deleted', 'workspace_deleted'))"
           )

    alter table(:access_keys) do
      add :approved_at, :utc_datetime_usec
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :last_pending_at, :utc_datetime_usec
    end

    create index(:access_keys, [:approved_by_id])

    create constraint(:access_keys, :access_keys_approval_check,
             check: "approved_by_id IS NULL OR approved_at IS NOT NULL"
           )
  end

  # Every node's key goes, with its deliveries, every public key the ledger holds that is
  # not a tombstone becomes one, `revoked`, and every enrolment code goes.
  defp clear_keys_and_codes do
    execute("DELETE FROM deliveries WHERE access_key_id IN (SELECT id FROM access_keys)")

    execute("""
    UPDATE access_key_public_keys
    SET state = 'tombstone', retired_at = now(), retired_reason = 'revoked', updated_at = now()
    WHERE state <> 'tombstone'
    """)

    execute("DELETE FROM access_keys")
    execute("DELETE FROM access_key_enrolment_codes")
  end
end
