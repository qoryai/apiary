defmodule Apiary.Repo.Migrations.FixANodeSPlace do
  use Ecto.Migration

  # A node's place, its workspace or none for a gateway of an organisation, is fixed when it
  # is made, as its kind is (`nodes_kind_fixed`): its access keys, enrolment codes and
  # instances are at its place (`node_place_matches`), and a node that moved would leave
  # them behind. The trigger `nodes_place_fixed` refuses a change of `nodes.workspace_id`.
  # A workspace's deletion deletes its nodes, and changes none. Nothing is backfilled.

  def up do
    execute """
    CREATE FUNCTION nodes_place_is_fixed() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id THEN
        RAISE EXCEPTION 'a node''s place is fixed when it is made'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'nodes_place_fixed';
      END IF;
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER nodes_place_fixed BEFORE UPDATE OF workspace_id ON nodes
    FOR EACH ROW EXECUTE FUNCTION nodes_place_is_fixed()
    """
  end

  def down do
    execute "DROP TRIGGER nodes_place_fixed ON nodes"
    execute "DROP FUNCTION nodes_place_is_fixed()"
  end
end
