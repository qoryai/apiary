defmodule Apiary.Repo.Migrations.KeepTheSecretNamesAnAdapterDeclares do
  use Ecto.Migration

  # The names of the secrets an adapter stores in Qory Apiary, as the source role of its
  # latest start-up's description lists them (`secrets`, `Apiary.Adapters.declare/2`): on
  # its node, `secret_names`, 1 to 16 names, each of lower-case letters, digits, dots,
  # underscores and hyphens, 1 to 64 characters, starting with a letter or a digit. NULL
  # while the description lists none, and on every other node
  # (`nodes_secret_names_check`). An upload of a secret whose name is not there is refused
  # (`Apiary.Adapters.store_app_values/3`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  def up do
    alter table(:nodes) do
      add :secret_names, {:array, :text}
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_secret_names_check CHECK (
      secret_names IS NULL OR (
        kind = 'adapter' AND
        cardinality(secret_names) BETWEEN 1 AND 16 AND
        array_position(secret_names, NULL) IS NULL AND
        array_to_string(secret_names, ' ') ~ '^[a-z0-9][a-z0-9_.-]{0,63}( [a-z0-9][a-z0-9_.-]{0,63})*$'
      )
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_secret_names_check"

    alter table(:nodes) do
      remove :secret_names
    end
  end
end
