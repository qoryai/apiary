defmodule Apiary.Repo.Migrations.LetAKeyArriveMadeInABrowser do
  use Ecto.Migration

  # A key may arrive a third way: made in a browser, on the node's Access key tab, which
  # sends Apiary its public half alone (`Apiary.AccessKeys.add_access_key/4`,
  # `arrived_by: :browser`). The check on how a key arrived takes the new value: `paste`
  # or `browser`, or `code` with the enrolment code it arrived by. The column is NOT NULL
  # since `RemoveServerMadeAccessKeys`, so the check no longer allows a null.
  def up do
    drop constraint(:access_keys, :access_keys_arrived_by_check)

    create constraint(:access_keys, :access_keys_arrived_by_check,
             check:
               "arrived_by IN ('paste', 'browser') OR " <>
                 "(arrived_by = 'code' AND enrolment_code_id IS NOT NULL)"
           )
  end

  # Rolling back gives the check its two values again. A key made in a browser has no place
  # under it, and its arrival is fixed (`access_keys_fixed_at_insert`) and covered by its
  # integrity code, so it is not rewritten as a paste: it is deleted, with its rows of
  # `deliveries`, whose foreign key would refuse the deletion, and its public key stays
  # refused in the ledger, a tombstone, `revoked`. A run and an instance lose the key they
  # name (`on_delete: :nilify_all`); an audit entry names it by id and stays.
  def down do
    execute("""
    DELETE FROM deliveries
    WHERE access_key_id IN (SELECT id FROM access_keys WHERE arrived_by = 'browser')
    """)

    execute("""
    UPDATE access_key_public_keys
    SET state = 'tombstone', retired_at = now(), retired_reason = 'revoked', updated_at = now()
    WHERE state <> 'tombstone'
      AND key_id IN (SELECT key_id FROM access_keys WHERE arrived_by = 'browser')
    """)

    execute("DELETE FROM access_keys WHERE arrived_by = 'browser'")

    drop constraint(:access_keys, :access_keys_arrived_by_check)

    create constraint(:access_keys, :access_keys_arrived_by_check,
             check:
               "arrived_by IS NULL OR arrived_by = 'paste' OR " <>
                 "(arrived_by = 'code' AND enrolment_code_id IS NOT NULL)"
           )
  end
end
