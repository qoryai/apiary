defmodule Apiary.Repo.Migrations.KeepNoModelListForAProvider do
  use Ecto.Migration

  # A model provider keeps no list of models: its models are those of its description
  # (`Apiary.Connections.provider_models/1`), and a model choice takes any other model id.
  # The table of the lists goes, with the check function only it used. Down puts both
  # back empty: a provider then has no models and no default model.
  def up do
    drop table(:provider_models)
    execute("DROP FUNCTION provider_effort_valid(text[])")
  end

  def down do
    execute("""
    CREATE FUNCTION provider_effort_valid(effort text[])
    RETURNS boolean LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog AS $$
      SELECT effort IS NULL
        OR (array_ndims(effort) = 1
          AND cardinality(effort) BETWEEN 1 AND 16
          AND array_position(effort, NULL) IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM unnest(effort) AS e(value) WHERE e.value !~ '^[a-z][a-z0-9-]{0,31}$'
          )
          AND (SELECT count(DISTINCT e.value) FROM unnest(effort) AS e(value)) = cardinality(effort))
    $$
    """)

    create table(:provider_models, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :connection_id,
          references(:organisation_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :model_id, :text, null: false
      add :title, :text, null: false
      add :effort, {:array, :text}
      add :position, :integer, null: false
      add :is_default, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:provider_models, :provider_models_model_id_format,
             check: "model_id ~ '^[A-Za-z0-9][!-~]{0,199}$'"
           )

    create constraint(:provider_models, :provider_models_title_length,
             check: "char_length(title) BETWEEN 1 AND 128"
           )

    create constraint(:provider_models, :provider_models_effort_check,
             check: "provider_effort_valid(effort)"
           )

    create constraint(:provider_models, :provider_models_position_check, check: "position >= 0")

    create unique_index(:provider_models, [:connection_id, :model_id])

    create unique_index(:provider_models, [:connection_id],
             where: "is_default",
             name: :provider_models_default_index
           )

    create index(:provider_models, [:organisation_id])
  end
end
