defmodule Apiary.Repo.Migrations.KeepTheVersionOfAHarnessChoice do
  use Ecto.Migration

  # The version of a harness choice (`Apiary.Stacks`), on a row with a choice:
  #
  #   * `version_kind`, text, NULL for the document's `ref` as the save wrote it:
  #     * `latest` and `named`, under the choice `qory`: the newest version of the Qory
  #       harness the release ships, or the named version `version_name`;
  #     * `branch`, `tag` and `commit`, under the choice `repository`: the newest commit
  #       of the branch `version_name` when each run starts; the tag `version_name`; the
  #       commit whose full id is `version_name`;
  #     * `workspace`, on a target's row: the version of the workspace's harness.
  #   * `version_name`, text: the name of a named version, a branch or a tag, or a full
  #     commit id.
  #
  # The check `stacks_version_check` takes a version only on a row with a choice, each
  # kind under its choice and with its name, and `workspace` only on a target's row. Its
  # terms read a NULL as no value, so no term is unknown: a check that is unknown passes.
  #
  # Each saved choice of the Qory harness at the commit fe3b3ab, the one commit the save
  # wrote before this migration, becomes `latest`. Its document, the text the save wrote,
  # is matched as written. Any other row keeps no version, and a run reads its document's
  # `ref`, as before.
  #
  # Rolled back, the two columns go with their check. A row at `latest` keeps the
  # document the save wrote, at fe3b3ab.
  @qory_document "extends:\n" <>
                   "  git: \"https://github.com/qoryai/harness\"\n" <>
                   "  ref: \"fe3b3ab4a02cd7c57d9efa16bbaf498d5f5de305\"\n" <>
                   "  stack: \"core\"\n"

  def up do
    alter table(:stacks) do
      add :version_kind, :text
      add :version_name, :text
    end

    create constraint(:stacks, :stacks_version_check,
             check: """
             (version_kind IS NULL AND version_name IS NULL)
             OR (COALESCE(choice, '') = 'qory' AND COALESCE(version_kind, '') = 'latest'
                 AND version_name IS NULL)
             OR (COALESCE(choice, '') = 'qory' AND COALESCE(version_kind, '') = 'named'
                 AND version_name IS NOT NULL)
             OR (COALESCE(choice, '') = 'repository'
                 AND COALESCE(version_kind, '') IN ('branch', 'tag', 'commit')
                 AND version_name IS NOT NULL)
             OR (choice IS NOT NULL AND COALESCE(version_kind, '') = 'workspace'
                 AND target_id IS NOT NULL AND version_name IS NULL)
             """
           )

    execute fn ->
      repo().query!(
        "UPDATE stacks SET version_kind = 'latest' WHERE choice = 'qory' AND harness = $1",
        [@qory_document]
      )
    end
  end

  def down do
    drop constraint(:stacks, :stacks_version_check)

    alter table(:stacks) do
      remove :version_kind
      remove :version_name
    end
  end
end
