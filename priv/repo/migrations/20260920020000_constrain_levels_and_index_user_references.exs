defmodule Apiary.Repo.Migrations.ConstrainLevelsAndIndexUserReferences do
  use Ecto.Migration

  # The level is an Ecto.Enum in the application; the database now refuses any
  # other value too. The two indexes serve the ON DELETE SET NULL of the user
  # references, which otherwise scans the table when a user is deleted.
  #
  # Both tables are small (one row per member or invitation, a handful of keys
  # per hive), so the indexes are created in the migration's transaction.
  def change do
    create constraint(:memberships, :memberships_level_check,
             check: "level IN ('owner', 'member')"
           )

    create constraint(:invitations, :invitations_level_check,
             check: "level IN ('owner', 'member')"
           )

    create index(:invitations, [:invited_by_id])
    create index(:access_keys, [:created_by_id])
  end
end
