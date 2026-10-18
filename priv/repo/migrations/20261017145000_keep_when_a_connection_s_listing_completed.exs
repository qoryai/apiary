defmodule Apiary.Repo.Migrations.KeepWhenAConnectionSListingCompleted do
  use Ecto.Migration

  # When a listing of a connection's collections last became complete,
  # `listing_completed_at` (`Apiary.Adapters.Connection`): every part from 1 to the last
  # had arrived (`Apiary.Adapters.Collections.post_listing/2`). Empty until the first
  # complete listing; a connection that no listing named has none. Adding a column that may
  # be empty, with no default, rewrites no row.
  def change do
    alter table(:adapter_connections) do
      add :listing_completed_at, :utc_datetime_usec
    end

    create constraint(:adapter_connections, :adapter_connections_listing_completed_check,
             check: "listing_completed_at IS NULL OR listed_at IS NOT NULL"
           )
  end
end
