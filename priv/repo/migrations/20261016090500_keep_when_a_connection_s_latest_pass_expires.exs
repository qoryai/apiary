defmodule Apiary.Repo.Migrations.KeepWhenAConnectionSLatestPassExpires do
  use Ecto.Migration

  # When the latest connect pass of a connection expires, `pass_expires_at`
  # (`Apiary.Adapters.Connection`), in UTC to the second, as the pass says. Each new pass
  # of a connection expires strictly later than the one before it
  # (`Apiary.Adapters.Connections.start/3`), so the adapter can always tell the newer
  # pass. The column may be empty: a connection made before it was added has no pass
  # expiry kept, and its next pass expires as a first pass does. Adding a column that may
  # be empty, with no default, rewrites no row.
  def change do
    alter table(:adapter_connections) do
      add :pass_expires_at, :utc_datetime
    end
  end
end
