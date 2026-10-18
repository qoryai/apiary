defmodule Apiary.Repo.Migrations.KeepWhatATargetSRunsAlsoRead do
  use Ecto.Migration

  # The further repositories a target's runs also read, after the target itself
  # (`Apiary.Runs.Target`, `further_repositories`): paths in the target's system, each
  # owner/name of the target's owner, in the order a person put them, written whole by
  # `Apiary.Targets.set_further_repositories/3`, which checks every rule at save. The
  # target's path and the list, joined with commas, are at most 256 bytes
  # (`targets_further_repositories_check`).
  #
  # Every row there already gets the empty list, and a constant default rewrites no row.
  def up do
    alter table(:targets) do
      add :further_repositories, {:array, :text}, null: false, default: []
    end

    execute """
    ALTER TABLE targets ADD CONSTRAINT targets_further_repositories_check CHECK (
      cardinality(further_repositories) = 0 OR
      octet_length(path || ',' || array_to_string(further_repositories, ',')) <= 256
    )
    """
  end

  def down do
    execute "ALTER TABLE targets DROP CONSTRAINT targets_further_repositories_check"

    alter table(:targets) do
      remove :further_repositories
    end
  end
end
