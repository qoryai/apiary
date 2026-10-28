defmodule Apiary.Repo.Migrations.KeepWhetherAnAdapterSCollectionsHaveTargets do
  use Ecto.Migration

  # Whether an adapter's collections can have a target, a place where a run's changes go,
  # as the integration contract has it (`description.schema.json`,
  # `roles.source.targets`): on an adapter's node (`Apiary.Nodes.Node`), `targets`, true
  # where its latest start's description says `targets: true` and false where it says
  # nothing. NULL before the adapter's first start, and on every other node
  # (`nodes_targets_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # An adapter's next start stores it, as it stores `items`.
  def up do
    alter table(:nodes) do
      add :targets, :boolean
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_targets_check CHECK (
      targets IS NULL OR kind = 'adapter'
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_targets_check"

    alter table(:nodes) do
      remove :targets
    end
  end
end
