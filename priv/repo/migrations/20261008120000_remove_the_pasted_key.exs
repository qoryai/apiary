defmodule Apiary.Repo.Migrations.RemoveThePastedKey do
  use Ecto.Migration

  # A key no longer arrives by a paste of its public key: a node or a pool gets its key by
  # an enrolment code, or made in a browser (`Apiary.AccessKeys`). The check on how a key
  # arrived takes the two values left: `browser`, or `code` with the enrolment code it
  # arrived by.
  #
  # A key pasted since `MakeAnEnrolledKeyActiveAtOnce`, which deleted every key before it,
  # has no place under the new check, and its arrival is fixed (`access_keys_fixed_at_insert`)
  # and covered by its integrity code, so it is not rewritten: it is deleted, with its rows
  # of `deliveries`, whose foreign key would refuse the deletion, and its public key stays
  # refused in the ledger, a tombstone, `revoked`. A run and an instance lose the key they
  # name (`on_delete: :nilify_all`); an audit entry names it by id and stays.
  def up do
    execute("""
    DELETE FROM deliveries
    WHERE access_key_id IN (SELECT id FROM access_keys WHERE arrived_by = 'paste')
    """)

    execute("""
    UPDATE access_key_public_keys
    SET state = 'tombstone', retired_at = now(), retired_reason = 'revoked', updated_at = now()
    WHERE state <> 'tombstone'
      AND key_id IN (SELECT key_id FROM access_keys WHERE arrived_by = 'paste')
    """)

    execute("DELETE FROM access_keys WHERE arrived_by = 'paste'")

    drop constraint(:access_keys, :access_keys_arrived_by_check)

    create constraint(:access_keys, :access_keys_arrived_by_check,
             check:
               "arrived_by = 'browser' OR " <>
                 "(arrived_by = 'code' AND enrolment_code_id IS NOT NULL)"
           )
  end

  # Rolling back gives the check `paste` again; the keys deleted do not come back.
  def down do
    drop constraint(:access_keys, :access_keys_arrived_by_check)

    create constraint(:access_keys, :access_keys_arrived_by_check,
             check:
               "arrived_by IN ('paste', 'browser') OR " <>
                 "(arrived_by = 'code' AND enrolment_code_id IS NOT NULL)"
           )
  end
end
