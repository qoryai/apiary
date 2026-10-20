defmodule Apiary.Repo.Migrations.LetAWorkItemHaveNoTarget do
  use Ecto.Migration

  # A work item's target is optional: whether a work item needs one is its workspace's
  # domain's rule (`Apiary.Lingo.Domain.target_required?/1`), which Take in applies, as
  # the database cannot read a workspace's domain from a work item's row. The two columns
  # become nullable, both or neither (`work_items_target_pair_check`).
  #
  # `work_items_target_shape_check` keeps its host part, which holds in every domain: no
  # dot first or last in the system, and no two together. Its rule on the path's segments
  # is the software domain's, which Take in and the handover check in code
  # (`Apiary.Lingo.Domain.Software`).
  #
  # Rolled back, the path rule and NOT NULL come back. Postgres refuses the rollback while
  # a work item has no target, or a path the old rule refuses, and nothing changes.
  def up do
    execute "ALTER TABLE work_items ALTER COLUMN target_system DROP NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN target_path DROP NOT NULL"

    create constraint(:work_items, :work_items_target_pair_check,
             check: "(target_system IS NULL) = (target_path IS NULL)"
           )

    drop constraint(:work_items, :work_items_target_shape_check)

    execute """
    ALTER TABLE work_items ADD CONSTRAINT work_items_target_shape_check CHECK (
      target_system !~ '(^\\.|\\.\\.|\\.$)'
    )
    """
  end

  def down do
    drop constraint(:work_items, :work_items_target_shape_check)

    execute """
    ALTER TABLE work_items ADD CONSTRAINT work_items_target_shape_check CHECK (
      target_system !~ '(^\\.|\\.\\.|\\.$)' AND target_path !~ '(^|/)-'
    )
    """

    drop constraint(:work_items, :work_items_target_pair_check)

    execute "ALTER TABLE work_items ALTER COLUMN target_path SET NOT NULL"
    execute "ALTER TABLE work_items ALTER COLUMN target_system SET NOT NULL"
  end
end
