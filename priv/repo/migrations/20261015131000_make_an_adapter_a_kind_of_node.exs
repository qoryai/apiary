defmodule Apiary.Repo.Migrations.MakeAnAdapterAKindOfNode do
  use Ecto.Migration

  # An adapter is a fourth kind of node: kind `adapter`, public id `na_` and sixteen
  # lowercase Crockford base32 characters. It lives at its organisation alone, with no
  # workspace (`nodes_place_check`), has no instance limit, chooses no gateway (`direct`),
  # has no gateway address (`url`, held to gateways by `nodes_url_check`) and is never a
  # default gateway (`nodes_default_gateway_check`). Its keys, codes and instances are at
  # its place as a gateway's of an organisation are (`node_place_matches`), and its kind
  # and place are fixed when it is made (`nodes_kind_fixed`, `nodes_place_fixed`).
  #
  # Names: an organisation's gateways and its adapters each have names unique among
  # themselves in use. `nodes_organisation_live_name_index`, which held every node without
  # a workspace, holds gateways alone from now on, and
  # `nodes_organisation_adapter_name_index` holds the adapters. An adapter's name is at most
  # 64 characters (`nodes_adapter_name_check`), within the 80 every node has.
  #
  # Beside them, the columns only an adapter has, NULL on every other node
  # (`nodes_adapter_check`):
  #
  # - `connect_url`: the https address a person is sent to when they connect it, at most
  #   2048 characters, with no user information in its authority and no whitespace;
  # - `sync_interval`: how often, in seconds, its periodic check runs, set by a person; NULL
  #   for the adapter's default;
  # - `sync_default_interval` and `sync_minimum_interval`: the default and the shortest it
  #   declares, the minimum never above the default;
  # - `sync_sends_changes`: whether it declares that it sends changes as they happen.
  #
  # Every interval is 60 to 86400 seconds. All are NULL until the adapter first declares
  # them.
  #
  # The checks are re-created and added NOT VALID, so the change scans no row under a lock
  # that blocks writes to `nodes`; a later migration validates them
  # (`20261015131200_validate_an_adapter_s_checks`).
  @public_id "^(nd|np|ng|na)_[0-9a-hjkmnp-tv-z]{16}$"
  @old_public_id "^(nd|np|ng)_[0-9a-hjkmnp-tv-z]{16}$"
  @interval "BETWEEN 60 AND 86400"

  def up do
    for name <- ~w(nodes_kind_check nodes_public_id_check nodes_instance_limit_check
                   nodes_gateway_choice_check nodes_place_check) do
      execute "ALTER TABLE nodes DROP CONSTRAINT #{name}"
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_kind_check
      CHECK (kind IN ('node', 'pool', 'gateway', 'adapter')) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_public_id_check CHECK (
      public_id ~ '#{@public_id}' AND
      (kind = 'node') = (public_id LIKE 'nd\\_%') AND
      (kind = 'pool') = (public_id LIKE 'np\\_%') AND
      (kind = 'gateway') = (public_id LIKE 'ng\\_%') AND
      (kind = 'adapter') = (public_id LIKE 'na\\_%')
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_instance_limit_check CHECK (
      (kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR
      (kind = 'pool' AND (instance_limit IS NULL OR instance_limit BETWEEN 1 AND 10000)) OR
      (kind IN ('gateway', 'adapter') AND instance_limit IS NULL)
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_gateway_choice_check CHECK (
      gateway_choice IN ('direct', 'default', 'named') AND
      (gateway_id IS NULL OR gateway_choice = 'named') AND
      (kind NOT IN ('gateway', 'adapter') OR gateway_choice = 'direct')
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check CHECK (
      (workspace_id IS NOT NULL OR kind IN ('gateway', 'adapter')) AND
      (kind <> 'adapter' OR workspace_id IS NULL)
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_adapter_name_check
      CHECK (kind <> 'adapter' OR char_length(name) <= 64) NOT VALID
    """

    drop index(:nodes, [:organisation_id, :name], name: :nodes_organisation_live_name_index)

    create unique_index(:nodes, [:organisation_id, :name],
             where: "kind = 'gateway' AND workspace_id IS NULL AND deleted_at IS NULL",
             name: :nodes_organisation_live_name_index
           )

    create unique_index(:nodes, [:organisation_id, :name],
             where: "kind = 'adapter' AND deleted_at IS NULL",
             name: :nodes_organisation_adapter_name_index
           )

    alter table(:nodes) do
      add :connect_url, :text
      add :sync_interval, :integer
      add :sync_default_interval, :integer
      add :sync_minimum_interval, :integer
      add :sync_sends_changes, :boolean
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_adapter_check CHECK (
      kind = 'adapter' OR (
        connect_url IS NULL AND sync_interval IS NULL AND sync_default_interval IS NULL AND
        sync_minimum_interval IS NULL AND sync_sends_changes IS NULL
      )
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_connect_url_check CHECK (
      connect_url IS NULL OR (
        char_length(connect_url) <= 2048 AND
        connect_url ~ '^https://[^/?#@[:space:]]+([/?#][^[:space:]]*)?$'
      )
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_sync_check CHECK (
      (sync_interval IS NULL OR sync_interval #{@interval}) AND
      (sync_default_interval IS NULL OR sync_default_interval #{@interval}) AND
      (sync_minimum_interval IS NULL OR sync_minimum_interval #{@interval}) AND
      (sync_minimum_interval IS NULL OR sync_default_interval IS NULL OR
       sync_minimum_interval <= sync_default_interval)
    ) NOT VALID
    """
  end

  # Rolled back, a node is a node, a node pool or a gateway again. An adapter's row could
  # not stay, and its keys, codes and instances name it, so the rollback refuses while any
  # adapter row is there, deleted ones included, rather than delete them.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM nodes WHERE kind = 'adapter') THEN
        RAISE EXCEPTION 'nodes holds adapters: delete their rows before rolling this back';
      END IF;
    END
    $$
    """)

    for name <- ~w(nodes_sync_check nodes_connect_url_check nodes_adapter_check) do
      execute "ALTER TABLE nodes DROP CONSTRAINT #{name}"
    end

    alter table(:nodes) do
      remove :sync_sends_changes
      remove :sync_minimum_interval
      remove :sync_default_interval
      remove :sync_interval
      remove :connect_url
    end

    drop index(:nodes, [:organisation_id, :name], name: :nodes_organisation_adapter_name_index)
    drop index(:nodes, [:organisation_id, :name], name: :nodes_organisation_live_name_index)

    create unique_index(:nodes, [:organisation_id, :name],
             where: "workspace_id IS NULL AND deleted_at IS NULL",
             name: :nodes_organisation_live_name_index
           )

    for name <- ~w(nodes_adapter_name_check nodes_place_check nodes_gateway_choice_check
                   nodes_instance_limit_check nodes_public_id_check nodes_kind_check) do
      execute "ALTER TABLE nodes DROP CONSTRAINT #{name}"
    end

    execute "ALTER TABLE nodes ADD CONSTRAINT nodes_kind_check CHECK (kind IN ('node', 'pool', 'gateway'))"

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_public_id_check CHECK (
      public_id ~ '#{@old_public_id}' AND
      (kind = 'node') = (public_id LIKE 'nd\\_%') AND
      (kind = 'pool') = (public_id LIKE 'np\\_%') AND
      (kind = 'gateway') = (public_id LIKE 'ng\\_%')
    )
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_instance_limit_check CHECK (
      (kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR
      (kind = 'pool' AND (instance_limit IS NULL OR instance_limit BETWEEN 1 AND 10000)) OR
      (kind = 'gateway' AND instance_limit IS NULL)
    )
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_gateway_choice_check CHECK (
      gateway_choice IN ('direct', 'default', 'named') AND
      (gateway_id IS NULL OR gateway_choice = 'named') AND
      (kind <> 'gateway' OR gateway_choice = 'direct')
    )
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check
      CHECK (workspace_id IS NOT NULL OR kind = 'gateway')
    """
  end
end
