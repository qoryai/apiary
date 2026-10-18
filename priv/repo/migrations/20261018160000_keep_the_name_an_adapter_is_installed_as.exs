defmodule Apiary.Repo.Migrations.KeepTheNameAnAdapterIsInstalledAs do
  use Ecto.Migration

  # An adapter installed with Qory Apiary (`Apiary.Adapters.install/2`): on its node, the
  # name the setting that lists the installed adapters gives it, `installed_as`, 1 to 32
  # characters, a lower-case letter, then lower-case letters, digits and hyphens. NULL for
  # an adapter an instance admin added, and on every other node (`nodes_installed_as_check`).
  # Among the adapters in use, one at most is installed as each name
  # (`nodes_installed_as_index`): a deleted one leaves the name free, and a name listed
  # again makes a new adapter.
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  @name "'^[a-z][a-z0-9-]{0,31}$'"

  def up do
    alter table(:nodes) do
      add :installed_as, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_installed_as_check CHECK (
      installed_as IS NULL OR (kind = 'adapter' AND installed_as ~ #{@name})
    )
    """

    create unique_index(:nodes, [:installed_as],
             where: "kind = 'adapter' AND installed_as IS NOT NULL AND deleted_at IS NULL",
             name: :nodes_installed_as_index
           )
  end

  def down do
    drop index(:nodes, [:installed_as], name: :nodes_installed_as_index)
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_installed_as_check"

    alter table(:nodes) do
      remove :installed_as
    end
  end
end
