defmodule Apiary.Repo.Migrations.LetAnInvitationHaveNoWorkspace do
  use Ecto.Migration

  # An invitation may have no workspace (`workspace_id` NULL): one sent while its
  # organisation has none, whose person joins the organisation and sets up its first
  # workspace (`Apiary.Organisations.invite_member/3`). That rule is the code's, checked
  # under the organisation's lock; the table allows the row.
  #
  # The key to the workspace keeps its columns (`workspace_id`, `organisation_id`) and
  # ON DELETE CASCADE, and becomes MATCH SIMPLE: MATCH FULL refuses a row whose
  # `organisation_id` is set while `workspace_id` is null. MATCH SIMPLE checks a row whose
  # two columns are set, so an invitation with a workspace is held to it as before, and
  # goes with it.
  #
  # Rolled back, `workspace_id` is required again and the key is MATCH FULL. The roll back
  # refuses while an invitation has no workspace, and changes nothing.
  @refusal "Qory Apiary keeps invitations with no workspace, so this migration rolls " <>
             "back only while every invitation has a workspace. One has none."

  def up do
    execute("""
    ALTER TABLE invitations DROP CONSTRAINT invitations_workspace_id_fkey,
      ADD CONSTRAINT invitations_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id)
      REFERENCES workspaces (id, organisation_id) MATCH SIMPLE ON DELETE CASCADE
    """)

    execute "ALTER TABLE invitations ALTER COLUMN workspace_id DROP NOT NULL"
  end

  def down do
    execute("LOCK TABLE invitations IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM invitations WHERE workspace_id IS NULL) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    execute "ALTER TABLE invitations ALTER COLUMN workspace_id SET NOT NULL"

    execute("""
    ALTER TABLE invitations DROP CONSTRAINT invitations_workspace_id_fkey,
      ADD CONSTRAINT invitations_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id)
      REFERENCES workspaces (id, organisation_id) MATCH FULL ON DELETE CASCADE
    """)
  end
end
