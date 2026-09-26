defmodule Apiary.Repo.Migrations.CopyPolicyChangesIntoAuditEntries do
  use Ecto.Migration

  # The history of the security policy becomes a part of the audit trail: every row of
  # `policy_changes` is copied into `audit_entries`, under its own id, and each run
  # configuration names the entry of the change that rendered it, which is the id its
  # `policy_change_id` holds. A change of mode is `security_policy.set_mode`, a lock or an
  # unlock `security_policy.lock`, every other change `security_policy.edit`; its subject
  # is the target it changed, or the workspace for the baseline; its author, or the
  # instance for a change nobody made (a render again after an upgrade). `details` keeps
  # what the policy page shows of it: the kind of change, the host or credential it is
  # about and the version it left in force.
  #
  # `policy_changes` is no longer read, and is written for one release more, each row
  # under the id of its change's entry (`Apiary.Policy.ChangeRow`), so the release before
  # can run after a rollback. The release that drops it runs this copy again first: the
  # rows written since are in the trail already, and a row a rolled-back release wrote
  # meanwhile is copied then. A data migration apart from the schema's: two statements,
  # over tables of a few rows per change of a policy. Copying twice copies nothing more.
  # Reversible: rolling it back deletes the copies and clears the configurations'
  # references to them.
  def up do
    execute("""
    INSERT INTO audit_entries (
      id, organisation_id, workspace_id, actor_kind, actor_id, action, subject_kind,
      subject_id, before, after, details, worker, inserted_at
    )
    SELECT
      c.id,
      c.organisation_id,
      c.workspace_id,
      CASE WHEN c.changed_by_id IS NULL THEN 'instance' ELSE 'person' END,
      c.changed_by_id,
      CASE c.action
        WHEN 'mode_changed' THEN 'security_policy.set_mode'
        WHEN 'rule_locked' THEN 'security_policy.lock'
        WHEN 'rule_unlocked' THEN 'security_policy.lock'
        ELSE 'security_policy.edit'
      END,
      CASE WHEN c.target_id IS NULL THEN 'workspace' ELSE 'target' END,
      COALESCE(c.target_id, c.workspace_id),
      c.before,
      c.after,
      jsonb_strip_nulls(
        jsonb_build_object('change', c.action, 'subject', c.subject, 'version', c.version_after)
      ),
      CASE WHEN c.action = 'rerendered' THEN 'mix apiary.policy.rerender' END,
      c.inserted_at
    FROM policy_changes c
    ON CONFLICT (id) DO NOTHING
    """)

    execute("""
    UPDATE run_configurations
    SET audit_entry_id = policy_change_id
    WHERE policy_change_id IS NOT NULL AND audit_entry_id IS NULL
    """)
  end

  def down do
    execute("""
    UPDATE run_configurations
    SET audit_entry_id = NULL
    WHERE audit_entry_id IS NOT NULL AND audit_entry_id = policy_change_id
    """)

    execute("DELETE FROM audit_entries WHERE id IN (SELECT id FROM policy_changes)")
  end
end
