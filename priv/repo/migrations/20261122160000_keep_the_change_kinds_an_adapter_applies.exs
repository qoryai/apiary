defmodule Apiary.Repo.Migrations.KeepTheChangeKindsAnAdapterApplies do
  use Ecto.Migration

  # The kinds of change request an adapter applies at its system, as the source role of its
  # latest start's description lists them (`change_kinds`, the integration contract's
  # `description.schema.json`): on an adapter's node (`Apiary.Nodes.Node`), `change_kinds`,
  # 1 to 16 kinds, each lower-case letters and digits in groups joined by single hyphens,
  # 1 to 64 characters; the description's schema checks that each is listed once. NULL
  # while the description lists none, and on every other node (`nodes_change_kinds_check`).
  #
  # Adding a column with no default rewrites no row. The check is added NOT VALID, so
  # adding it takes no scan of `nodes` under its lock; the next migration validates it.
  # An adapter's next start stores the list, as it stores `comments`.
  def up do
    alter table(:nodes) do
      add :change_kinds, {:array, :text}
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_change_kinds_check CHECK (
      change_kinds IS NULL OR (
        kind = 'adapter' AND
        cardinality(change_kinds) BETWEEN 1 AND 16 AND
        array_position(change_kinds, NULL) IS NULL AND
        array_to_string(change_kinds, ' ') ~
          '^(?=[a-z0-9-]{1,64}( |$))[a-z0-9]+(-[a-z0-9]+)*( (?=[a-z0-9-]{1,64}( |$))[a-z0-9]+(-[a-z0-9]+)*)*$'
      )
    ) NOT VALID
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_change_kinds_check"

    alter table(:nodes) do
      remove :change_kinds
    end
  end
end
