defmodule Apiary.Repo.Migrations.KeepARunSModelKeys do
  use Ecto.Migration

  # A run's model keys, in place of the one key it kept, and the model providers a run of
  # the queue waits for (`Apiary.Dispatches.RunSettings`, `Apiary.ModelKeys`):
  #
  # - `runs.model_keys`: the run's keys in the order of its run configuration's
  #   `credentials`, a JSON array of at most 6 objects. Each has `id`, the key's row id
  #   (`secret_values.id`), which a rename of the value id leaves as it is, and `name`, the
  #   credential's name, both required; and, as the claim wrote them for the run
  #   configuration, `pause_for_s`, `resets_at`, `schedule_resets_at`, `chosen` and
  #   `cooldown_until`. It has no key value. Set with the other provider columns, and
  #   only with them.
  # - `dispatch_runs.model_provider_ids`: the model providers of the run's model choice
  #   when it was queued, the choice's provider first, then its fallbacks in their order;
  #   empty for a run with none. A claim passes a run while every key of each of them is
  #   in cooldown.
  #
  # Each run with `provider_value_id` gets the key of its provider's secret with that
  # value id, under the name its run configuration has for it, the provider's public id,
  # so the run configuration of a live run stays as it was. A run whose key is gone since
  # its claim gets the all-zero row id in its place, which no key has: its run
  # configuration stays, and a secrets request for the key is refused, as before. A run
  # whose provider is gone, which only an ended run is, gets an empty list.
  # `runs_provider_check` then names `model_keys` in place of `provider_value_id`, which
  # goes.
  #
  # Rolled back, `provider_value_id` is the value id of the first key of the list, where
  # that key is still there; a run without one loses its provider columns.
  @name "^[a-z0-9][a-z0-9_.-]{0,63}$"
  @no_key "00000000-0000-0000-0000-000000000000"
  @uuid "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

  def up do
    alter table(:runs) do
      add :model_keys, :jsonb
    end

    alter table(:dispatch_runs) do
      add :model_provider_ids, {:array, :binary_id}, null: false, default: []
    end

    execute("""
    UPDATE runs r SET model_keys = COALESCE((
      SELECT jsonb_build_array(jsonb_build_object(
        'id', COALESCE(v.id, '#{@no_key}'::uuid)::text, 'name', c.public_id))
      FROM organisation_connections c
      LEFT JOIN secret_values v
        ON v.secret_id = c.secret_id AND v.secret_id = r.provider_secret_id
          AND v.value_id = r.provider_value_id
      WHERE c.id = r.provider_connection_id
      LIMIT 1
    ), '[]'::jsonb)
    WHERE r.provider_value_id IS NOT NULL
    """)

    drop constraint(:runs, :runs_provider_check)

    create constraint(:runs, :runs_provider_check,
             check: """
             (model_keys IS NULL AND provider_chain IS NULL AND provider_api IS NULL
               AND provider_connection_id IS NULL AND provider_secret_id IS NULL)
             OR (run_settings IS NOT NULL AND model_keys IS NOT NULL
               AND provider_chain IS NOT NULL AND provider_api IS NOT NULL
               AND provider_chain IN ('organisation', 'operator'))
             """
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

    alter table(:runs) do
      remove :provider_value_id
    end
  end

  def down do
    drop constraint(:runs, :runs_model_keys_check)
    drop constraint(:runs, :runs_provider_check)

    alter table(:runs) do
      add :provider_value_id, :text
    end

    execute("""
    UPDATE runs r SET provider_value_id = (
      SELECT v.value_id FROM secret_values v
      WHERE v.id = (r.model_keys -> 0 ->> 'id')::uuid AND v.secret_id = r.provider_secret_id
    )
    WHERE r.model_keys IS NOT NULL AND jsonb_array_length(r.model_keys) > 0
    """)

    execute("""
    UPDATE runs SET provider_connection_id = NULL, provider_secret_id = NULL,
      provider_chain = NULL, provider_api = NULL
    WHERE model_keys IS NOT NULL AND provider_value_id IS NULL
    """)

    create constraint(:runs, :runs_provider_check,
             check: """
             (provider_value_id IS NULL AND provider_chain IS NULL AND provider_api IS NULL
               AND provider_connection_id IS NULL AND provider_secret_id IS NULL)
             OR (run_settings IS NOT NULL AND provider_value_id IS NOT NULL
               AND provider_chain IS NOT NULL AND provider_api IS NOT NULL
               AND provider_value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'
               AND provider_chain IN ('organisation', 'operator'))
             """
           )

    alter table(:dispatch_runs) do
      remove :model_provider_ids
    end

    alter table(:runs) do
      remove :model_keys
    end
  end
end
