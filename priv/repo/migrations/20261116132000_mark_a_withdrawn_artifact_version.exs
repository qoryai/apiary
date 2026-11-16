defmodule Apiary.Repo.Migrations.MarkAWithdrawnArtifactVersion do
  use Ecto.Migration

  # `withdrawn` of `artifact_versions`: true for a version a run stored with no files to
  # withdraw its artifact's name (`Apiary.Artifacts.withdraw/4`), false for every other
  # version. Every row there today is a version with files, so it gets false.
  def change do
    alter table(:artifact_versions) do
      add :withdrawn, :boolean, null: false, default: false
    end
  end
end
