defmodule Apiary.Repo.Migrations.KeepARunSModelKeysByProvider do
  use Ecto.Migration

  # `run_model_keys`: the model keys a run's claim stored for it, one row per key, at most
  # 6 per run, of one or more model providers (`Apiary.Runs.ModelKey`). Written once, in
  # the transaction of the run's handover (`Apiary.Dispatches.Handover`), and never
  # changed; deleted with the run.
  #
  # - `position`, 1 to 6, unique per run: the key's place in the run configuration's
  #   `credentials`. With the uniqueness, the check caps a run at 6 keys.
  # - `name`, the credential's name, unique per run; `start`, true on the start key, at
  #   most one per run.
  # - `secret_value_id`, the key's row id (`secret_values.id`), with no foreign key: a
  #   key removed after the claim fails at the secrets request.
  # - `connection_id` and `secret_id`, the key's provider and that provider's keys'
  #   secret; each becomes NULL should its row be deleted, and each has an index for that
  #   delete. `chain`, the provider's chain.
  # - `api`, the provider's API that the key's sessions use: a JSON object of `format`,
  #   `endpoint`, `auth` and, when the description lists them, `key_prefixes` and
  #   `use_up_to_windows`, at most 8 KiB.
  # - what the claim wrote for the run configuration: `pause_for_s`, and, where the claim
  #   had them, `resets_at`, `schedule_resets_at`, `cooldown_until` and
  #   `use_up_to_percent`.
  #
  # No row has a key value. The table starts empty: the next migration drops the run's
  # columns that kept one provider's keys, and copies no run's keys.
  @name "^[a-z0-9][a-z0-9_.-]{0,63}$"
  @window "^[a-z][a-z0-9_]{0,63}$"

  def change do
    create table(:run_model_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :name, :text, null: false
      add :start, :boolean, null: false, default: false
      add :secret_value_id, :binary_id, null: false

      add :connection_id,
          references(:organisation_connections, type: :binary_id, on_delete: :nilify_all)

      add :secret_id, references(:secrets, type: :binary_id, on_delete: :nilify_all)
      add :chain, :text, null: false
      add :api, :jsonb, null: false
      add :pause_for_s, :integer, null: false
      add :resets_at, :utc_datetime
      add :schedule_resets_at, :utc_datetime
      add :cooldown_until, :utc_datetime
      add :use_up_to_percent, :integer
    end

    create unique_index(:run_model_keys, [:run_id, :position])
    create unique_index(:run_model_keys, [:run_id, :name])

    create unique_index(:run_model_keys, [:run_id],
             where: "start",
             name: :run_model_keys_start_index
           )

    create index(:run_model_keys, [:connection_id], where: "connection_id IS NOT NULL")
    create index(:run_model_keys, [:secret_id], where: "secret_id IS NOT NULL")

    create constraint(:run_model_keys, :run_model_keys_position_check,
             check: "position BETWEEN 1 AND 6"
           )

    create constraint(:run_model_keys, :run_model_keys_name_check, check: "name ~ '#{@name}'")

    create constraint(:run_model_keys, :run_model_keys_chain_check,
             check: "chain IN ('organisation', 'operator')"
           )

    create constraint(:run_model_keys, :run_model_keys_pause_for_s_check,
             check: "pause_for_s BETWEEN 1 AND 604800"
           )

    create constraint(:run_model_keys, :run_model_keys_use_up_to_percent_check,
             check: "use_up_to_percent IS NULL OR use_up_to_percent BETWEEN 1 AND 99"
           )

    create constraint(:run_model_keys, :run_model_keys_api_check, check: api_check())
  end

  # Each CASE branch runs only when the one before it does not hold, so the length of
  # `use_up_to_windows` is read only for an array.
  defp api_check do
    "jsonb_typeof(api) = 'object' " <>
      "AND api ?& ARRAY['format', 'endpoint', 'auth'] " <>
      "AND jsonb_typeof(api -> 'format') = 'string' " <>
      "AND jsonb_typeof(api -> 'endpoint') = 'string' " <>
      "AND jsonb_typeof(api -> 'auth') = 'object' " <>
      "AND (api - ARRAY['format', 'endpoint', 'auth', 'key_prefixes', " <>
      "'use_up_to_windows']) = '{}'::jsonb " <>
      "AND CASE WHEN NOT api ? 'use_up_to_windows' THEN true " <>
      "WHEN jsonb_typeof(api -> 'use_up_to_windows') <> 'array' THEN false " <>
      "ELSE jsonb_array_length(api -> 'use_up_to_windows') BETWEEN 1 AND 11 " <>
      "AND NOT jsonb_path_exists(api, " <>
      "'lax $.use_up_to_windows[*] ? (@.type() != \"string\" " <>
      "|| !(@ like_regex \"#{@window}\"))') END " <>
      "AND octet_length(api::text) <= 8192"
  end
end
