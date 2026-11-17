defmodule Apiary.Repo.Migrations.KeepTheLargestPrebuiltImage do
  use Ecto.Migration

  # `instance_settings.prebuilt_image_max_gb`, the largest image a prebuild may keep, in
  # GB, as an instance admin saves it in Instance settings › Configuration: 1 to 10000,
  # NULL until saved, and NULL is no limit.
  def change do
    alter table(:instance_settings) do
      add :prebuilt_image_max_gb, :integer
    end

    create constraint(:instance_settings, :instance_settings_prebuilt_image_max_gb_check,
             check: "prebuilt_image_max_gb BETWEEN 1 AND 10000"
           )
  end
end
