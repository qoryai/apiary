defmodule Apiary.Repo.Migrations.KeepTheSettingsAndStatesOfModelKeys do
  use Ecto.Migration

  # The settings and the states of a model key, one value of a model provider's secret
  # (`Apiary.ModelKeys`). Both tables are keyed by `secret_values.id`, which a rename of
  # the value id leaves as it is, and both go with the value (`ON DELETE CASCADE`).
  #
  # `model_key_settings`, one row per key, every setting optional:
  #
  #   * a weekly reset: `reset_weekday` (1 for Monday to 7 for Sunday), `reset_time` and
  #     `reset_time_zone`, an IANA zone, all three or none;
  #   * `pause_seconds`, the cooldown when no reset is known, from 1 to 604800 (7 days).
  #
  # `model_key_states`, one row per key and limit window, as a run's gateway reports it:
  # `status`, `resets_at`, `utilization` in whole percent, `cooldown_until`, `source` and
  # `observed_at`, the gateway's clock when the provider's response arrived. A report
  # keeps a row only when it is newer by `observed_at`. The index on (`secret_value_id`,
  # `cooldown_until`) serves the question whether every key of a provider is in cooldown.
  #
  # Each row is of one organisation, the key's: the composite key to `secret_values`
  # holds `organisation_id` to the value's. Nothing exists to fill.
  def change do
    create unique_index(:secret_values, [:id, :organisation_id])

    create table(:model_key_settings, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :secret_value_id,
          references(:secret_values,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true

      add :reset_weekday, :smallint
      add :reset_time, :time
      add :reset_time_zone, :text
      add :pause_seconds, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:model_key_settings, [:organisation_id])

    create constraint(:model_key_settings, :model_key_settings_reset_check,
             check: """
             (reset_weekday IS NULL AND reset_time IS NULL AND reset_time_zone IS NULL)
             OR (reset_weekday BETWEEN 1 AND 7 AND reset_time IS NOT NULL
                 AND reset_time_zone IS NOT NULL AND length(reset_time_zone) BETWEEN 1 AND 64)
             """
           )

    create constraint(:model_key_settings, :model_key_settings_pause_seconds_check,
             check: "pause_seconds IS NULL OR pause_seconds BETWEEN 1 AND 604800"
           )

    create table(:model_key_states, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :secret_value_id,
          references(:secret_values,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true

      add :window, :text, primary_key: true

      add :status, :text, null: false
      add :resets_at, :utc_datetime_usec
      add :utilization, :smallint
      add :cooldown_until, :utc_datetime_usec
      add :source, :text, null: false
      add :observed_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:model_key_states, [:organisation_id])
    create index(:model_key_states, [:secret_value_id, :cooldown_until])

    create constraint(:model_key_states, :model_key_states_window_check,
             check: ~S("window" ~ '^[a-z][a-z0-9_]{0,63}$')
           )

    create constraint(:model_key_states, :model_key_states_status_check,
             check: "status IN ('allowed', 'allowed_warning', 'rejected')"
           )

    create constraint(:model_key_states, :model_key_states_utilization_check,
             check: "utilization IS NULL OR utilization BETWEEN 0 AND 100"
           )

    create constraint(:model_key_states, :model_key_states_source_check,
             check: "source IN ('provider', 'schedule', 'pause_for')"
           )
  end
end
