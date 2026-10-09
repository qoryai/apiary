defmodule Apiary.Repo.Migrations.RemoveServerMadeAccessKeys do
  use Ecto.Migration

  # One kind of access key is left: a node's or a node pool's, with one Ed25519 public key
  # (`Apiary.AccessKeys`). The keys with a secret the server made, and no node, are gone.
  #
  # Every row without a public key is deleted, with its rows of `deliveries`, whose
  # foreign key would refuse the deletion (`on_delete: :nothing`). A run and an instance
  # lose the key they name (`on_delete: :nilify_all`) and keep everything else; an audit
  # entry names its key by id, without a foreign key, and stays as it is.
  #
  # The secret columns go, with the check that a row held a secret or a public key and the
  # label's uniqueness among the workspace's keys of that kind. A row now always has a
  # public key, a node, a time it was received and how it arrived: the columns say so.
  # The table keeps its name: the contract still calls them access keys.
  def up do
    execute("""
    DELETE FROM deliveries
    WHERE access_key_id IN (SELECT id FROM access_keys WHERE public_key IS NULL)
    """)

    execute("DELETE FROM access_keys WHERE public_key IS NULL")

    drop constraint(:access_keys, :access_keys_credential_check)

    drop index(:access_keys, [:organisation_id, :workspace_id, :label],
           name: :access_keys_active_label_index
         )

    alter table(:access_keys) do
      remove :secret_primary
      remove :secret_secondary
      remove :rotated_at
    end

    # SET NOT NULL alone: `modify` would alter the type too, which the trigger that keeps
    # the node and the public key fixed refuses.
    execute("""
    ALTER TABLE access_keys
      ALTER COLUMN public_key SET NOT NULL,
      ALTER COLUMN node_id SET NOT NULL,
      ALTER COLUMN received_at SET NOT NULL,
      ALTER COLUMN arrived_by SET NOT NULL
    """)
  end

  # Rolling back gives the table its columns, constraint and index again, empty: the keys
  # deleted, their secrets and their deliveries do not come back.
  def down do
    execute("""
    ALTER TABLE access_keys
      ALTER COLUMN arrived_by DROP NOT NULL,
      ALTER COLUMN received_at DROP NOT NULL,
      ALTER COLUMN node_id DROP NOT NULL,
      ALTER COLUMN public_key DROP NOT NULL
    """)

    alter table(:access_keys) do
      add :rotated_at, :utc_datetime_usec
      add :secret_secondary, :binary
      add :secret_primary, :binary
    end

    create unique_index(:access_keys, [:organisation_id, :workspace_id, :label],
             where: "revoked_at IS NULL AND node_id IS NULL",
             name: :access_keys_active_label_index
           )

    create constraint(:access_keys, :access_keys_credential_check,
             check: "(public_key IS NULL) <> (secret_primary IS NULL)"
           )
  end
end
