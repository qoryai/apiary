defmodule Apiary.Repo.Migrations.KeepAnAdapterSTitle do
  use Ecto.Migration

  # An adapter's human name, as its latest start's description gives it (the integration
  # contract's `description.schema.json`, `title`), which a page shows in place of the
  # adapter's name: on an adapter's node (`Apiary.Nodes.Node`), `title`, 1 to 100
  # characters. NULL before the adapter's first start, where the title fails the check
  # that a start makes of it, and on every other node (`nodes_title_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # An adapter's next start stores it, as it stores its domains.
  def up do
    alter table(:nodes) do
      add :title, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_title_check CHECK (
      title IS NULL OR (kind = 'adapter' AND char_length(title) BETWEEN 1 AND 100)
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_title_check"

    alter table(:nodes) do
      remove :title
    end
  end
end
