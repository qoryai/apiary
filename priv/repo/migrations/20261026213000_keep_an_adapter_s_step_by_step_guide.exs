defmodule Apiary.Repo.Migrations.KeepAnAdapterSStepByStepGuide do
  use Ecto.Migration

  # The step-by-step help an adapter's description gives for setting it up and for
  # connecting it, as the integration contract has it (`description.schema.json`,
  # `roles.source.guide`): on an adapter's node (`Apiary.Nodes.Node`), `source_guide`, a
  # JSON object as the description has it, which the description's schema has checked.
  # NULL until a start stores one, where its description has no guide, and on every other
  # node (`nodes_source_guide_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # An adapter's next start stores it, as it stores its line on access.
  def up do
    alter table(:nodes) do
      add :source_guide, :jsonb
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_source_guide_check CHECK (
      source_guide IS NULL OR (kind = 'adapter' AND jsonb_typeof(source_guide) = 'object')
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_source_guide_check"

    alter table(:nodes) do
      remove :source_guide
    end
  end
end
