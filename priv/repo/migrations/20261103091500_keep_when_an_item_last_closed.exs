defmodule Apiary.Repo.Migrations.KeepWhenAnItemLastClosed do
  use Ecto.Migration

  # When an item of a collection last closed at its source, `last_closed_at`
  # (`Apiary.Sources.Item`): Qory Apiary's time of the write that moved it from open to
  # closed, or that inserted it closed. Empty until then, and for every item already
  # closed: no work item is finished yet, so no check reads one of them. Adding a column
  # that may be empty, with no default, rewrites no row.
  def change do
    alter table(:source_items) do
      add :last_closed_at, :utc_datetime_usec
    end
  end
end
