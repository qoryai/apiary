defmodule Apiary.Repo.Migrations.KeepEachWorkspaceTypeSNameAndDescription do
  use Ecto.Migration

  # The name, summary and description of a workspace type, kept with each version of its
  # default process (`Apiary.Processes.TypeTemplate`). Nil, for every row that exists and
  # for a copy of the release's default, means the text the release ships in code
  # (`Apiary.Processes.type_texts/1`). An instance admin's save copies them, or changes
  # them, into the new version.
  def change do
    alter table(:type_template_versions) do
      add :name, :text
      add :summary, :text
      add :description, :text
    end

    create constraint(:type_template_versions, :type_template_versions_texts_check,
             check:
               "(name IS NULL OR char_length(name) BETWEEN 1 AND 60) AND " <>
                 "(summary IS NULL OR char_length(summary) BETWEEN 1 AND 200) AND " <>
                 "(description IS NULL OR char_length(description) BETWEEN 1 AND 1200)"
           )
  end
end
