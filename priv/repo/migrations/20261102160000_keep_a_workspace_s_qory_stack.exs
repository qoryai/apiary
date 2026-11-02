defmodule Apiary.Repo.Migrations.KeepAWorkspaceSQoryStack do
  use Ecto.Migration

  # `workspaces.qory_stack`: the stack of the Qory harness a workspace uses, as its template
  # gives it, nil for `core` (`Apiary.Organisations.Workspace.qory_stack/1`).
  #
  # Adding a column that may be empty, with no default, rewrites no row: every workspace
  # made before this column keeps `core`.
  def change do
    alter table(:workspaces) do
      add :qory_stack, :text
    end
  end
end
