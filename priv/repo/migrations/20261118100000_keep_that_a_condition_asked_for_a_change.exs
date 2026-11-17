defmodule Apiary.Repo.Migrations.KeepThatAConditionAskedForAChange do
  use Ecto.Migration

  # An entry or a stage can be passed over by a condition `{input: T, changed: true}`
  # (`Apiary.Stages.Runner`). `stage_skips.changed` is true for the row of such a condition,
  # with `input` the type `T`, and false for every other row, so each stored row keeps its
  # meaning. The column has a constant default, so adding it rewrites no row.
  def change do
    alter table(:stage_skips) do
      add :changed, :boolean, null: false, default: false
    end
  end
end
