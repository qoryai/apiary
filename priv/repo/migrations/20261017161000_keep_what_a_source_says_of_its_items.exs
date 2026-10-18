defmodule Apiary.Repo.Migrations.KeepWhatASourceSaysOfItsItems do
  use Ecto.Migration

  # What a work item source says of its items, as the integration contract has it
  # (`description.schema.json`, `roles.source`; `source-collections.schema.json`):
  #
  # - on an adapter's node (`Apiary.Nodes.Node`), `item_noun_one` and `item_noun_other`,
  #   its words for one item and for many, both or neither, NULL for the default; and
  #   `items`, false for a source that reports collections and no items, with no words
  #   beside it. Each word is 1 to 32 lower-case letters, a to z, in words joined by
  #   single spaces or hyphens, and never "work item" or "work items", with a space or a
  #   hyphen. Every other node has no words and `items` true (`nodes_items_check`).
  # - on a collection (`Apiary.Adapters.Collection`), `items`, false while the latest
  #   listing that named it said it has no items.
  #
  # Both are true for every row there already, and a constant default rewrites no row.
  @noun "'^[a-z]+([ -][a-z]+)*$'"
  @work_item "'^work[ -]items?$'"

  def up do
    alter table(:nodes) do
      add :item_noun_one, :text
      add :item_noun_other, :text
      add :items, :boolean, null: false, default: true
    end

    alter table(:source_collections) do
      add :items, :boolean, null: false, default: true
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_items_check CHECK (
      (kind = 'adapter' OR (item_noun_one IS NULL AND item_noun_other IS NULL AND items)) AND
      ((item_noun_one IS NULL) = (item_noun_other IS NULL)) AND
      (items OR item_noun_one IS NULL) AND
      (item_noun_one IS NULL OR (
        char_length(item_noun_one) BETWEEN 1 AND 32 AND item_noun_one ~ #{@noun} AND
        item_noun_one !~ #{@work_item}
      )) AND
      (item_noun_other IS NULL OR (
        char_length(item_noun_other) BETWEEN 1 AND 32 AND item_noun_other ~ #{@noun} AND
        item_noun_other !~ #{@work_item}
      ))
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_items_check"

    alter table(:source_collections) do
      remove :items
    end

    alter table(:nodes) do
      remove :items
      remove :item_noun_other
      remove :item_noun_one
    end
  end
end
