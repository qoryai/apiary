defmodule Apiary.Repo.Migrations.TellAnAdapterOfItsGrants do
  use Ecto.Migration

  # The adapter's change feed holds a fourth kind of entry, `grant`: a grant of one of the
  # adapter's connections linked or unlinked (`Apiary.Adapters.Feed`, the integration
  # contract's `changes.schema.json`). The check is added NOT VALID, so adding it takes no
  # scan of the feed under its lock; the next migration validates it. Rolled back, the
  # check takes the three kinds again, refused while a grant entry is there.
  def up do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'collection', 'sync', 'grant')",
             validate: false
           )
  end

  def down do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'collection', 'sync')"
           )
  end
end
