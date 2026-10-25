defmodule Apiary.Repo.Migrations.KeepAGrantSAccountAndItsCollections do
  use Ecto.Migration

  # A grant's external account, and the grant that covers each collection, as the
  # integration contract has them (`grant.schema.json`, `source-collections.schema.json`,
  # `grant-end.schema.json`):
  #
  # - `adapter_grants` gains `account_ref`, the external account's id at the source, 1 to
  #   200 characters, and `account_title`, its display name, 1 to 1,024 characters, both
  #   or neither, as set by the latest accepted report of the grant. `ended_reason`
  #   gains `adapter_reported`: the adapter reported that the source no longer covers the
  #   grant (`POST /v1/grants/end`), and the connection stays.
  # - `source_collections` gains `grant_id`, the grant of the same connection, as set by
  #   the latest listing with the collection. Its foreign key to the composite key on
  #   `adapter_grants` (`id`, `connection_id`) keeps it a grant of that connection.
  #
  # The rows there already keep NULL in the three columns, and adding a column with no
  # default rewrites no row: an account is never made up, and the next listing with a
  # collection sets its grant. A grant end ends only the collections whose
  # `grant_id` is that grant. `adapter_grants` has one row per external account a
  # connection reaches, so its new index is built inside the transaction.
  def up do
    alter table(:adapter_grants) do
      add :account_ref, :text
      add :account_title, :text
    end

    create constraint(:adapter_grants, :adapter_grants_account_check,
             check:
               "(account_ref IS NULL) = (account_title IS NULL) AND " <>
                 "(account_ref IS NULL OR (char_length(account_ref) BETWEEN 1 AND 200 AND " <>
                 "char_length(account_title) BETWEEN 1 AND 1024))"
           )

    drop constraint(:adapter_grants, :adapter_grants_ended_reason_check)

    create constraint(:adapter_grants, :adapter_grants_ended_reason_check,
             check:
               "(ended_at IS NULL) = (ended_reason IS NULL) AND " <>
                 "(ended_reason IS NULL OR " <>
                 "ended_reason IN ('connection_ended', 'adapter_reported'))"
           )

    # The key that a collection's foreign key to its grant links to: the grant and its
    # connection at once.
    create unique_index(:adapter_grants, [:id, :connection_id])

    alter table(:source_collections) do
      add :grant_id,
          references(:adapter_grants,
            type: :binary_id,
            with: [connection_id: :connection_id],
            on_delete: :nothing
          )
    end
  end

  # Rolling back drops the three columns. The old check has no place for a grant that
  # ended by a grant end, and its connection did not end, so `connection_ended` would be
  # false: such grants are deleted. They are in no copy of grants, and nothing else has a
  # foreign key to them once `grant_id` is gone.
  def down do
    alter table(:source_collections) do
      remove :grant_id
    end

    drop index(:adapter_grants, [:id, :connection_id])

    execute("DELETE FROM adapter_grants WHERE ended_reason = 'adapter_reported'")

    drop constraint(:adapter_grants, :adapter_grants_ended_reason_check)

    create constraint(:adapter_grants, :adapter_grants_ended_reason_check,
             check:
               "(ended_at IS NULL) = (ended_reason IS NULL) AND " <>
                 "(ended_reason IS NULL OR ended_reason IN ('connection_ended'))"
           )

    drop constraint(:adapter_grants, :adapter_grants_account_check)

    alter table(:adapter_grants) do
      remove :account_title
      remove :account_ref
    end
  end
end
