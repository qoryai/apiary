defmodule Apiary.Repo.Migrations.KeepTheApplyItemsAnAdapterDeclares do
  use Ecto.Migration

  # The apply items of the work credential an adapter's latest start-up describes
  # (`roles.source.apply`, `Apiary.Adapters.declare/2`): on its node, `source_apply`, a
  # JSON array of 1 to 16 objects, the items with each path a template; and
  # `egress_hosts`, the description's `egress_hosts` entries that are hosts, 1 or more,
  # with no NULL. NULL while the description has none, and on every other node
  # (`nodes_source_apply_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  def up do
    alter table(:nodes) do
      add :source_apply, :jsonb
      add :egress_hosts, {:array, :text}
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_source_apply_check CHECK (
      (source_apply IS NULL OR (
        kind = 'adapter' AND
        jsonb_typeof(source_apply) = 'array' AND
        jsonb_array_length(source_apply) BETWEEN 1 AND 16 AND
        NOT jsonb_path_exists(source_apply, '$[*] ? (@.type() != "object")')
      ))
      AND (egress_hosts IS NULL OR (
        kind = 'adapter' AND
        cardinality(egress_hosts) >= 1 AND
        array_position(egress_hosts, NULL) IS NULL
      ))
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_source_apply_check"

    alter table(:nodes) do
      remove :source_apply
      remove :egress_hosts
    end
  end
end
