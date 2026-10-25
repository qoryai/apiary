defmodule Apiary.Repo.Migrations.KeepTheOwnerOfEachStack do
  use Ecto.Migration

  # Each stack row has an owner organisation (`Apiary.Stacks.Stack`): the column
  # `stacks.saved_by_organisation_id` becomes `stacks.owner_organisation_id`, with its
  # index and its foreign key, which still sets it to NULL when that organisation is
  # deleted. `Apiary.Stacks.put_stack/3` refuses a save with no owner, so a row written
  # after this migration has one until its owner is deleted.
  #
  # Up sets each NULL owner to the instance's organisation as the core edition has it
  # (`Apiary.Edition.Core.instance_organisation_id/0`): the oldest organisation that is
  # not marked for deletion. The core has no operators, so a document saved by no member
  # was saved by an instance admin or by the instance. On a database with no
  # organisation, the NULL owners stay. Down renames the column back, and the owners up
  # wrote stay.

  def up do
    rename table(:stacks), :saved_by_organisation_id, to: :owner_organisation_id
    rename_names("saved_by_organisation_id", "owner_organisation_id")

    execute """
    UPDATE stacks SET owner_organisation_id = (
      SELECT id FROM organisations
      WHERE deletion_marked_at IS NULL
      ORDER BY inserted_at ASC, id ASC
      LIMIT 1
    )
    WHERE owner_organisation_id IS NULL
    """
  end

  def down do
    rename table(:stacks), :owner_organisation_id, to: :saved_by_organisation_id
    rename_names("owner_organisation_id", "saved_by_organisation_id")
  end

  # The column's index and foreign key, named after the column.
  defp rename_names(from, to) do
    execute "ALTER INDEX stacks_#{from}_index RENAME TO stacks_#{to}_index"

    execute "ALTER TABLE stacks RENAME CONSTRAINT stacks_#{from}_fkey TO stacks_#{to}_fkey"
  end
end
