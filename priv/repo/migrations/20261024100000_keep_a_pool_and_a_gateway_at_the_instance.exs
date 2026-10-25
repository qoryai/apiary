defmodule Apiary.Repo.Migrations.KeepAPoolAndAGatewayAtTheInstance do
  use Ecto.Migration

  # The instance may have one node pool and one gateway, with no organisation and no
  # workspace, as an adapter has: the pool takes the runs of every workspace that has no
  # pool in use, and the gateway serves every workspace.
  #
  # - `nodes_place_check`: a workspace means an organisation; a node always has a
  #   workspace; an adapter never has an organisation; a pool has a workspace, or neither a
  #   workspace nor an organisation. A gateway lives at a workspace, at an organisation, or
  #   at the instance.
  # - `nodes_place_fixed` fires on a change of `organisation_id` too: a node with an
  #   organisation never loses it, which `nodes_place_check` held before for every kind but
  #   an adapter.
  # - `nodes_instance_kind_index`: one pool and one gateway in use at the instance. Their
  #   names are unique by that index, and the instance's gateway is its level's default
  #   by rule, so no name or default index holds them.
  # - `nodes_installed_as_check` and `nodes_installed_as_index`: the instance's pool and
  #   gateway have the name of their code folder as an installed adapter has, and one name
  #   is in use once among all three kinds, as the folders share one directory.
  # - The keys of `dispatches.pool_id`, `environments.pool_id`, `dispatch_runs.pool_id` and
  #   `runs.node_id` were composite with the row's workspace, which refuses the instance's
  #   pool for a row with a workspace. Each becomes a plain key to `nodes`, with the same
  #   `ON DELETE`, and the trigger `pool_place_matches` holds the place: the node is of
  #   the row's workspace, or is the instance's pool.
  # - `node_instances.organisation_id` may be NULL for an instance node, and then the row
  #   has no workspace either (`node_instances_place_check`). `node_instances_node_fkey`
  #   holds such a row to its node, which the composite keys do not.
  #
  # The checks and keys are added NOT VALID, so the change scans no row under a lock that
  # blocks writes to the tables; `20261024100100_validate_the_instance_node_checks`
  # validates them.
  @name "'^[a-z][a-z0-9-]{0,31}$'"
  @pool_tables [
    {"dispatches", "pool_id"},
    {"environments", "pool_id"},
    {"dispatch_runs", "pool_id"},
    {"runs", "node_id"}
  ]

  def up do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_place_check"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check CHECK (
      (workspace_id IS NULL OR organisation_id IS NOT NULL) AND
      (kind <> 'node' OR workspace_id IS NOT NULL) AND
      (kind <> 'adapter' OR organisation_id IS NULL) AND
      (kind <> 'pool' OR workspace_id IS NOT NULL OR organisation_id IS NULL)
    ) NOT VALID
    """

    execute """
    CREATE OR REPLACE FUNCTION nodes_place_is_fixed() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id
         OR NEW.organisation_id IS DISTINCT FROM OLD.organisation_id THEN
        RAISE EXCEPTION 'a node''s place is fixed when it is made'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'nodes_place_fixed';
      END IF;
      RETURN NEW;
    END
    $$
    """

    execute "DROP TRIGGER nodes_place_fixed ON nodes"

    execute """
    CREATE TRIGGER nodes_place_fixed BEFORE UPDATE OF workspace_id, organisation_id ON nodes
    FOR EACH ROW EXECUTE FUNCTION nodes_place_is_fixed()
    """

    create unique_index(:nodes, [:kind],
             where:
               "organisation_id IS NULL AND kind IN ('pool', 'gateway') AND deleted_at IS NULL",
             name: :nodes_instance_kind_index
           )

    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_installed_as_check"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_installed_as_check CHECK (
      installed_as IS NULL OR (
        installed_as ~ #{@name} AND
        (kind = 'adapter' OR (kind IN ('pool', 'gateway') AND organisation_id IS NULL))
      )
    ) NOT VALID
    """

    drop index(:nodes, [:installed_as], name: :nodes_installed_as_index)

    create unique_index(:nodes, [:installed_as],
             where: "installed_as IS NOT NULL AND deleted_at IS NULL",
             name: :nodes_installed_as_index
           )

    execute "ALTER TABLE dispatches DROP CONSTRAINT dispatches_pool_id_fkey"

    execute """
    ALTER TABLE dispatches ADD CONSTRAINT dispatches_pool_id_fkey
      FOREIGN KEY (pool_id) REFERENCES nodes (id) NOT VALID
    """

    execute "ALTER TABLE environments DROP CONSTRAINT environments_pool_id_fkey"

    execute """
    ALTER TABLE environments ADD CONSTRAINT environments_pool_id_fkey
      FOREIGN KEY (pool_id) REFERENCES nodes (id) NOT VALID
    """

    execute "ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_pool_id_fkey"

    execute """
    ALTER TABLE dispatch_runs ADD CONSTRAINT dispatch_runs_pool_id_fkey
      FOREIGN KEY (pool_id) REFERENCES nodes (id) NOT VALID
    """

    execute "ALTER TABLE runs DROP CONSTRAINT runs_node_id_fkey"

    execute """
    ALTER TABLE runs ADD CONSTRAINT runs_node_id_fkey
      FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE SET NULL NOT VALID
    """

    # The node a row names, in `TG_ARGV[0]`, `pool_id` or `node_id`: of the row's workspace,
    # or the instance's pool. A node that is not there is left to the key. The trigger
    # fires on every insert and update, with no column list, so that a migration rolled
    # back may drop the column; an update that keeps both columns returns at once.
    execute """
    CREATE FUNCTION pool_place_matches() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      named uuid;
      named_before uuid;
    BEGIN
      IF TG_ARGV[0] = 'node_id' THEN
        named := NEW.node_id;
      ELSE
        named := NEW.pool_id;
      END IF;

      IF named IS NULL THEN
        RETURN NEW;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF TG_ARGV[0] = 'node_id' THEN
          named_before := OLD.node_id;
        ELSE
          named_before := OLD.pool_id;
        END IF;

        IF named = named_before AND NEW.workspace_id IS NOT DISTINCT FROM OLD.workspace_id THEN
          RETURN NEW;
        END IF;
      END IF;

      IF EXISTS (
        SELECT 1 FROM nodes n
          WHERE n.id = named
            AND n.workspace_id IS DISTINCT FROM NEW.workspace_id
            AND NOT (n.organisation_id IS NULL AND n.kind = 'pool')
      ) THEN
        RAISE EXCEPTION 'a row''s node is of its workspace, or is the instance''s pool'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'pool_place_matches';
      END IF;

      RETURN NEW;
    END
    $$
    """

    for {table, column} <- @pool_tables do
      execute """
      CREATE TRIGGER #{table}_pool_place_matches
      BEFORE INSERT OR UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION pool_place_matches('#{column}')
      """
    end

    execute "ALTER TABLE node_instances ALTER COLUMN organisation_id DROP NOT NULL"

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_place_check
      CHECK (organisation_id IS NOT NULL OR workspace_id IS NULL) NOT VALID
    """

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_node_fkey
      FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE CASCADE NOT VALID
    """
  end

  # Rolled back, a pool always has a workspace and every row's node is of the row's
  # workspace again. The instance's pool and gateway, their instances and the rows that
  # name them could not stay, so the rollback refuses while any of them is there, deleted
  # ones included, rather than delete them.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1 FROM nodes WHERE organisation_id IS NULL AND kind IN ('pool', 'gateway')
         )
         OR EXISTS (SELECT 1 FROM node_instances WHERE organisation_id IS NULL) THEN
        RAISE EXCEPTION 'nodes holds the instance''s pool or gateway: delete their rows before rolling this back';
      END IF;
    END
    $$
    """)

    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_node_fkey"
    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_place_check"
    execute "ALTER TABLE node_instances ALTER COLUMN organisation_id SET NOT NULL"

    for {table, _column} <- Enum.reverse(@pool_tables) do
      execute "DROP TRIGGER #{table}_pool_place_matches ON #{table}"
    end

    execute "DROP FUNCTION pool_place_matches()"

    execute "ALTER TABLE runs DROP CONSTRAINT runs_node_id_fkey"

    execute """
    ALTER TABLE runs ADD CONSTRAINT runs_node_id_fkey
      FOREIGN KEY (node_id, workspace_id) REFERENCES nodes (id, workspace_id)
      ON DELETE SET NULL (node_id)
    """

    execute "ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_pool_id_fkey"

    execute """
    ALTER TABLE dispatch_runs ADD CONSTRAINT dispatch_runs_pool_id_fkey
      FOREIGN KEY (pool_id, workspace_id) REFERENCES nodes (id, workspace_id)
    """

    execute "ALTER TABLE environments DROP CONSTRAINT environments_pool_id_fkey"

    execute """
    ALTER TABLE environments ADD CONSTRAINT environments_pool_id_fkey
      FOREIGN KEY (pool_id, workspace_id) REFERENCES nodes (id, workspace_id) MATCH FULL
    """

    execute "ALTER TABLE dispatches DROP CONSTRAINT dispatches_pool_id_fkey"

    execute """
    ALTER TABLE dispatches ADD CONSTRAINT dispatches_pool_id_fkey
      FOREIGN KEY (pool_id, workspace_id) REFERENCES nodes (id, workspace_id) MATCH FULL
    """

    drop index(:nodes, [:installed_as], name: :nodes_installed_as_index)

    create unique_index(:nodes, [:installed_as],
             where: "kind = 'adapter' AND installed_as IS NOT NULL AND deleted_at IS NULL",
             name: :nodes_installed_as_index
           )

    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_installed_as_check"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_installed_as_check CHECK (
      installed_as IS NULL OR (kind = 'adapter' AND installed_as ~ #{@name})
    )
    """

    drop index(:nodes, [:kind], name: :nodes_instance_kind_index)

    execute "DROP TRIGGER nodes_place_fixed ON nodes"

    execute """
    CREATE OR REPLACE FUNCTION nodes_place_is_fixed() RETURNS trigger LANGUAGE plpgsql AS $$
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

    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_place_check"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check CHECK (
      (workspace_id IS NOT NULL OR kind IN ('gateway', 'adapter')) AND
      (kind <> 'adapter' OR workspace_id IS NULL) AND
      (organisation_id IS NULL) = (kind = 'adapter')
    )
    """
  end
end
