defmodule Apiary.Repo.Migrations.KeepAMemberSCommentOnATicket do
  use Ecto.Migration

  # A comment a member writes on a ticket in Qory Apiary, kept in `source_item_comments`
  # beside the comments the adapter sends (`Apiary.Sources.Comment`), until the adapter
  # posts it at the source:
  #
  # - `author_id`, the member who wrote it, nil once their account's row is gone;
  # - `comment_id`, its id in Qory Apiary: `sc_` and sixteen lowercase Crockford base32
  #   characters (`Apiary.PublicId`), unique (`20261106130200`);
  # - `post_state`, how far the post at the source is: `posting`, `posted`, `not_posted`
  #   or `kept`, for a source that takes no comments;
  # - `post_failure`, why a post failed: `item_gone`, `not_permitted`, `too_long`,
  #   `unreachable` or `deleted_at_source`, only with `not_posted`.
  #
  # A comment the adapter sent has none of the four. A member's comment has a
  # `comment_id` and a `post_state`, and its `external_ref` and `url` only once it is
  # posted, so both may now be empty, together.
  #
  # Every column is new and may be empty, with no default, so no row is written again,
  # and every row there passes each check. The checks and the key to `users` are added NOT
  # VALID, so adding them takes no scan of the table under its lock;
  # `20261106130100` validates them, and `20261106130200` makes the indexes concurrently.
  @comment_id "^sc_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    alter table(:source_item_comments) do
      add :author_id,
          references(:users, type: :binary_id, on_delete: :nilify_all, validate: false)

      add :comment_id, :text
      add :post_state, :text
      add :post_failure, :text
    end

    execute "ALTER TABLE source_item_comments ALTER COLUMN external_ref DROP NOT NULL"
    execute "ALTER TABLE source_item_comments ALTER COLUMN url DROP NOT NULL"

    create constraint(:source_item_comments, :source_item_comments_comment_id_check,
             check: "comment_id ~ '#{@comment_id}'",
             validate: false
           )

    # A source's comment: no id, no state, no member, a ref. A member's comment: an id
    # and a state, a ref exactly once it is posted. Each check is written so that it is
    # never NULL, which a check takes as passed.
    create constraint(:source_item_comments, :source_item_comments_post_state_check,
             check:
               "(comment_id IS NULL AND post_state IS NULL AND author_id IS NULL AND " <>
                 "external_ref IS NOT NULL) OR " <>
                 "(comment_id IS NOT NULL AND post_state IS NOT NULL AND " <>
                 "post_state IN ('posting', 'posted', 'not_posted', 'kept') AND " <>
                 "(external_ref IS NOT NULL) = (post_state = 'posted'))",
             validate: false
           )

    create constraint(:source_item_comments, :source_item_comments_post_failure_check,
             check:
               "CASE WHEN post_state = 'not_posted' THEN post_failure IS NOT NULL AND " <>
                 "post_failure IN ('item_gone', 'not_permitted', 'too_long', 'unreachable', " <>
                 "'deleted_at_source') " <>
                 "ELSE post_failure IS NULL END",
             validate: false
           )

    create constraint(:source_item_comments, :source_item_comments_ref_url_check,
             check: "(external_ref IS NULL) = (url IS NULL)",
             validate: false
           )
  end

  # Rolled back, the comments members wrote that no adapter posted, which have no ref, are
  # deleted: the columns they need go. A posted one stays, as a comment of its source.
  def down do
    execute "DELETE FROM source_item_comments WHERE external_ref IS NULL OR url IS NULL"

    drop constraint(:source_item_comments, :source_item_comments_ref_url_check)
    drop constraint(:source_item_comments, :source_item_comments_post_failure_check)
    drop constraint(:source_item_comments, :source_item_comments_post_state_check)
    drop constraint(:source_item_comments, :source_item_comments_comment_id_check)

    execute "ALTER TABLE source_item_comments ALTER COLUMN url SET NOT NULL"
    execute "ALTER TABLE source_item_comments ALTER COLUMN external_ref SET NOT NULL"

    alter table(:source_item_comments) do
      remove :post_failure
      remove :post_state
      remove :comment_id
      remove :author_id
    end
  end
end
