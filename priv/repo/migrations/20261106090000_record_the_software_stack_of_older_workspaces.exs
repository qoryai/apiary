defmodule Apiary.Repo.Migrations.RecordTheSoftwareStackOfOlderWorkspaces do
  use Ecto.Migration

  # A workspace made from the Qory template records the stack `software` when it is
  # created (`Apiary.Organisations.Workspace.put_qory_stack/2`). A workspace made before
  # `workspaces.qory_stack` (20261102160000) has no stack, so its runs use the Qory harness
  # at `core`, which lists no workflow, and Explore never finds `explore-a-ticket`.
  #
  # Up records `software` on each workspace of the software domain with no stack, made
  # before 20261102160000 ran, except one made from a template of a harness repository:
  # its version 1 records the source `repository` (`Apiary.Stacks.Sources.save_start/3`),
  # and creation leaves it with no stack. A workspace made after 20261102160000 with no
  # stack, such as one from `Apiary.Organisations.create_workspace/2`, stays without one.
  #
  # A Qory harness row (`choice` `qory`) stores the stack of its workspace when it was
  # saved, and `Apiary.Stacks.Sources.chosen/1` reads the row before the column. Up first
  # writes `software` for `core` in two kinds of row. The first is the row of a workspace
  # that up updates. The second is the row an organisation shares, when every workspace
  # that reads it has the stack `software` after up. A workspace reads the shared row when
  # no row with a choice has its workspace id and no target. A shared row that another
  # workspace reads at `core` stays. A row chosen for a target is a person's choice, and
  # stays.
  #
  # Down changes nothing: a workspace that up updated cannot be told from one made with
  # the stack.

  @workspaces """
  SELECT w.id FROM workspaces w
  WHERE w.qory_stack IS NULL AND w.domain = 'software'
    AND w.inserted_at <
      (SELECT m.inserted_at FROM schema_migrations m WHERE m.version = 20261102160000)
    AND NOT EXISTS (
      SELECT 1 FROM process_versions v
      WHERE v.workspace_id = w.id AND v.number = 1 AND v.template->>'source' = 'repository'
    )
  """

  @core ~s(\n  stack: "core"\n)
  @software ~s(\n  stack: "software"\n)

  def up do
    execute("""
    UPDATE stacks s
    SET harness = replace(s.harness, '#{@core}', '#{@software}'), updated_at = now()
    WHERE s.choice = 'qory' AND s.target_id IS NULL AND s.workflow IS NULL
      AND strpos(s.harness, '#{@core}') > 0
      AND (
        s.workspace_id IN (#{@workspaces})
        OR (
          s.workspace_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM workspaces r
            WHERE r.organisation_id = s.organisation_id AND r.qory_stack IS NULL
              AND r.id NOT IN (#{@workspaces})
              AND NOT EXISTS (
                SELECT 1 FROM stacks o
                WHERE o.workspace_id = r.id AND o.target_id IS NULL AND o.workflow IS NULL
                  AND o.choice IS NOT NULL
              )
          )
        )
      )
    """)

    execute("UPDATE workspaces SET qory_stack = 'software' WHERE id IN (#{@workspaces})")
  end

  def down, do: :ok
end
