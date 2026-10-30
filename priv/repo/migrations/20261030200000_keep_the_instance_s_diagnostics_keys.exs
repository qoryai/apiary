defmodule Apiary.Repo.Migrations.KeepTheInstanceSDiagnosticsKeys do
  use Ecto.Migration

  # A diagnostics key reads one run's diagnostics, of any run of the instance, by a signed
  # request (`GET /v1/runs/<run id>/diagnostics`), and nothing else. It is an access key
  # of a node of the kind `diagnostics`: one node at the instance, with no organisation and
  # no workspace, which holds every diagnostics key, as an adapter holds its keys.
  #
  # - `nodes_kind_check` takes `diagnostics`, and `nodes_public_id_check` its prefix, `dg_`.
  # - `nodes_instance_limit_check`: it has no instance limit.
  # - `nodes_gateway_choice_check`: it chooses no gateway.
  # - `nodes_place_check`: it never has an organisation, so never a workspace either.
  # - `nodes_diagnostics_index`: one in use.
  #
  # The checks are added NOT VALID, so the change scans no row under a lock that blocks
  # writes to the table; `20261030200100_validate_the_diagnostics_checks` validates them.
  @public_id "^(nd|np|ng|na|dg)_[0-9a-hjkmnp-tv-z]{16}$"
  @before_public_id "^(nd|np|ng|na)_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    for name <- ~w(nodes_kind_check nodes_public_id_check nodes_instance_limit_check
                   nodes_gateway_choice_check nodes_place_check) do
      execute "ALTER TABLE nodes DROP CONSTRAINT #{name}"
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_kind_check
      CHECK (kind IN ('node', 'pool', 'gateway', 'adapter', 'diagnostics')) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_public_id_check CHECK (
      public_id ~ '#{@public_id}' AND
      (kind = 'node') = (public_id LIKE 'nd\\_%') AND
      (kind = 'pool') = (public_id LIKE 'np\\_%') AND
      (kind = 'gateway') = (public_id LIKE 'ng\\_%') AND
      (kind = 'adapter') = (public_id LIKE 'na\\_%') AND
      (kind = 'diagnostics') = (public_id LIKE 'dg\\_%')
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_instance_limit_check CHECK (
      (kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR
      (kind = 'pool' AND (instance_limit IS NULL OR instance_limit BETWEEN 1 AND 10000)) OR
      (kind IN ('gateway', 'adapter', 'diagnostics') AND instance_limit IS NULL)
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_gateway_choice_check CHECK (
      gateway_choice IN ('direct', 'default', 'named') AND
      (gateway_id IS NULL OR gateway_choice = 'named') AND
      (kind NOT IN ('gateway', 'adapter', 'diagnostics') OR gateway_choice = 'direct')
    ) NOT VALID
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check CHECK (
      (workspace_id IS NULL OR organisation_id IS NOT NULL) AND
      (kind <> 'node' OR workspace_id IS NOT NULL) AND
      (kind NOT IN ('adapter', 'diagnostics') OR organisation_id IS NULL) AND
      (kind <> 'pool' OR workspace_id IS NOT NULL OR organisation_id IS NULL)
    ) NOT VALID
    """

    create unique_index(:nodes, [:kind],
             where: "kind = 'diagnostics' AND deleted_at IS NULL",
             name: :nodes_diagnostics_index
           )
  end

  # Rolled back, no node may be of the kind `diagnostics`. The rollback refuses while one
  # is there, deleted ones included, rather than delete it with its keys.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM nodes WHERE kind = 'diagnostics') THEN
        RAISE EXCEPTION 'nodes holds the instance''s diagnostics node: delete its row and its keys before rolling this back';
      END IF;
    END
    $$
    """)

    drop index(:nodes, [:kind], name: :nodes_diagnostics_index)

    for name <- ~w(nodes_kind_check nodes_public_id_check nodes_instance_limit_check
                   nodes_gateway_choice_check nodes_place_check) do
      execute "ALTER TABLE nodes DROP CONSTRAINT #{name}"
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_kind_check
      CHECK (kind IN ('node', 'pool', 'gateway', 'adapter'))
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_public_id_check CHECK (
      public_id ~ '#{@before_public_id}' AND
      (kind = 'node') = (public_id LIKE 'nd\\_%') AND
      (kind = 'pool') = (public_id LIKE 'np\\_%') AND
      (kind = 'gateway') = (public_id LIKE 'ng\\_%') AND
      (kind = 'adapter') = (public_id LIKE 'na\\_%')
    )
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_instance_limit_check CHECK (
      (kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR
      (kind = 'pool' AND (instance_limit IS NULL OR instance_limit BETWEEN 1 AND 10000)) OR
      (kind IN ('gateway', 'adapter') AND instance_limit IS NULL)
    )
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_gateway_choice_check CHECK (
      gateway_choice IN ('direct', 'default', 'named') AND
      (gateway_id IS NULL OR gateway_choice = 'named') AND
      (kind NOT IN ('gateway', 'adapter') OR gateway_choice = 'direct')
    )
    """

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_place_check CHECK (
      (workspace_id IS NULL OR organisation_id IS NOT NULL) AND
      (kind <> 'node' OR workspace_id IS NOT NULL) AND
      (kind <> 'adapter' OR organisation_id IS NULL) AND
      (kind <> 'pool' OR workspace_id IS NOT NULL OR organisation_id IS NULL)
    )
    """
  end
end
