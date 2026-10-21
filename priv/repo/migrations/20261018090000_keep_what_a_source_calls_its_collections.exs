defmodule Apiary.Repo.Migrations.KeepWhatASourceCallsItsCollections do
  use Ecto.Migration

  # What a work item source calls its collections, as the integration contract has it
  # (`description.schema.json`, `roles.source.collection_noun`): on an adapter's node
  # (`Apiary.Nodes.Node`), `collection_noun_one` and `collection_noun_other`, its words for
  # one collection and for many, both or neither, NULL for the default, the domain's word.
  # Each is 1 to 32 characters: lower-case letters, a to z, in words joined by single
  # spaces or hyphens. Unlike the words for its items, no word is refused, and they may stand beside
  # `items` false: a source with no items still reports collections. Every other node has
  # none (`nodes_collection_noun_check`).
  #
  # Both are NULL for every row there already, and adding a column with no default
  # rewrites no row.
  @noun "'^[a-z]+([ -][a-z]+)*$'"

  def up do
    alter table(:nodes) do
      add :collection_noun_one, :text
      add :collection_noun_other, :text
    end

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

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_collection_noun_check"

    alter table(:nodes) do
      remove :collection_noun_other
      remove :collection_noun_one
    end
  end
end
