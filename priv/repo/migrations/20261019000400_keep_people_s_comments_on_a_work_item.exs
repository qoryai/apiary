defmodule Apiary.Repo.Migrations.KeepPeopleSCommentsOnAWorkItem do
  use Ecto.Migration

  # People's comments on a work item's Thread (`Apiary.WorkItems.Comment`), in plain text:
  #
  # - `work_item_comments`: one row per comment. `public_id` is `cm_` and sixteen
  #   lowercase Crockford base32 characters (`Apiary.PublicId`), unique. `body` is the
  #   text as the member wrote it, its line breaks line feeds, trimmed, 1 to 4,000
  #   characters counted as code points; which characters it may hold the application
  #   checks (`Apiary.Names.validate_characters/3`). `inserted_at` is when it was written.
  # - A deleted comment keeps its row, so the Thread keeps a line in its place:
  #   `deleted_at`, and `deleted_by_id`, who deleted it. Its body is gone (NULL). A
  #   comment not deleted has a body and nobody who deleted it.
  #
  # Who wrote or deleted it is a plain reference, set to NULL should the account's row
  # ever go; a page names a person without one as a former member. The table is held to
  # its workspace's organisation, and each row to its work item and the work item's
  # workspace by the composite key, which follows the work item to another workspace
  # (`ON UPDATE CASCADE`) and goes with it. The table is new, and empty.

  @public_id "^cm_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    create table(:work_item_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :work_item_id, :binary_id, null: false
      add :public_id, :text, null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :body, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec
      add :deleted_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    execute("""
    ALTER TABLE work_item_comments ADD CONSTRAINT work_item_comments_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create unique_index(:work_item_comments, [:public_id])
    create index(:work_item_comments, [:work_item_id, :inserted_at])
    create index(:work_item_comments, [:organisation_id, :workspace_id])
    create index(:work_item_comments, [:author_id])
    create index(:work_item_comments, [:deleted_by_id])

    create constraint(:work_item_comments, :work_item_comments_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    # A comment not deleted has its body, a deleted one none. `body IS NOT NULL` is
    # spelled out: `char_length(NULL)` is NULL, which a check lets pass.
    create constraint(:work_item_comments, :work_item_comments_body_check,
             check:
               "(deleted_at IS NULL AND body IS NOT NULL AND " <>
                 "char_length(body) BETWEEN 1 AND 4000) OR " <>
                 "(deleted_at IS NOT NULL AND body IS NULL)"
           )

    create constraint(:work_item_comments, :work_item_comments_deleted_check,
             check: "deleted_at IS NOT NULL OR deleted_by_id IS NULL"
           )
  end

  # Rolled back, the table goes, so the roll back refuses while a comment is kept, deleted
  # or not: it deletes none.
  @refusal "Qory Apiary keeps the comments people wrote on work items, so this migration " <>
             "rolls back only while none is kept. Some are."

  def down do
    execute("LOCK TABLE work_item_comments IN SHARE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM work_item_comments) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    drop table(:work_item_comments)
  end
end
