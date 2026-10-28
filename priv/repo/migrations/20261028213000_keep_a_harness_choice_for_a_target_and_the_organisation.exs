defmodule Apiary.Repo.Migrations.KeepAHarnessChoiceForATargetAndTheOrganisation do
  use Ecto.Migration

  # A harness choice (`stacks.choice`) on three rows with no workflow (`Apiary.Stacks`):
  #
  #   * a target's row: the stack chosen for that target;
  #   * the workspace's row: the workspace's choice, as before;
  #   * the organisation's row: the harness the organisation shares with every workspace.
  #
  # Each choice is `qory` or `repository`, with its document. The choice `target_file`
  # goes: a run reads its target's harness file where neither a stack chosen for the
  # target nor a `repository` choice applies (`Apiary.Harnesses.Walk`). A row with
  # `target_file` loses its choice, and such a row with neither a document nor a workflow
  # is deleted, as the check `stacks_harness_or_workflow` takes no row with none of the
  # three.
  #
  # Rolled back, a choice on a target's row or the organisation's row is cleared, and the
  # check takes a choice on the workspace's row again, `target_file` among them.
  def up do
    execute """
    DELETE FROM stacks WHERE choice = 'target_file' AND harness IS NULL AND workflow IS NULL
    """

    execute "UPDATE stacks SET choice = NULL WHERE choice = 'target_file'"

    drop constraint(:stacks, :stacks_choice_check)

    create constraint(:stacks, :stacks_choice_check,
             check: """
             choice IS NULL
             OR (choice IN ('qory', 'repository') AND workflow IS NULL AND harness IS NOT NULL)
             """
           )
  end

  def down do
    execute """
    UPDATE stacks SET choice = NULL
    WHERE choice IS NOT NULL AND (workspace_id IS NULL OR target_id IS NOT NULL)
    """

    drop constraint(:stacks, :stacks_choice_check)

    create constraint(:stacks, :stacks_choice_check,
             check: """
             choice IS NULL
             OR (choice IN ('qory', 'repository', 'target_file')
                 AND workspace_id IS NOT NULL AND target_id IS NULL AND workflow IS NULL
                 AND (harness IS NOT NULL OR choice = 'target_file'))
             """
           )
  end
end
