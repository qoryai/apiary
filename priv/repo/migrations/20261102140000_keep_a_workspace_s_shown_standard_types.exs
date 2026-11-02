defmodule Apiary.Repo.Migrations.KeepAWorkspaceSShownStandardTypes do
  use Ecto.Migration

  # `workspaces.shown_standard_types`: the names of the standard artifact types the
  # workspace shows, nil for every standard type (`Apiary.Artifacts`). The list contains no
  # always-on name (`Apiary.Artifacts.Type.always_on/0`).
  #
  # Adding a column that may be empty, with no default, rewrites no row: every workspace
  # keeps every standard type.
  def change do
    alter table(:workspaces) do
      add :shown_standard_types, {:array, :text}
    end
  end
end
