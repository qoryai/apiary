defmodule Apiary.Repo.Migrations.KeepTheFallbacksOfAModelChoice do
  use Ecto.Migration

  # The fallbacks of a model choice (`Apiary.ModelChoices.Fallback`): the model providers
  # whose keys runs use, in order, while every key of the choice's provider is in
  # cooldown. Each row is one model provider (`connection_id`) at one `position` of a
  # choice, from 0, with a model id and an effort value, each optional as the choice's
  # are. A provider is at most once among a choice's fallbacks, and a position once.
  #
  # The organisation is a column of the row, so a row reaches only a choice and a
  # provider of that organisation (the composite keys). A choice takes its fallbacks with
  # it (`ON DELETE CASCADE`); a provider a fallback uses is not deleted while the row is
  # there (`ON DELETE RESTRICT`), as with a choice. Nothing exists to fill.
  def change do
    create unique_index(:model_choices, [:id, :organisation_id])

    create table(:model_choice_fallbacks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :model_choice_id,
          references(:model_choices,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :position, :integer, null: false

      add :connection_id,
          references(:organisation_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :restrict
          ),
          null: false

      add :model_id, :text
      add :effort, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_position_check,
             check: "position >= 0"
           )

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_model_id_format,
             check: "model_id ~ '^[A-Za-z0-9][!-~]{0,199}$'"
           )

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_effort_format,
             check: "effort ~ '^[a-z][a-z0-9-]{0,31}$'"
           )

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_shape_check,
             check: "effort IS NULL OR model_id IS NOT NULL"
           )

    create unique_index(:model_choice_fallbacks, [:model_choice_id, :position])
    create unique_index(:model_choice_fallbacks, [:model_choice_id, :connection_id])
    create index(:model_choice_fallbacks, [:connection_id])
    create index(:model_choice_fallbacks, [:organisation_id])
  end
end
