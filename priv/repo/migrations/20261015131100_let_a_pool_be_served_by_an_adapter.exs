defmodule Apiary.Repo.Migrations.LetAPoolBeServedByAnAdapter do
  use Ecto.Migration

  # A node pool may name the adapter that serves it, `served_by_id`, an adapter in use of
  # the pool's organisation. Only a pool names one (`nodes_served_by_check`); every row
  # that is there when the column is added names none.
  #
  # `served_by_id` is a plain reference to the adapter's row. The trigger
  # `nodes_served_by_is_an_adapter` refuses a reference, made or changed, to a row that is
  # not an adapter in use of the same organisation, and holds that row `FOR SHARE` for the
  # rest of the transaction, so the adapter's deletion, which clears the pools it serves
  # under the adapter's row held `FOR UPDATE`, either comes first and is seen, or waits and
  # finds the pool. When the adapter's row itself goes, with the purge of its
  # organisation, the reference is set NULL.
  #
  # The check is added NOT VALID, so adding it scans no row under a lock that blocks
  # writes to `nodes`; a later migration validates it
  # (`20261015131200_validate_an_adapter_s_checks`).
  def up do
    alter table(:nodes) do
      add :served_by_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_served_by_check
      CHECK (served_by_id IS NULL OR kind = 'pool') NOT VALID
    """

    create index(:nodes, [:served_by_id], where: "served_by_id IS NOT NULL")

    execute """
    CREATE FUNCTION nodes_served_by_is_an_adapter() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.served_by_id IS NOT NULL
         AND (TG_OP = 'INSERT' OR NEW.served_by_id IS DISTINCT FROM OLD.served_by_id) THEN
        PERFORM 1 FROM nodes
          WHERE id = NEW.served_by_id AND kind = 'adapter' AND deleted_at IS NULL
            AND organisation_id = NEW.organisation_id
          FOR SHARE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'a pool is served by an adapter in use of its organisation'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'nodes_served_by_is_an_adapter';
        END IF;
      END IF;

      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER nodes_served_by_is_an_adapter
    BEFORE INSERT OR UPDATE OF served_by_id ON nodes
    FOR EACH ROW EXECUTE FUNCTION nodes_served_by_is_an_adapter()
    """
  end

  # Rolled back, no pool names an adapter.
  def down do
    execute "DROP TRIGGER nodes_served_by_is_an_adapter ON nodes"
    execute "DROP FUNCTION nodes_served_by_is_an_adapter()"

    drop index(:nodes, [:served_by_id], where: "served_by_id IS NOT NULL")
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_served_by_check"

    alter table(:nodes) do
      remove :served_by_id
    end
  end
end
