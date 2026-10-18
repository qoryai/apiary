defmodule Apiary.Repo.Migrations.KeepWhereAnAdapterIsSetUp do
  use Ecto.Migration

  # Where an instance admin is sent to set an adapter up at the system it reads from, as
  # the adapter's latest start-up declared it (`Apiary.Adapters.declare/2`): on its node,
  # `setup_url`, an https address of at most 2,048 characters with no user information, no
  # whitespace and no fragment, as `nodes_connect_url_check` holds a connect address but
  # without `#`. NULL while the adapter declares none, and on every other node
  # (`nodes_setup_url_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  @setup_url "'^https://[^/?#@[:space:]]+([/?][^#[:space:]]*)?$'"

  def up do
    alter table(:nodes) do
      add :setup_url, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_setup_url_check CHECK (
      setup_url IS NULL OR (
        kind = 'adapter' AND
        char_length(setup_url) <= 2048 AND
        setup_url ~ #{@setup_url}
      )
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_setup_url_check"

    alter table(:nodes) do
      remove :setup_url
    end
  end
end
