defmodule Apiary.Repo.Migrations.LetAGatewayLiveAtAnOrganisation do
  use Ecto.Migration

  # A gateway may live at an organisation as well as at a workspace (`Apiary.Gateways`):
  # its row of `nodes` has no workspace (`workspace_id` NULL), and so have its access keys,
  # its enrolment codes and its instances. Only a gateway lives at an organisation: a node
  # or a node pool always has its workspace (`nodes_place_check`).
  #
  # The keys to the workspace were `MATCH FULL`, which refuses a row with an organisation and
  # no workspace; they become `MATCH SIMPLE`, so they hold a row that has a workspace, as
  # before, and leave one without. Each row of the three tables stays its node's, of the
  # node's organisation, by a new composite key `(node_id, organisation_id)` to the unique
  # `(id, organisation_id)` of `nodes`; an access key stays its enrolment code's by
  # `(enrolment_code_id, organisation_id)` beside the key it had. The trigger
  # `node_place_matches` refuses a row of the three without a workspace that names a node
  # with one: a row is at its node's place.
  #
  # An organisation's gateways have their own names, unique among its gateways in use
  # (`nodes_organisation_live_name_index`), and at most one default
  # (`nodes_organisation_default_gateway_index`), as a workspace's have.
  #
  # Nothing is backfilled: every row there keeps its workspace. The checks and keys are
  # added NOT VALID, so adding them scans no row under a lock that blocks writes; the next
  # migration validates them.
  @rows ~w(access_keys access_key_enrolment_codes node_instances)

  def up do
    # nodes
    execute "ALTER TABLE nodes ALTER COLUMN workspace_id DROP NOT NULL"
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_workspace_id_fkey"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check
      CHECK (workspace_id IS NOT NULL OR kind = 'gateway') NOT VALID
    """

    create unique_index(:nodes, [:id, :organisation_id])

    create unique_index(:nodes, [:organisation_id, :name],
             where: "workspace_id IS NULL AND deleted_at IS NULL",
             name: :nodes_organisation_live_name_index
           )

    create unique_index(:nodes, [:organisation_id],
             where: "default_gateway AND workspace_id IS NULL",
             name: :nodes_organisation_default_gateway_index
           )

    # access_key_enrolment_codes
    execute "ALTER TABLE access_key_enrolment_codes ALTER COLUMN workspace_id DROP NOT NULL"

    execute "ALTER TABLE access_key_enrolment_codes DROP CONSTRAINT access_key_enrolment_codes_workspace_id_fkey"

    execute "ALTER TABLE access_key_enrolment_codes DROP CONSTRAINT access_key_enrolment_codes_node_id_fkey"

    execute """
    ALTER TABLE access_key_enrolment_codes ADD CONSTRAINT access_key_enrolment_codes_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE access_key_enrolment_codes ADD CONSTRAINT access_key_enrolment_codes_node_id_fkey
      FOREIGN KEY (node_id, workspace_id) REFERENCES nodes (id, workspace_id)
      MATCH SIMPLE NOT VALID
    """

    execute """
    ALTER TABLE access_key_enrolment_codes ADD CONSTRAINT access_key_enrolment_codes_node_organisation_fkey
      FOREIGN KEY (node_id, organisation_id) REFERENCES nodes (id, organisation_id) NOT VALID
    """

    create unique_index(:access_key_enrolment_codes, [:id, :organisation_id])

    # access_keys
    execute "ALTER TABLE access_keys ALTER COLUMN workspace_id DROP NOT NULL"
    execute "ALTER TABLE access_keys DROP CONSTRAINT access_keys_workspace_id_fkey"

    execute """
    ALTER TABLE access_keys ADD CONSTRAINT access_keys_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE access_keys ADD CONSTRAINT access_keys_node_organisation_fkey
      FOREIGN KEY (node_id, organisation_id) REFERENCES nodes (id, organisation_id) NOT VALID
    """

    execute """
    ALTER TABLE access_keys ADD CONSTRAINT access_keys_enrolment_code_organisation_fkey
      FOREIGN KEY (enrolment_code_id, organisation_id)
      REFERENCES access_key_enrolment_codes (id, organisation_id) NOT VALID
    """

    # node_instances
    execute "ALTER TABLE node_instances ALTER COLUMN workspace_id DROP NOT NULL"
    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_workspace_id_fkey"
    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_node_id_fkey"

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_node_id_fkey
      FOREIGN KEY (node_id, workspace_id) REFERENCES nodes (id, workspace_id)
      MATCH SIMPLE ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_node_organisation_fkey
      FOREIGN KEY (node_id, organisation_id) REFERENCES nodes (id, organisation_id)
      ON DELETE CASCADE NOT VALID
    """

    # A row without a workspace names a node without one.
    execute """
    CREATE FUNCTION node_place_matches() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.workspace_id IS NULL AND NEW.node_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM nodes WHERE id = NEW.node_id AND workspace_id IS NULL
      ) THEN
        RAISE EXCEPTION 'a row without a workspace is of a node without one'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'node_place_matches';
      END IF;
      RETURN NEW;
    END
    $$
    """

    for table <- @rows do
      execute """
      CREATE TRIGGER #{table}_node_place_matches
      BEFORE INSERT OR UPDATE OF node_id, workspace_id ON #{table}
      FOR EACH ROW EXECUTE FUNCTION node_place_matches()
      """
    end
  end

  # Rolled back, every row has its workspace again. A gateway at an organisation, and its
  # keys, codes and instances, could not stay, so the rollback refuses while any row
  # without a workspace is there, deleted ones included, rather than delete them.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM nodes WHERE workspace_id IS NULL)
         OR EXISTS (SELECT 1 FROM access_keys WHERE workspace_id IS NULL)
         OR EXISTS (SELECT 1 FROM access_key_enrolment_codes WHERE workspace_id IS NULL)
         OR EXISTS (SELECT 1 FROM node_instances WHERE workspace_id IS NULL) THEN
        RAISE EXCEPTION 'nodes holds gateways of organisations: delete their rows before rolling this back';
      END IF;
    END
    $$
    """)

    for table <- Enum.reverse(@rows) do
      execute "DROP TRIGGER #{table}_node_place_matches ON #{table}"
    end

    execute "DROP FUNCTION node_place_matches()"

    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_node_organisation_fkey"
    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_node_id_fkey"
    execute "ALTER TABLE node_instances DROP CONSTRAINT node_instances_workspace_id_fkey"

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_node_id_fkey
      FOREIGN KEY (node_id, workspace_id) REFERENCES nodes (id, workspace_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute """
    ALTER TABLE node_instances ADD CONSTRAINT node_instances_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute "ALTER TABLE node_instances ALTER COLUMN workspace_id SET NOT NULL"

    execute "ALTER TABLE access_keys DROP CONSTRAINT access_keys_enrolment_code_organisation_fkey"
    execute "ALTER TABLE access_keys DROP CONSTRAINT access_keys_node_organisation_fkey"
    execute "ALTER TABLE access_keys DROP CONSTRAINT access_keys_workspace_id_fkey"

    execute """
    ALTER TABLE access_keys ADD CONSTRAINT access_keys_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute "ALTER TABLE access_keys ALTER COLUMN workspace_id SET NOT NULL"

    drop index(:access_key_enrolment_codes, [:id, :organisation_id])

    execute "ALTER TABLE access_key_enrolment_codes DROP CONSTRAINT access_key_enrolment_codes_node_organisation_fkey"

    execute "ALTER TABLE access_key_enrolment_codes DROP CONSTRAINT access_key_enrolment_codes_node_id_fkey"

    execute "ALTER TABLE access_key_enrolment_codes DROP CONSTRAINT access_key_enrolment_codes_workspace_id_fkey"

    execute """
    ALTER TABLE access_key_enrolment_codes ADD CONSTRAINT access_key_enrolment_codes_node_id_fkey
      FOREIGN KEY (node_id, workspace_id) REFERENCES nodes (id, workspace_id) MATCH FULL
    """

    execute """
    ALTER TABLE access_key_enrolment_codes ADD CONSTRAINT access_key_enrolment_codes_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute "ALTER TABLE access_key_enrolment_codes ALTER COLUMN workspace_id SET NOT NULL"

    drop index(:nodes, [:organisation_id], name: :nodes_organisation_default_gateway_index)
    drop index(:nodes, [:organisation_id, :name], name: :nodes_organisation_live_name_index)
    drop index(:nodes, [:id, :organisation_id])

    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_place_check"
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_workspace_id_fkey"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_workspace_id_fkey
      FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute "ALTER TABLE nodes ALTER COLUMN workspace_id SET NOT NULL"
  end
end
