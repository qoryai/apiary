defmodule Apiary.Repo.Migrations.TellAnAdapterOfAChangeRequest do
  use Ecto.Migration

  # The adapter's change feed has a seventh kind of entry, `change_request`: a change a run
  # stored, for the adapter to apply at a target in one of its collections
  # (`Apiary.Adapters.Feed`, the integration contract's `changes.schema.json`). Its `data`
  # is up to 786,432 bytes as `Jason.encode!/1` writes it. As text, Postgres writes a
  # space after each `:` and `,` of a jsonb value, which makes it up to 1.5 times longer,
  # and the entry also has a text of up to 20,000 characters and two titles of up to 256,
  # each character up to four bytes, with the ids, the target and the previous address.
  # So a change_request entry's data may take up to 1,400,000 bytes as text. Postgres
  # writes a jsonb number in plain notation, which can make an entry longer still: the
  # writer (`Apiary.Artifacts.Delivery`) measures the text before it writes, and marks a
  # longer entry invalid. A comment
  # entry keeps its bound of 400,000 bytes, and every other kind its bound of 4,096.
  #
  # Both checks are added NOT VALID, so adding them takes no scan of the feed under its
  # lock; the next migration validates them. Rolled back, the checks take the six kinds
  # and the earlier bounds again, refused while a change_request entry is there.
  def up do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)
    drop constraint(:adapter_feed, :adapter_feed_data_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check:
               "kind IN ('work_item', 'comment', 'collection', 'sync', 'grant', 'watch', 'change_request')",
             validate: false
           )

    create constraint(:adapter_feed, :adapter_feed_data_check,
             check: """
             jsonb_typeof(data) = 'object' AND
               octet_length(data::text) <= CASE kind
                 WHEN 'change_request' THEN 1400000
                 WHEN 'comment' THEN 400000
                 ELSE 4096
               END
             """,
             validate: false
           )
  end

  def down do
    drop constraint(:adapter_feed, :adapter_feed_kind_check)
    drop constraint(:adapter_feed, :adapter_feed_data_check)

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'comment', 'collection', 'sync', 'grant', 'watch')"
           )

    create constraint(:adapter_feed, :adapter_feed_data_check,
             check: """
             jsonb_typeof(data) = 'object' AND
               octet_length(data::text) <= CASE WHEN kind = 'comment' THEN 400000 ELSE 4096 END
             """
           )
  end
end
