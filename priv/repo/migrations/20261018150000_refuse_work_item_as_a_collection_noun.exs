defmodule Apiary.Repo.Migrations.RefuseWorkItemAsACollectionNoun do
  use Ecto.Migration

  # What a work item source calls its collections, on an adapter's node
  # (`nodes_collection_noun_check`), is held to the integration contract's words
  # (`description.schema.json`, `roles.source.collection_noun`), which refuse "work item"
  # and "work items", with a space or a hyphen, for a collection as for an item
  # (`nodes_items_check`).
  #
  # Up clears both words of an adapter that stored one of those, to NULL, the default, the
  # domain's word, until a start of the adapter stores words again; then it rebuilds the
  # check with the refusal. Down rebuilds the check without it, and the words it cleared
  # stay NULL: nothing tells them back.
  @noun "'^[a-z]+([ -][a-z]+)*$'"
  @work_item "'^work[ -]items?$'"

  def up do
    execute """
    UPDATE nodes SET collection_noun_one = NULL, collection_noun_other = NULL
    WHERE collection_noun_one ~ #{@work_item} OR collection_noun_other ~ #{@work_item}
    """

    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_collection_noun_check"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_collection_noun_check CHECK (
      (kind = 'adapter' OR (collection_noun_one IS NULL AND collection_noun_other IS NULL)) AND
      ((collection_noun_one IS NULL) = (collection_noun_other IS NULL)) AND
      (collection_noun_one IS NULL OR (
        char_length(collection_noun_one) BETWEEN 1 AND 32 AND collection_noun_one ~ #{@noun} AND
        collection_noun_one !~ #{@work_item}
      )) AND
      (collection_noun_other IS NULL OR (
        char_length(collection_noun_other) BETWEEN 1 AND 32 AND
        collection_noun_other ~ #{@noun} AND collection_noun_other !~ #{@work_item}
      ))
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_collection_noun_check"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_collection_noun_check CHECK (
      (kind = 'adapter' OR (collection_noun_one IS NULL AND collection_noun_other IS NULL)) AND
      ((collection_noun_one IS NULL) = (collection_noun_other IS NULL)) AND
      (collection_noun_one IS NULL OR (
        char_length(collection_noun_one) BETWEEN 1 AND 32 AND collection_noun_one ~ #{@noun}
      )) AND
      (collection_noun_other IS NULL OR (
        char_length(collection_noun_other) BETWEEN 1 AND 32 AND collection_noun_other ~ #{@noun}
      ))
    )
    """
  end
end
