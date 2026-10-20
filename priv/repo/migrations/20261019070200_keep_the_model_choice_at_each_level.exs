defmodule Apiary.Repo.Migrations.KeepTheModelChoiceAtEachLevel do
  use Ecto.Migration

  # A model choice set at a level of an organisation (`Apiary.ModelChoices.ModelChoice`):
  # its model provider (`connection_id`), the value id of one of the provider's keys, a
  # model id of the provider's list, an effort value, and a tier map. A row is at one of
  # five levels, by the columns it has set:
  #
  #   * a target and a run kind: `workspace_id`, `target_id` and `run_kind`;
  #   * a target: `workspace_id` and `target_id`;
  #   * the workspace and a run kind: `workspace_id` and `run_kind`;
  #   * the workspace: `workspace_id`;
  #   * the organisation's default: neither.
  #
  # `chain` is `organisation` for a row the organisation sets, or `operator` for one an
  # operator sets for a client, which an edition manages. One row per place and chain:
  # the unique index reads a missing workspace or target as the nil UUID and a missing
  # run kind as the empty text. Only a row of the workspace, with or without a run kind,
  # is locked. A key or a model only with a provider, an effort only with a model, and a
  # row has a provider or a tier map. A tier map is an object of one to three of the
  # tiers `light`, `fast` and `thinking`, each a model id, or an object of a model id and
  # an optional effort value (`model_choice_tiers_valid/1`). A provider a row uses is not
  # deleted while the row is there (`ON DELETE RESTRICT`); a target or a workspace takes
  # its rows with it.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def up do
    execute("""
    CREATE FUNCTION model_choice_tiers_valid(tiers jsonb)
    RETURNS boolean LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog AS $$
      SELECT CASE
        WHEN tiers IS NULL THEN true
        WHEN jsonb_typeof(tiers) <> 'object' OR tiers = '{}'::jsonb THEN false
        ELSE NOT EXISTS (
          SELECT 1 FROM jsonb_each(tiers) AS t(tier, entry)
          WHERE t.tier NOT IN ('light', 'fast', 'thinking')
            OR NOT COALESCE(
              CASE jsonb_typeof(t.entry)
                WHEN 'string' THEN (t.entry #>> '{}') ~ '^[A-Za-z0-9][!-~]{0,199}$'
                WHEN 'object' THEN
                  jsonb_typeof(t.entry -> 'model') = 'string'
                  AND (t.entry ->> 'model') ~ '^[A-Za-z0-9][!-~]{0,199}$'
                  AND (NOT (t.entry ? 'effort')
                    OR (jsonb_typeof(t.entry -> 'effort') = 'string'
                      AND (t.entry ->> 'effort') ~ '^[a-z][a-z0-9-]{0,31}$'))
                  AND NOT EXISTS (
                    SELECT 1 FROM jsonb_object_keys(t.entry) AS k(name)
                    WHERE k.name NOT IN ('model', 'effort'))
                ELSE false
              END,
              false))
      END
    $$
    """)

    create table(:model_choices, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :simple,
            on_delete: :delete_all
          )

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :simple,
            on_delete: :delete_all
          )

      add :run_kind, :text
      add :chain, :text, null: false, default: "organisation"
      add :locked, :boolean, null: false, default: false

      add :connection_id,
          references(:organisation_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :simple,
            on_delete: :restrict
          )

      add :value_id, :text
      add :model_id, :text
      add :effort, :text
      add :tiers, :jsonb
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:model_choices, :model_choices_run_kind_format,
             check: "run_kind ~ '^[a-z][a-z_]{0,39}$'"
           )

    create constraint(:model_choices, :model_choices_chain_check,
             check: "chain IN ('organisation', 'operator')"
           )

    create constraint(:model_choices, :model_choices_value_id_format,
             check: "value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'"
           )

    create constraint(:model_choices, :model_choices_model_id_format,
             check: "model_id ~ '^[A-Za-z0-9][!-~]{0,199}$'"
           )

    create constraint(:model_choices, :model_choices_effort_format,
             check: "effort ~ '^[a-z][a-z0-9-]{0,31}$'"
           )

    create constraint(:model_choices, :model_choices_tiers_check,
             check: "model_choice_tiers_valid(tiers)"
           )

    create constraint(:model_choices, :model_choices_shape_check,
             check: """
             (target_id IS NULL OR workspace_id IS NOT NULL)
             AND (NOT locked OR (workspace_id IS NOT NULL AND target_id IS NULL))
             AND ((value_id IS NULL AND model_id IS NULL) OR connection_id IS NOT NULL)
             AND (effort IS NULL OR model_id IS NOT NULL)
             AND (connection_id IS NOT NULL OR tiers IS NOT NULL)
             """
           )

    create unique_index(
             :model_choices,
             [
               :organisation_id,
               :chain,
               "COALESCE(workspace_id, #{@nobody})",
               "COALESCE(target_id, #{@nobody})",
               "COALESCE(run_kind, '')"
             ],
             name: :model_choices_place_index
           )

    create index(:model_choices, [:workspace_id])
    create index(:model_choices, [:target_id])
    create index(:model_choices, [:connection_id])
    create index(:model_choices, [:created_by_id])
    create index(:model_choices, [:updated_by_id])
  end

  def down do
    drop table(:model_choices)
    execute("DROP FUNCTION model_choice_tiers_valid(jsonb)")
  end
end
