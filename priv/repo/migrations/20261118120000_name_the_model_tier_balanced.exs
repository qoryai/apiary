defmodule Apiary.Repo.Migrations.NameTheModelTierBalanced do
  use Ecto.Migration

  # The tier `fast` of a model choice's tier map is renamed `balanced`. The tiers become
  # `light`, `balanced` and `thinking`. `model_choice_tiers_valid/1`, the check of
  # `model_choices.tiers`, accepts `balanced` in place of `fast`.
  #
  # The migration moves no data. It deletes each model choice whose tier map has the
  # tier `fast`, with its fallbacks (`ON DELETE CASCADE`). PostgreSQL does not run a
  # replaced check function on the rows already in the table, so without the delete a
  # row with `fast` would stay in a table whose check fails on it.
  #
  # Rolled back, the check accepts `fast` in place of `balanced` again, and the migration
  # deletes each model choice whose tier map has the tier `balanced`, with its fallbacks.

  def up do
    execute("DELETE FROM model_choices WHERE tiers ? 'fast'")
    execute(tiers_valid(~w(light balanced thinking)))
  end

  def down do
    execute("DELETE FROM model_choices WHERE tiers ? 'balanced'")
    execute(tiers_valid(~w(light fast thinking)))
  end

  # The function of `20261019070200_keep_the_model_choice_at_each_level.exs` with the
  # tiers `tiers`.
  defp tiers_valid(tiers) do
    listed = Enum.map_join(tiers, ", ", &"'#{&1}'")

    """
    CREATE OR REPLACE FUNCTION model_choice_tiers_valid(tiers jsonb)
    RETURNS boolean LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog AS $$
      SELECT CASE
        WHEN tiers IS NULL THEN true
        WHEN jsonb_typeof(tiers) <> 'object' OR tiers = '{}'::jsonb THEN false
        ELSE NOT EXISTS (
          SELECT 1 FROM jsonb_each(tiers) AS t(tier, entry)
          WHERE t.tier NOT IN (#{listed})
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
    """
  end
end
