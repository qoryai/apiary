defmodule Apiary.Repo.Migrations.KeepOneLiveGrantPerConnection do
  use Ecto.Migration

  # A connection to an adapter has one external account, so one grant that has not ended
  # (`adapter_grants.ended_at IS NULL`). `Apiary.Adapters.Grants.report/2` returns
  # `connection_held` for a second one; this index makes a second one a database error
  # (`adapter_grants_one_live_per_connection`). No row is read or changed: the migration
  # fails on a database where a connection has two grants that have not ended. Down drops
  # the index.
  def change do
    create unique_index(:adapter_grants, [:connection_id],
             where: "ended_at IS NULL",
             name: :adapter_grants_one_live_per_connection
           )
  end
end
