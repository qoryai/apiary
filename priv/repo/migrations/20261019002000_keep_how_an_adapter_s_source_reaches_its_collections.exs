defmodule Apiary.Repo.Migrations.KeepHowAnAdapterSSourceReachesItsCollections do
  use Ecto.Migration

  # How to change, at the source, which collections an adapter reaches, as the integration
  # contract has it (`description.schema.json`, `roles.source.access`): on an adapter's
  # node (`Apiary.Nodes.Node`), `source_access`, its description's line, NULL until a
  # start stores one or where its description has no source role. Every other node has
  # none (`nodes_source_access_check`).
  #
  # It is NULL for every row there already, and adding a column with no default rewrites
  # no row. An adapter's next start stores it, as it stores the words for its items and
  # its collections.

  def up do
    alter table(:nodes) do
      add :source_access, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_source_access_check CHECK (
      kind = 'adapter' OR source_access IS NULL
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_source_access_check"

    alter table(:nodes) do
      remove :source_access
    end
  end
end
