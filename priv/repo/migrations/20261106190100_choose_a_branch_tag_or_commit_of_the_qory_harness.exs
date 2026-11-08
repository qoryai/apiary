defmodule Apiary.Repo.Migrations.ChooseABranchTagOrCommitOfTheQoryHarness do
  use Ecto.Migration

  # A harness choice of the Qory harness takes a branch, a tag or a commit, as a choice of
  # a harness repository does (`Apiary.Stacks`): the versions `latest` and `named`, which
  # read a commit the release listed, go.
  #
  # The check `stacks_version_check` takes `branch`, `tag` and `commit` under both
  # choices, each with its name. Every row of the choice `qory` at `latest` or `named`, or
  # with no version, becomes the branch `main`, the branch a workspace with no choice
  # follows, and its document's `ref` becomes `main` too. So does the document of a
  # target's row of the Qory harness at `workspace`, whose `ref` is read only where the
  # workspace's harness is another. The documents of these rows are the text a save
  # wrote, one line per key, so the line of `ref` is replaced as written.
  #
  # Rolled back, the check is as before, and each row of the Qory harness at a branch
  # becomes `latest`; the documents keep `main`. The roll back raises an error while a row
  # of the Qory harness is at a tag or a commit.
  @ref_line "E'\\n  ref: [^\\n]*\\n'"
  @main_line ~s|E'\\n  ref: "main"\\n'|

  def up do
    drop constraint(:stacks, :stacks_version_check)

    execute """
    UPDATE stacks
    SET version_kind = 'branch',
        version_name = 'main',
        harness = regexp_replace(harness, #{@ref_line}, #{@main_line})
    WHERE choice = 'qory'
      AND (version_kind IS NULL OR version_kind IN ('latest', 'named'))
    """

    execute """
    UPDATE stacks
    SET harness = regexp_replace(harness, #{@ref_line}, #{@main_line})
    WHERE choice = 'qory' AND version_kind = 'workspace'
    """

    create constraint(:stacks, :stacks_version_check,
             check: """
             (version_kind IS NULL AND version_name IS NULL)
             OR (choice IS NOT NULL
                 AND COALESCE(version_kind, '') IN ('branch', 'tag', 'commit')
                 AND version_name IS NOT NULL)
             OR (choice IS NOT NULL AND COALESCE(version_kind, '') = 'workspace'
                 AND target_id IS NOT NULL AND version_name IS NULL)
             """
           )
  end

  # A rollback turns a row of the Qory harness's choice at any branch, `main` or another,
  # back into `latest`: a row at a branch other than `main` then follows `main` again. It
  # refuses rows at a tag or a commit, which `latest` would change more.
  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM stacks
                 WHERE choice = 'qory' AND version_kind IN ('tag', 'commit')) THEN
        RAISE EXCEPTION 'Choose the Qory harness at a branch in each workspace set to a tag or a commit, then roll back again: the check before this migration refuses them'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    drop constraint(:stacks, :stacks_version_check)

    execute """
    UPDATE stacks SET version_kind = 'latest', version_name = NULL
    WHERE choice = 'qory' AND version_kind = 'branch'
    """

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
  end
end
