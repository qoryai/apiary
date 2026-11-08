defmodule Apiary.Repo.Migrations.KeepWhetherAWorkspaceKeepsItsProcessAtTheLatest do
  use Ecto.Migration

  # `workspaces.keep_process_latest`: whether each later commit of the branch the
  # workspace's harness follows is saved as a version of its process
  # (`Apiary.Processes.HarnessUpdate`). Nil until a person sets it or saves edits to the
  # process: then it is on for the Qory harness and off for a harness repository.
  #
  # Adding a column that may be empty, with no default, rewrites no row.
  def change do
    alter table(:workspaces) do
      add :keep_process_latest, :boolean
    end
  end
end
