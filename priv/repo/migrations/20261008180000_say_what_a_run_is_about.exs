defmodule Apiary.Repo.Migrations.SayWhatARunIsAbout do
  use Ecto.Migration

  # A run says what it is about: `about` of its `dev.qory.run.started`, folded into four
  # columns (`Apiary.Runs.Fold`). `about_kind` and `about_title` are text, `about_subjects`
  # a JSON array of `{type, ref, url?, title?}` objects, empty when the run named none, and
  # `about_details` a JSON object. All four are rebuilt from the events like every other
  # folded field.
  def change do
    alter table(:runs) do
      add :about_kind, :text
      add :about_title, :text
      add :about_subjects, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :about_details, :jsonb
    end
  end
end
