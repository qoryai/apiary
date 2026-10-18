defmodule Apiary.Repo.Migrations.KeepWhenACompleteSetLeftACommentOut do
  use Ecto.Migration

  # For a comment that a complete set of its item's comments left out and marked deleted,
  # that set's `complete.since` (`deleted_by_complete_at`, `Apiary.Sources.Comment`): the
  # mark counts as a write at that time, so that a later request carrying the comment
  # updated before it does not bring it back (`Apiary.Sources`). Only a comment marked
  # deleted has it. Adding a column that may be empty, with no default, rewrites no row,
  # and every row passes the check.
  def change do
    alter table(:source_item_comments) do
      add :deleted_by_complete_at, :utc_datetime
    end

    create constraint(:source_item_comments, :source_item_comments_deleted_by_complete_check,
             check: "deleted_by_complete_at IS NULL OR deleted_at IS NOT NULL"
           )
  end
end
