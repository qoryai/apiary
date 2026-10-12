defmodule Apiary.Repo.Migrations.MakeAGatewayAKindOfNode do
  use Ecto.Migration

  # A gateway is a third kind of node (`Apiary.Nodes`, `Apiary.Gateways`): kind `gateway`,
  # public id `ng_` and sixteen lowercase Crockford base32 characters, no instance limit
  # (NULL), and an address, `url`, which a gateway must have and a node or a node pool
  # never has: at most 2048 characters, a scheme and a host with an optional port and
  # nothing after them. A later migration holds it to https
  # (`20261011150300_hold_a_gateway_s_address_to_https`). The checks of the kind, the
  # public id and the limit widen to it; the trigger `nodes_kind_fixed` still refuses a
  # change of kind.
  #
  # `default_gateway` marks a workspace's default gateway: only a gateway in use holds it,
  # and the partial unique index holds a workspace to one at most. Every row is false
  # when the column is added.
  #
  # nodes is a small table, so the checks are made and validated at once.
  @public_id "^(nd|np|ng)_[0-9a-hjkmnp-tv-z]{16}$"
  @old_public_id "^(nd|np)_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    drop constraint(:nodes, :nodes_kind_check)
    drop constraint(:nodes, :nodes_public_id_check)
    drop constraint(:nodes, :nodes_instance_limit_check)

    create constraint(:nodes, :nodes_kind_check, check: "kind IN ('node', 'pool', 'gateway')")

    create constraint(:nodes, :nodes_public_id_check,
             check:
               "public_id ~ '#{@public_id}' AND " <>
                 "(kind = 'node') = (public_id LIKE 'nd\\_%') AND " <>
                 "(kind = 'pool') = (public_id LIKE 'np\\_%') AND " <>
                 "(kind = 'gateway') = (public_id LIKE 'ng\\_%')"
           )

    create constraint(:nodes, :nodes_instance_limit_check,
             check:
               "(kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR " <>
                 "(kind = 'pool' AND (instance_limit IS NULL OR " <>
                 "instance_limit BETWEEN 1 AND 10000)) OR " <>
                 "(kind = 'gateway' AND instance_limit IS NULL)"
           )

    alter table(:nodes) do
      add :url, :text
      add :default_gateway, :boolean, null: false, default: false
    end

    create constraint(:nodes, :nodes_url_check,
             check:
               "(kind = 'gateway') = (url IS NOT NULL) AND " <>
                 "(url IS NULL OR (char_length(url) <= 2048 AND " <>
                 "url ~ '^https?://[^/?#@[:space:]]+$'))"
           )

    create constraint(:nodes, :nodes_default_gateway_check,
             check: "NOT default_gateway OR (kind = 'gateway' AND deleted_at IS NULL)"
           )

    create unique_index(:nodes, [:workspace_id],
             where: "default_gateway",
             name: :nodes_default_gateway_index
           )
  end

  # Rolled back, a node is a node or a node pool again. A gateway's row could not stay, and
  # its keys, codes and instances name it, so the rollback refuses while any gateway row is
  # there, deleted ones included, rather than delete them.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM nodes WHERE kind = 'gateway') THEN
        RAISE EXCEPTION 'nodes holds gateways: delete their rows before rolling this back';
      END IF;
    END
    $$
    """)

    drop index(:nodes, [:workspace_id], name: :nodes_default_gateway_index)
    drop constraint(:nodes, :nodes_default_gateway_check)
    drop constraint(:nodes, :nodes_url_check)

    alter table(:nodes) do
      remove :default_gateway
      remove :url
    end

    drop constraint(:nodes, :nodes_instance_limit_check)
    drop constraint(:nodes, :nodes_public_id_check)
    drop constraint(:nodes, :nodes_kind_check)

    create constraint(:nodes, :nodes_kind_check, check: "kind IN ('node', 'pool')")

    create constraint(:nodes, :nodes_public_id_check,
             check:
               "public_id ~ '#{@old_public_id}' AND " <>
                 "(kind = 'node') = (public_id LIKE 'nd\\_%') AND " <>
                 "(kind = 'pool') = (public_id LIKE 'np\\_%')"
           )

    create constraint(:nodes, :nodes_instance_limit_check,
             check:
               "(kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR " <>
                 "(kind = 'pool' AND (instance_limit IS NULL OR " <>
                 "instance_limit BETWEEN 1 AND 10000))"
           )
  end
end
