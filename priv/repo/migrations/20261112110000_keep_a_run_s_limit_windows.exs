defmodule Apiary.Repo.Migrations.KeepARunSLimitWindows do
  use Ecto.Migration

  # The limit windows a run's keys' Use up to percentages apply to
  # (`Apiary.Dispatches.RunSettings`): `runs.provider_api` may have `use_up_to_windows`,
  # 1 to 11 strings, the limit windows of the catalogue entry of the run's model provider
  # at the claim, once for the run, beside its `format`, `endpoint`, `auth` and
  # `key_prefixes`. The bound of 8192 octets stays.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the next migration validates it. It changes no row: a run claimed before has no
  # windows, and so no Use up to members in its run configuration.
  def up do
    drop constraint(:runs, :runs_provider_api_check)

    create constraint(:runs, :runs_provider_api_check,
             check: check(~w(format endpoint auth key_prefixes use_up_to_windows), windows()),
             validate: false
           )
  end

  # Rolled back, a run keeps no windows: they are removed from every run that has them.
  def down do
    drop constraint(:runs, :runs_provider_api_check)

    execute """
    UPDATE runs SET provider_api = provider_api - 'use_up_to_windows'
    WHERE provider_api ? 'use_up_to_windows'
    """

    create constraint(:runs, :runs_provider_api_check,
             check: check(~w(format endpoint auth key_prefixes), "")
           )
  end

  defp check(members, windows) do
    "provider_api IS NULL OR (jsonb_typeof(provider_api) = 'object' " <>
      "AND provider_api ?& ARRAY['format', 'endpoint', 'auth'] " <>
      "AND jsonb_typeof(provider_api -> 'format') = 'string' " <>
      "AND jsonb_typeof(provider_api -> 'endpoint') = 'string' " <>
      "AND jsonb_typeof(provider_api -> 'auth') = 'object' " <>
      "AND (provider_api - ARRAY[#{Enum.map_join(members, ", ", &"'#{&1}'")}]) " <>
      "= '{}'::jsonb#{windows} AND octet_length(provider_api::text) <= 8192)"
  end

  # Each CASE branch runs only when the one before it does not hold, so the length of
  # `use_up_to_windows` is read only for an array.
  defp windows do
    " AND CASE WHEN NOT provider_api ? 'use_up_to_windows' THEN true " <>
      "WHEN jsonb_typeof(provider_api -> 'use_up_to_windows') <> 'array' THEN false " <>
      "ELSE jsonb_array_length(provider_api -> 'use_up_to_windows') BETWEEN 1 AND 11 " <>
      "AND NOT jsonb_path_exists(provider_api, " <>
      "'lax $.use_up_to_windows[*] ? (@.type() != \"string\")') END"
  end
end
