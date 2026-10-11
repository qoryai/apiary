defmodule Apiary.Repo.Migrations.LetANodeChooseItsGateway do
  use Ecto.Migration

  # How a node or a node pool reaches Qory Apiary (`Apiary.Gateways.resolve/1`):
  # `gateway_choice` is `direct`, `default` (the default gateway of its workspace, resolved
  # at each registration) or `named`, with the named gateway in `gateway_id`. Every row
  # that is there when the column is added is `direct`, which is what every node does
  # today, and so is a row written without one. A gateway itself is always `direct`.
  #
  # `gateway_id` is a plain reference to the gateway's own row, not the composite key a
  # node's other references use: whether a gateway may serve the node's workspace is the
  # application's rule (`Apiary.Gateways.may_serve?/2`), not "the same workspace". The
  # trigger `nodes_gateway_is_a_gateway` refuses a reference, made or changed, to a row that
  # is not a gateway in use.
  #
  # When the gateway's row itself goes, with the purge of its workspace or organisation, the
  # reference is set NULL and the choice stays `named`: the purge is never held up by
  # another workspace's or organisation's nodes that name the gateway, and such a node does
  # not quietly become direct. It names a gateway that is gone, and its registrations are
  # refused until someone chooses again. The check lets `gateway_id` be NULL under `named`
  # for that; the application requires a gateway when the choice is made.
  #
  # nodes is a small table, so the checks are made and validated at once.
  def up do
    alter table(:nodes) do
      add :gateway_choice, :string, null: false, default: "direct"
      add :gateway_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:nodes, :nodes_gateway_choice_check,
             check:
               "gateway_choice IN ('direct', 'default', 'named') AND " <>
                 "(gateway_id IS NULL OR gateway_choice = 'named') AND " <>
                 "(kind <> 'gateway' OR gateway_choice = 'direct')"
           )

    create index(:nodes, [:gateway_id], where: "gateway_id IS NOT NULL")

    execute("""
    CREATE FUNCTION nodes_gateway_is_a_gateway() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.gateway_id IS NOT NULL
         AND (TG_OP = 'INSERT' OR NEW.gateway_id IS DISTINCT FROM OLD.gateway_id)
         AND NOT EXISTS (
           SELECT 1 FROM nodes
           WHERE id = NEW.gateway_id AND kind = 'gateway' AND deleted_at IS NULL
         ) THEN
        RAISE EXCEPTION 'a node''s gateway is a gateway in use'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'nodes_gateway_is_a_gateway';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER nodes_gateway_is_a_gateway BEFORE INSERT OR UPDATE OF gateway_id ON nodes
    FOR EACH ROW EXECUTE FUNCTION nodes_gateway_is_a_gateway()
    """)
  end

  # Rolled back, every node is direct again, as it was before.
  def down do
    execute("DROP TRIGGER nodes_gateway_is_a_gateway ON nodes")
    execute("DROP FUNCTION nodes_gateway_is_a_gateway()")

    drop index(:nodes, [:gateway_id], where: "gateway_id IS NOT NULL")
    drop constraint(:nodes, :nodes_gateway_choice_check)

    alter table(:nodes) do
      remove :gateway_id
      remove :gateway_choice
    end
  end
end
