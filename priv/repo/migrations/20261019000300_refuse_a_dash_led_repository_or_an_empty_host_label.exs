defmodule Apiary.Repo.Migrations.RefuseADashLedRepositoryOrAnEmptyHostLabel do
  use Ecto.Migration

  # A run's repositories are owner/name paths none of whose segments starts with a dash,
  # so that none reads as an option, and its system is a host name with no empty label:
  # no dot first or last, and no two together (`Apiary.Runs.RunVariables`). The code
  # checks both at take in and at save; these checks hold the same on the rows that carry
  # them: a work item's target (`work_items_target_shape_check`) and a target's further
  # repositories (`targets_further_repositories_shape_check`, every segment of every path,
  # joined with slashes). The rest of the owner/name rule stays with the code.
  #
  # Each check is added validated: on an install holding a row outside it, Postgres
  # refuses the migration and nothing changes.
  def up do
    execute """
    ALTER TABLE work_items ADD CONSTRAINT work_items_target_shape_check CHECK (
      target_system !~ '(^\\.|\\.\\.|\\.$)' AND target_path !~ '(^|/)-'
    )
    """

    execute """
    ALTER TABLE targets ADD CONSTRAINT targets_further_repositories_shape_check CHECK (
      array_to_string(further_repositories, '/') !~ '(^|/)-'
    )
    """
  end

  def down do
    execute "ALTER TABLE targets DROP CONSTRAINT targets_further_repositories_shape_check"
    execute "ALTER TABLE work_items DROP CONSTRAINT work_items_target_shape_check"
  end
end
