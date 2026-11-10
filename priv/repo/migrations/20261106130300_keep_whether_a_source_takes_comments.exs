defmodule Apiary.Repo.Migrations.KeepWhetherASourceTakesComments do
  use Ecto.Migration

  # Whether an adapter's source takes the comments members write in Qory Apiary, as the
  # integration contract has it (`description.schema.json`, `roles.source.comments`): on
  # an adapter's node (`Apiary.Nodes.Node`), `comments`, true where its latest start's
  # description sets `comments: true` and false where it has no `comments`. NULL before the
  # adapter's first start, and on every other node (`nodes_comments_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # An adapter's next start stores it, as it stores `targets`.
  def up do
    alter table(:nodes) do
      add :comments, :boolean
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_comments_check CHECK (
      comments IS NULL OR kind = 'adapter'
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_comments_check"

    alter table(:nodes) do
      remove :comments
    end
  end
end
