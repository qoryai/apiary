defmodule Apiary.Repo.Migrations.LetATypeForbidWithdrawing do
  use Ecto.Migration

  # `withdrawable` of `artifact_types`: false for a custom type whose template sets
  # `withdrawable: false`, so a run cannot withdraw a name of that type
  # (`Apiary.Artifacts.withdraw/4`). Every row there today is a type that allows it, so it
  # gets true.
  #
  # `locked_standard_types` of `workspaces`: the names of the standard types whose
  # template entry sets `withdrawable: false`, with no row of their own. Every workspace
  # has none today, so it gets the empty list. Both defaults are constants, so no row is
  # rewritten.
  def change do
    alter table(:artifact_types) do
      add :withdrawable, :boolean, null: false, default: true
    end

    alter table(:workspaces) do
      add :locked_standard_types, {:array, :text}, null: false, default: fragment("'{}'")
    end
  end
end
