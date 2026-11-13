defmodule Apiary.Repo.Migrations.KeepTheInstanceSFeatures do
  use Ecto.Migration

  # The features an instance admin saved (`Apiary.Features.Saved`), in the instance's row:
  #
  # `features`, the names of the features on, NULL until the first save, which leaves the
  # defaults on; `features_version`, raised by one on each write of `features`, so that a
  # save made from an older read of them is refused.
  def change do
    alter table(:instance_settings) do
      add :features, {:array, :text}
      add :features_version, :integer, null: false, default: 0
    end

    create constraint(:instance_settings, :instance_settings_features_version_check,
             check: "features_version >= 0"
           )
  end
end
