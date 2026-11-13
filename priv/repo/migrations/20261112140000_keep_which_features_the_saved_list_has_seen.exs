defmodule Apiary.Repo.Migrations.KeepWhichFeaturesTheSavedListHasSeen do
  use Ecto.Migration

  # The names of the features the instance's saved list has seen (`Apiary.Features.Saved`,
  # `features_seen`): a feature it has not seen takes its default, so a later release's
  # new feature comes on or stays off as that release sets it, and a config value of an
  # older release turns its feature on once, at the first boot that reads it.
  def change do
    alter table(:instance_settings) do
      add :features_seen, {:array, :text}, null: false, default: []
    end
  end
end
