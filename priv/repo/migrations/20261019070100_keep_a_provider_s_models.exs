defmodule Apiary.Repo.Migrations.KeepAProviderSModels do
  use Ecto.Migration

  # A model provider's list of models (`Apiary.Connections.ProviderModel`), started from
  # its description and edited by exact model id: each model's id as the provider's API
  # takes it, a title, the effort values it accepts or none, its place in the list, and
  # whether it is the provider's default. A row goes with its provider. The 200 models a
  # provider has at most are counted under the provider's row lock, in code.
  def up do
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

  def down do
    drop table(:provider_models)
    execute("DROP FUNCTION provider_effort_valid(text[])")
  end
end
