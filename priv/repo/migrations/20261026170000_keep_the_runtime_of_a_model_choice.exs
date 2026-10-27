defmodule Apiary.Repo.Migrations.KeepTheRuntimeOfAModelChoice do
  use Ecto.Migration

  # A model choice names the runtime its runs use, by its name in the runtime catalogue
  # (`Apiary.Kinds.Runtimes`), beside its provider: empty for the catalogue's default
  # (`Apiary.ModelChoices.default_runtime/0`). A choice that names a runtime names a
  # provider too.
  def change do
    alter table(:model_choices) do
      add :runtime, :text
    end

    create constraint(:model_choices, :model_choices_runtime_format,
             check: "runtime ~ '^[a-z][a-z0-9_-]{0,63}$'"
           )

    create constraint(:model_choices, :model_choices_runtime_provider,
             check: "runtime IS NULL OR connection_id IS NOT NULL"
           )
  end
end
