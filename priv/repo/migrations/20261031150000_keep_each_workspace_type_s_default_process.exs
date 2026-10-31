defmodule Apiary.Repo.Migrations.KeepEachWorkspaceTypeSDefaultProcess do
  use Ecto.Migration

  # The default process of each workspace type (`Apiary.Processes.TypeTemplates`), the
  # instance's, as versions: a new workspace copies the newest version of its type. Each
  # save is a new row, numbered 1, 2, … within the type. `type` is the key of the type's
  # definition (`Apiary.Lingo.Domain.Definition`), such as `qory.software`. `author_id` is
  # nil for a copy of the default the release ships, and `release` is that default's
  # version; an instance admin's save has an author and no `release`. `based_on` is the
  # number of the version the save started from.
  #
  # The table starts empty: the first read of a type inserts its version 1, the release's
  # default.
  def change do
    create table(:type_template_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :text, null: false
      add :number, :integer, null: false
      add :document, :map, null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :release, :integer
      add :based_on, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:type_template_versions, [:type, :number])

    create constraint(:type_template_versions, :type_template_versions_number_check,
             check: "number >= 1 AND (based_on IS NULL OR (based_on >= 1 AND based_on < number))"
           )

    create constraint(:type_template_versions, :type_template_versions_release_check,
             check: "release IS NULL OR release >= 1"
           )
  end
end
