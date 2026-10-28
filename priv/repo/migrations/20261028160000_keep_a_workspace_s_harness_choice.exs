defmodule Apiary.Repo.Migrations.KeepAWorkspaceSHarnessChoice do
  use Ecto.Migration

  # The harness a workspace's runs use (`Apiary.Stacks`): `stacks.choice`, text, on the
  # workspace's row with no target and no workflow, NULL for none.
  #
  #   * `qory`: the Qory harness, with the document that extends it at its pinned commit;
  #   * `repository`: a harness repository, with the document that extends it at the
  #     commit its branch or tag resolved to when it was saved;
  #   * `target_file`: the harness file of each run's target, with or without a document.
  #
  # The check `stacks_choice_check` takes a choice only on such a row, and a `qory` or
  # `repository` choice only with a document. The check `stacks_harness_or_workflow` also
  # takes a row with a choice and neither a document nor a workflow. Every row before this
  # migration has no choice.
  #
  # Rolled back, the rows with neither a document nor a workflow, which keep a choice
  # alone, are deleted, then the column goes with its check.
  def up do
    alter table(:stacks) do
      add :choice, :text
    end

    drop constraint(:stacks, :stacks_harness_or_workflow)

    create constraint(:stacks, :stacks_harness_or_workflow,
             check: "harness IS NOT NULL OR workflow IS NOT NULL OR choice IS NOT NULL"
           )

    create constraint(:stacks, :stacks_choice_check,
             check: """
             choice IS NULL
             OR (choice IN ('qory', 'repository', 'target_file')
                 AND workspace_id IS NOT NULL AND target_id IS NULL AND workflow IS NULL
                 AND (harness IS NOT NULL OR choice = 'target_file'))
             """
           )
  end

  def down do
    execute "DELETE FROM stacks WHERE harness IS NULL AND workflow IS NULL"

    drop constraint(:stacks, :stacks_choice_check)
    drop constraint(:stacks, :stacks_harness_or_workflow)

    create constraint(:stacks, :stacks_harness_or_workflow,
             check: "harness IS NOT NULL OR workflow IS NOT NULL"
           )

    alter table(:stacks) do
      remove :choice
    end
  end
end
