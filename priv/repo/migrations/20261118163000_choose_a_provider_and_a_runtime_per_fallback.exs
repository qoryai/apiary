defmodule Apiary.Repo.Migrations.ChooseAProviderAndARuntimePerFallback do
  use Ecto.Migration

  # A model choice chooses a model provider, and a run takes that provider's keys: the
  # column `value_id`, the key a choice chose, goes from `model_choices` with its check.
  #
  # A fallback of a model choice (`Apiary.ModelChoices.Fallback`) has a runtime and a tier
  # map, as a choice has: `runtime`, the name of a runtime of the catalogue, in the form
  # of `model_choices.runtime`, and `tiers`, checked by `model_choice_tiers_valid/1`, as
  # `model_choices.tiers` is. Both are needed. The columns `model_id` and `effort` go
  # with their checks.
  #
  # The migration moves no data. It deletes every fallback first: a stored fallback has
  # no runtime and no tiers to keep.
  #
  # Rolled back, `value_id` and the fallbacks' `model_id` and `effort` come back empty,
  # with their checks, and `runtime` and `tiers` go.

  def up do
    drop constraint(:model_choices, :model_choices_value_id_format)
    drop constraint(:model_choices, :model_choices_shape_check)

    alter table(:model_choices) do
      remove :value_id
    end

    create constraint(:model_choices, :model_choices_shape_check, check: shape(false))

    execute("DELETE FROM model_choice_fallbacks")

    drop constraint(:model_choice_fallbacks, :model_choice_fallbacks_model_id_format)
    drop constraint(:model_choice_fallbacks, :model_choice_fallbacks_effort_format)
    drop constraint(:model_choice_fallbacks, :model_choice_fallbacks_shape_check)

    alter table(:model_choice_fallbacks) do
      remove :model_id
      remove :effort
      add :runtime, :text, null: false
      add :tiers, :map, null: false
    end

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_runtime_format,
             check: "runtime ~ '^[a-z][a-z0-9_-]{0,63}$'"
           )

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_tiers_check,
             check: "model_choice_tiers_valid(tiers)"
           )
  end

  def down do
    drop constraint(:model_choice_fallbacks, :model_choice_fallbacks_tiers_check)
    drop constraint(:model_choice_fallbacks, :model_choice_fallbacks_runtime_format)

    alter table(:model_choice_fallbacks) do
      remove :runtime
      remove :tiers
      add :model_id, :text
      add :effort, :text
    end

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_model_id_format,
             check: "model_id ~ '^[A-Za-z0-9][!-~]{0,199}$'"
           )

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_effort_format,
             check: "effort ~ '^[a-z][a-z0-9-]{0,31}$'"
           )

    create constraint(:model_choice_fallbacks, :model_choice_fallbacks_shape_check,
             check: "effort IS NULL OR model_id IS NOT NULL"
           )

    drop constraint(:model_choices, :model_choices_shape_check)

    alter table(:model_choices) do
      add :value_id, :text
    end

    create constraint(:model_choices, :model_choices_value_id_format,
             check: "value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'"
           )

    create constraint(:model_choices, :model_choices_shape_check, check: shape(true))
  end

  # The check of what goes with what, as 20261019070200 made it, with `value_id` or
  # without it.
  defp shape(value_id?) do
    chosen = if value_id?, do: "(value_id IS NULL AND model_id IS NULL)", else: "model_id IS NULL"

    """
    (target_id IS NULL OR workspace_id IS NOT NULL)
    AND (NOT locked OR (workspace_id IS NOT NULL AND target_id IS NULL))
    AND (#{chosen} OR connection_id IS NOT NULL)
    AND (effort IS NULL OR model_id IS NOT NULL)
    AND (connection_id IS NOT NULL OR tiers IS NOT NULL)
    """
  end
end
