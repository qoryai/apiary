defmodule Apiary.Repo.Migrations.MakeAMachineTypeASize do
  use Ecto.Migration

  # A machine type sets the size of the machine a run starts on, and no image: every run
  # starts in its target's prebuilt image, else in the machine's default image. Up drops
  # what kept a type's image:
  #
  # - `machine_types.image`, with its check `machine_types_image_check`;
  # - `runs.configured_image_from_type` and `runs.configured_image_machine_type_id`, with
  #   the check `runs_configured_image_from_type_check` and the partial index on the type.
  #
  # The data in them is lost: each type's image, and which past runs started in a type's
  # image. `runs.configured_image` stays. Every type keeps its key, name and spec. A run
  # claimed with a type's image before the upgrade attaches after it with that image read
  # as its target's (`Apiary.Environments.own_image/2`): an image outside the
  # organisation's place in the registry is not given, and the run starts in the pool's
  # default image.
  #
  # Down adds the columns, the checks and the index back: no type has an image, and no run
  # is marked as given one. No data comes back.
  def up do
    drop constraint(:machine_types, :machine_types_image_check)
    drop constraint(:runs, :runs_configured_image_from_type_check)

    drop index(:runs, [:configured_image_machine_type_id],
           where: "configured_image_machine_type_id IS NOT NULL"
         )

    alter table(:machine_types) do
      remove :image
    end

    alter table(:runs) do
      remove :configured_image_machine_type_id
      remove :configured_image_from_type
    end
  end

  def down do
    alter table(:machine_types) do
      add :image, :text
    end

    create constraint(:machine_types, :machine_types_image_check,
             check:
               "image IS NULL OR (char_length(image) <= 327 AND image ~ '@sha256:[0-9a-f]{64}$')"
           )

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
