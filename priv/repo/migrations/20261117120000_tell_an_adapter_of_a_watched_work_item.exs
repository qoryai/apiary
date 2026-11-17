defmodule Apiary.Repo.Migrations.TellAnAdapterOfAWatchedWorkItem do
  use Ecto.Migration

  # The adapter's change feed has a sixth kind of entry, `watch`: a work item on which a
  # run stored a submission version (`Apiary.Adapters.Feed`, the integration contract's
  # `changes.schema.json`). A watch entry's data keeps the bound of 4,096 bytes.
  #
  # The check is added NOT VALID, so adding it takes no scan of the feed under its lock;
  # the next migration validates it. Rolled back, the check takes the five kinds again,
  # and the rollback fails while a watch entry is in the feed.
  def up do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'comment', 'collection', 'sync', 'grant', 'watch')",
             validate: false
           )
  end

  def down do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'comment', 'collection', 'sync', 'grant')"
           )
  end
end
