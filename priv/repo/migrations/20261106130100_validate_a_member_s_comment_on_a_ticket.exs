defmodule Apiary.Repo.Migrations.ValidateAMemberSCommentOnATicket do
  use Ecto.Migration

  # Validates the checks and the key to `users` that the migration before this one added
  # NOT VALID: scans that take no lock that blocks writes to `source_item_comments`. Down
  # leaves them as they are; the migration before this one drops them.
  @valid ~w(
    source_item_comments_author_id_fkey
    source_item_comments_comment_id_check
    source_item_comments_post_state_check
    source_item_comments_post_failure_check
    source_item_comments_ref_url_check
  )

  def up do
    for name <- @valid do
      execute "ALTER TABLE source_item_comments VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
