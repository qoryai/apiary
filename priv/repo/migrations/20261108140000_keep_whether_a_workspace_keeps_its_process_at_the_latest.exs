defmodule Apiary.Repo.Migrations.KeepWhetherAWorkspaceKeepsItsProcessAtTheLatest do
  use Ecto.Migration

  # `workspaces.keep_process_latest`: whether each later commit of the branch the
  # workspace's harness follows is saved as a version of its process
  # (`Apiary.Processes.HarnessUpdate`). Nil until a person sets it or saves edits to the
  # process. Nil reads as on for the Qory harness and off for a harness repository, and
  # off where version 1 is a version of the workspace type's default process that an
  # instance admin saved (Instance settings › Workspace types): that version has no
  # author, and counts as a person's saved edit.
  #
  # A workspace whose current version a person saved has edits that an update from the
  # harness would replace, so its switch is off, and so is the switch of a workspace
  # whose version 1 an instance admin saved. Adding a column that may be empty, with no
  # default, rewrites no row; the updates write only those workspaces' rows.
  def up do
    alter table(:workspaces) do
      add :keep_process_latest, :boolean
    end

    flush()

    execute("""
    UPDATE workspaces AS w SET keep_process_latest = false
    FROM process_versions AS v
    WHERE v.workspace_id = w.id AND v.status = 'current' AND v.author_id IS NOT NULL
    """)

    execute("""
    UPDATE workspaces AS w SET keep_process_latest = false
    FROM process_versions AS v, type_template_versions AS t
    WHERE v.workspace_id = w.id AND v.number = 1
      AND t.type = v.template->>'type' AND t.number::text = v.template->>'version'
      AND t.author_id IS NOT NULL
    """)
  end

  def down do
    alter table(:workspaces) do
      remove :keep_process_latest
    end
  end
end
