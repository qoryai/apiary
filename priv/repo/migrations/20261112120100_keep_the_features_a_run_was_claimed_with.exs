defmodule Apiary.Repo.Migrations.KeepTheFeaturesARunWasClaimedWith do
  use Ecto.Migration

  # Each run keeps the names of the instance's features when it was claimed or registered
  # (`Apiary.Runs.Run`, `features`): its requests are checked against them, not against a
  # list saved since. NULL for a run claimed before this column, which follows the
  # instance's features.
  def change do
    alter table(:runs) do
      add :features, {:array, :text}
    end
  end
end
