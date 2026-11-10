defmodule Apiary.Repo.Migrations.TellAnAdapterOfMembersComments do
  use Ecto.Migration

  # The adapter's change feed has a fifth kind of entry, `comment`: a comment a member
  # wrote in Qory Apiary, for the adapter to post on its item (`Apiary.Adapters.Feed`, the
  # integration contract's `changes.schema.json`). Its body is up to 65,000 characters,
  # so a comment entry's data may take up to 400,000 bytes as text: 65,000 characters of
  # six bytes each at most, a control character written `\uXXXX`, with its other members.
  # Every other kind keeps the bound of 4,096 bytes.
  #
  # Both checks are added NOT VALID, so adding them takes no scan of the feed under its
  # lock; the next migration validates them. Rolled back, the checks take the four kinds
  # and 4,096 bytes again, refused while a comment entry is there.
  def up do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)
    drop constraint(:adapter_feed, :adapter_feed_data_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'comment', 'collection', 'sync', 'grant')",
             validate: false
           )

    create constraint(:adapter_feed, :adapter_feed_data_check,
             check: """
             jsonb_typeof(data) = 'object' AND
               octet_length(data::text) <= CASE WHEN kind = 'comment' THEN 400000 ELSE 4096 END
             """,
             validate: false
           )
  end

  def down do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)
    drop constraint(:adapter_feed, :adapter_feed_data_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'collection', 'sync', 'grant')"
           )

    create constraint(:adapter_feed, :adapter_feed_data_check,
             check: "jsonb_typeof(data) = 'object' AND octet_length(data::text) <= 4096"
           )
  end
end
