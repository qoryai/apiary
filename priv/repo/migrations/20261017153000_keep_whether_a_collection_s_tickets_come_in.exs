defmodule Apiary.Repo.Migrations.KeepWhetherACollectionSTicketsComeIn do
  use Ecto.Migration

  # Whether a collection's items come into the Backlog of the workspace it is linked to,
  # `backlog` (`Apiary.Adapters.Collection`): a collection is linked while it is assigned
  # to a workspace and this is on. On for every collection, those there already among
  # them. A constant default rewrites no row.
  def change do
    alter table(:source_collections) do
      add :backlog, :boolean, null: false, default: true
    end
  end
end
