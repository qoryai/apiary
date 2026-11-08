defmodule Apiary.Repo.Migrations.IndexAMemberSCommentOnATicket do
  use Ecto.Migration

  # The indexes of a member's comment on a ticket (`20261106130000`): its `comment_id`,
  # unique, which the adapter's echo and failure report find it by, and its author, which
  # the removal of an account's row reads. Each has the rows that have the column alone,
  # so the comments the adapter sent add nothing to it.
  #
  # Concurrently, since `source_item_comments` may be large: outside a transaction and
  # without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create unique_index(:source_item_comments, [:comment_id],
             where: "comment_id IS NOT NULL",
             concurrently: true
           )

    create index(:source_item_comments, [:author_id],
             where: "author_id IS NOT NULL",
             concurrently: true
           )
  end
end
