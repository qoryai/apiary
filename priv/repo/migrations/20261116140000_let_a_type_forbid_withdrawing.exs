defmodule Apiary.Repo.Migrations.LetATypeForbidWithdrawing do
  use Ecto.Migration

  # `withdrawable` of `artifact_types`: false for a custom type whose template sets
  # `withdrawable: false`, so a run cannot withdraw a name of that type
  # (`Apiary.Artifacts.withdraw/4`). Every row there today is a type that allows it, so it
  # gets true.
  def change do
    alter table(:artifact_types) do
      add :withdrawable, :boolean, null: false, default: true
    end
  end
end
