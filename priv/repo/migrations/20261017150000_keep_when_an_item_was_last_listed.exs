defmodule Apiary.Repo.Migrations.KeepWhenAnItemWasLastListed do
  use Ecto.Migration

  # When an item of a collection was last named by a listing of its collection,
  # `last_listed_at` (`Apiary.Sources.Item`): the `started_at` of the newest listing that
  # named it, so that a complete listing closes the items it left out and no others
  # (`Apiary.Sources`). Empty until a listing names it. Adding a column that may be empty,
  # with no default, rewrites no row.
  def change do
    alter table(:source_items) do
      add :last_listed_at, :utc_datetime
    end
  end
end
