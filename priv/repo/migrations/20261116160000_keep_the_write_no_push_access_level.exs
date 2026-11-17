defmodule Apiary.Repo.Migrations.KeepTheWriteNoPushAccessLevel do
  use Ecto.Migration

  # The third access level of a workflow, `write-no-push`: a run with a writable checkout
  # that has no push credential.
  #
  #   * `run_harnesses.access_level` (`Apiary.Harnesses.RunHarness`) takes `write-no-push`
  #     besides `read` and `write` (`run_harnesses_access_level_check`). The new check
  #     scans `run_harnesses` under a lock that blocks reads and writes. No row changes.
  #   * `workspaces.declared_access`, JSON, is the level each workflow of the workspace's
  #     harness declares at the last read of the harness, by name, as the Workflows page
  #     shows it (`Apiary.Processes.declared_snapshot/1`). NULL until the first read after
  #     this migration, and for a workspace on the Qory harness, whose levels are read
  #     from the stored files. Adding a column with no default rewrites no row.
  #
  # Rolled back, a run of `write-no-push` becomes `read`, as it was the level of its work
  # credential.
  def up do
    execute "ALTER TABLE run_harnesses DROP CONSTRAINT run_harnesses_access_level_check"

    execute """
    ALTER TABLE run_harnesses ADD CONSTRAINT run_harnesses_access_level_check
    CHECK (access_level IN ('read', 'write-no-push', 'write'))
    """

    alter table(:workspaces) do
      add :declared_access, :map
    end
  end

  def down do
    alter table(:workspaces) do
      remove :declared_access
    end

    execute "ALTER TABLE run_harnesses DROP CONSTRAINT run_harnesses_access_level_check"
    execute "UPDATE run_harnesses SET access_level = 'read' WHERE access_level = 'write-no-push'"

    execute """
    ALTER TABLE run_harnesses ADD CONSTRAINT run_harnesses_access_level_check
    CHECK (access_level IN ('read', 'write'))
    """
  end
end
