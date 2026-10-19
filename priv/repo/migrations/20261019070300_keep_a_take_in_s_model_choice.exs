defmodule Apiary.Repo.Migrations.KeepATakeInSModelChoice do
  use Ecto.Migration

  # The model choice a person sends with a take in of a work item, for every run of that
  # take in (`Apiary.ModelChoices.TakeInChoice`): one row per take in at most, with the
  # columns of a model choice (`model_choices`) and the rules on them, the tier map's
  # included (`model_choice_tiers_valid/1`).
  #
  # `provider_chosen` says whether the take in chose a model provider. Removing the
  # provider sets `connection_id` alone to NULL and keeps the rest, so the row still says
  # that a provider was chosen and is gone, and the key and the model it chose. So a key
  # or a model is kept with `provider_chosen` and no provider, and a row chose a provider
  # or has a tier map.
  #
  # Each row is held to its work item and the work item's workspace by the composite key,
  # which follows the work item to another workspace (`ON UPDATE CASCADE`) and goes with
  # it, as the work item's answers do.
  def up do
    create table(:take_in_model_choices, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :work_item_id, :binary_id, null: false
      add :take_in, :integer, null: false
      add :provider_chosen, :boolean, null: false, default: false
      add :connection_id, :binary_id
      add :value_id, :text
      add :model_id, :text
      add :effort, :text
      add :tiers, :jsonb
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute("""
    ALTER TABLE take_in_model_choices ADD CONSTRAINT take_in_model_choices_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    execute("""
    ALTER TABLE take_in_model_choices ADD CONSTRAINT take_in_model_choices_connection_id_fkey
      FOREIGN KEY (connection_id, organisation_id)
      REFERENCES organisation_connections (id, organisation_id)
      MATCH SIMPLE ON DELETE SET NULL (connection_id)
    """)

    create unique_index(:take_in_model_choices, [:work_item_id, :take_in])
    create index(:take_in_model_choices, [:organisation_id, :workspace_id])
    create index(:take_in_model_choices, [:connection_id])
    create index(:take_in_model_choices, [:created_by_id])

    create constraint(:take_in_model_choices, :take_in_model_choices_take_in_check,
             check: "take_in >= 1"
           )

    create constraint(:take_in_model_choices, :take_in_model_choices_value_id_format,
             check: "value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'"
           )

    create constraint(:take_in_model_choices, :take_in_model_choices_model_id_format,
             check: "model_id ~ '^[A-Za-z0-9][!-~]{0,199}$'"
           )

    create constraint(:take_in_model_choices, :take_in_model_choices_effort_format,
             check: "effort ~ '^[a-z][a-z0-9-]{0,31}$'"
           )

    create constraint(:take_in_model_choices, :take_in_model_choices_tiers_check,
             check: "model_choice_tiers_valid(tiers)"
           )

    create constraint(:take_in_model_choices, :take_in_model_choices_shape_check,
             check: """
             (connection_id IS NULL OR provider_chosen)
             AND ((value_id IS NULL AND model_id IS NULL) OR provider_chosen)
             AND (effort IS NULL OR model_id IS NOT NULL)
             AND (provider_chosen OR tiers IS NOT NULL)
             """
           )
  end

  def down do
    drop table(:take_in_model_choices)
  end
end
