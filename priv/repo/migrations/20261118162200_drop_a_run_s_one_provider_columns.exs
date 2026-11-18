defmodule Apiary.Repo.Migrations.DropARunSOneProviderColumns do
  use Ecto.Migration

  # A run keeps its model keys in `run_model_keys`, one row per key with its provider,
  # its keys' secret, its chain and its API. The run's columns that kept one provider's
  # keys go: `provider_secret_id`, `provider_chain`, `provider_api` and `model_keys`, with
  # their checks `runs_provider_check`, `runs_provider_api_check` and
  # `runs_model_keys_check`. `provider_connection_id` stays, as the provider of the run's
  # start key. No run's keys are copied: a run claimed before this migration has no key
  # rows, and its secrets requests fail.
  #
  # Rolled back, the columns and their checks come back, filled from the key rows of each
  # run's start key's provider; a run with no such rows loses `provider_connection_id`.
  @uuid "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
  @name "^[a-z0-9][a-z0-9_.-]{0,63}$"
  @window "^[a-z][a-z0-9_]{0,63}$"

  def up do
    drop constraint(:runs, :runs_model_keys_check)
    drop constraint(:runs, :runs_provider_api_check)
    drop constraint(:runs, :runs_provider_check)

    alter table(:runs) do
      remove :model_keys
      remove :provider_api
      remove :provider_chain
      remove :provider_secret_id
    end
  end

  def down do
    alter table(:runs) do
      add :provider_secret_id, references(:secrets, type: :binary_id, on_delete: :nilify_all)
      add :provider_chain, :text
      add :provider_api, :jsonb
      add :model_keys, :jsonb
    end

    execute """
    UPDATE runs r SET provider_secret_id = k.secret_id, provider_chain = k.chain,
      provider_api = k.api,
      model_keys = (
        SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'id', o.secret_value_id::text, 'name', o.name,
          'start', CASE WHEN o.start THEN true END,
          'pause_for_s', o.pause_for_s,
          'resets_at', #{time("o.resets_at")},
          'schedule_resets_at', #{time("o.schedule_resets_at")},
          'chosen', CASE WHEN o.chosen THEN true END,
          'cooldown_until', #{time("o.cooldown_until")},
          'use_up_to_percent', o.use_up_to_percent)) ORDER BY o.position)
        FROM run_model_keys o
        WHERE o.run_id = r.id AND o.connection_id = r.provider_connection_id)
    FROM run_model_keys k
    WHERE k.run_id = r.id AND k.start AND k.connection_id = r.provider_connection_id
    """

    execute """
    UPDATE runs SET provider_connection_id = NULL
    WHERE provider_connection_id IS NOT NULL AND model_keys IS NULL
    """

    create constraint(:runs, :runs_provider_check,
             check: """
             (model_keys IS NULL AND provider_chain IS NULL AND provider_api IS NULL
               AND provider_connection_id IS NULL AND provider_secret_id IS NULL)
             OR (run_settings IS NOT NULL AND model_keys IS NOT NULL
               AND provider_chain IS NOT NULL AND provider_api IS NOT NULL
               AND provider_chain IN ('organisation', 'operator'))
             """
           )

    create constraint(:runs, :runs_provider_api_check,
             check:
               "provider_api IS NULL OR (jsonb_typeof(provider_api) = 'object' " <>
                 "AND provider_api ?& ARRAY['format', 'endpoint', 'auth'] " <>
                 "AND jsonb_typeof(provider_api -> 'format') = 'string' " <>
                 "AND jsonb_typeof(provider_api -> 'endpoint') = 'string' " <>
                 "AND jsonb_typeof(provider_api -> 'auth') = 'object' " <>
                 "AND (provider_api - ARRAY['format', 'endpoint', 'auth', 'key_prefixes', " <>
                 "'use_up_to_windows']) = '{}'::jsonb" <>
                 " AND CASE WHEN NOT provider_api ? 'use_up_to_windows' THEN true " <>
                 "WHEN jsonb_typeof(provider_api -> 'use_up_to_windows') <> 'array' " <>
                 "THEN false " <>
                 "ELSE jsonb_array_length(provider_api -> 'use_up_to_windows') " <>
                 "BETWEEN 1 AND 11 AND NOT jsonb_path_exists(provider_api, " <>
                 "'lax $.use_up_to_windows[*] ? (@.type() != \"string\" " <>
                 "|| !(@ like_regex \"#{@window}\"))') END" <>
                 " AND octet_length(provider_api::text) <= 8192)"
           )

    create constraint(:runs, :runs_model_keys_check,
             check: """
             model_keys IS NULL OR (jsonb_typeof(model_keys) = 'array'
               AND jsonb_array_length(model_keys) <= 6
               AND octet_length(model_keys::text) <= 4096
               AND NOT jsonb_path_exists(model_keys, 'lax $[*] ? (@.type() != "object"
                 || !exists(@.id) || !exists(@.name)
                 || @.id.type() != "string" || @.name.type() != "string"
                 || !(@.id like_regex "#{@uuid}") || !(@.name like_regex "#{@name}"))'))
             """
           )
  end

  # A stored time as the run configuration writes it: RFC 3339 in UTC, whole seconds.
  defp time(column),
    do: "to_char(#{column} AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"
end
