defmodule Apiary.Repo.Migrations.KeepTheMachineTypeOfARunImage do
  use Ecto.Migration

  # Whether a run's `configured_image` is the image of a machine type, and which type.
  # The claim sets both for a run whose type has an image, and the attach for a run given
  # the default type's image (`Apiary.Runs.Attach`):
  #
  # - `runs.configured_image_from_type`: true for a type's image, false for a target's
  #   image and for no image. It outlives the type, so a run whose type was deleted still
  #   ends `image_missing` as a type's image does (`Apiary.Dispatches.RunEnd`);
  # - `runs.configured_image_machine_type_id`: that type, by id, which finds its name and
  #   key after any rename; set to null when the type is deleted.
  #
  # A check keeps a type's image to a run with an image, and the type to a type's image.
  # Nothing exists to fill: a run given an image before is read as given its target's.
  def change do
    alter table(:runs) do
      add :configured_image_from_type, :boolean, null: false, default: false

      add :configured_image_machine_type_id,
          references(:machine_types, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:runs, [:configured_image_machine_type_id],
             where: "configured_image_machine_type_id IS NOT NULL"
           )

    create constraint(:runs, :runs_configured_image_from_type_check,
             check: """
             (configured_image_from_type AND configured_image IS NOT NULL)
             OR (NOT configured_image_from_type AND configured_image_machine_type_id IS NULL)
             """
           )
  end
end
