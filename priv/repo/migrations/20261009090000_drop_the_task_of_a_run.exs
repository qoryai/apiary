defmodule Apiary.Repo.Migrations.DropTheTaskOfARun do
  use Ecto.Migration

  # A run's title is the one it gives in `about` (`about_title`), so the `task` label is an
  # ordinary label: nothing is titled, filtered or searched by it, and its column goes. The
  # label itself stays in `labels`.
  def up do
    alter table(:runs) do
      remove :task
    end
  end

  # Rolling back gives the column again, filled from the label it was folded from.
  def down do
    alter table(:runs) do
      add :task, :text
    end

    execute "UPDATE runs SET task = labels->>'task' WHERE labels ? 'task'"
  end
end
