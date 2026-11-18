defmodule Apiary.Repo.Migrations.KeepARunSApiPaths do
  use Ecto.Migration

  # The paths a run's model key is set on (`Apiary.Dispatches.RunSettings`):
  # `runs.provider_api` may have `paths`, 1 to 32 paths, the `paths` of the API in the
  # catalogue entry of the run's model provider at the claim, once for the run, beside its
  # `format`, `endpoint`, `auth`, `key_prefixes` and `use_up_to_windows`. The bound of 8192
  # octets stays, and it bounds the length of the paths. The check holds the shape only:
  # each path is a string that starts with `/`. The path grammar of the Forager contract's
  # `credential_paths` is checked when the catalogue entry loads
  # (`Apiary.Integrations.Description`), not here.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the next migration validates it. It changes no row: a run claimed before has no paths,
  # so every path of the endpoint's host applies to its key, as before.
  @window "^[a-z][a-z0-9_]{0,63}$"
  @path "^/"

  def up do
    drop constraint(:runs, :runs_provider_api_check)

    create constraint(:runs, :runs_provider_api_check,
             check: check(~w(format endpoint auth key_prefixes use_up_to_windows paths)),
             validate: false
           )
  end

  # Rolled back, a run keeps no paths: they are removed from every run that has them.
  def down do
    drop constraint(:runs, :runs_provider_api_check)

    execute """
    UPDATE runs SET provider_api = provider_api - 'paths'
    WHERE provider_api ? 'paths'
    """

    create constraint(:runs, :runs_provider_api_check,
             check: check(~w(format endpoint auth key_prefixes use_up_to_windows), false),
             validate: false
           )

    execute "ALTER TABLE runs VALIDATE CONSTRAINT runs_provider_api_check"
  end

  defp check(members, with_paths \\ true) do
    "provider_api IS NULL OR (jsonb_typeof(provider_api) = 'object' " <>
      "AND provider_api ?& ARRAY['format', 'endpoint', 'auth'] " <>
      "AND jsonb_typeof(provider_api -> 'format') = 'string' " <>
      "AND jsonb_typeof(provider_api -> 'endpoint') = 'string' " <>
      "AND jsonb_typeof(provider_api -> 'auth') = 'object' " <>
      "AND (provider_api - ARRAY[#{Enum.map_join(members, ", ", &"'#{&1}'")}]) " <>
      "= '{}'::jsonb#{windows()}#{if with_paths, do: paths()} " <>
      "AND octet_length(provider_api::text) <= 8192)"
  end

  # Each CASE branch runs only when the one before it does not hold, so the length of
  # `use_up_to_windows` is read only for an array. Each window is a name as the
  # integrations contract's `limit_windows` has it.
  defp windows do
    " AND CASE WHEN NOT provider_api ? 'use_up_to_windows' THEN true " <>
      "WHEN jsonb_typeof(provider_api -> 'use_up_to_windows') <> 'array' THEN false " <>
      "ELSE jsonb_array_length(provider_api -> 'use_up_to_windows') BETWEEN 1 AND 11 " <>
      "AND NOT jsonb_path_exists(provider_api, " <>
      "'lax $.use_up_to_windows[*] ? (@.type() != \"string\" " <>
      "|| !(@ like_regex \"#{@window}\"))') END"
  end

  # The same for `paths`: an array of 1 to 32 strings that each fit the bound above.
  defp paths do
    " AND CASE WHEN NOT provider_api ? 'paths' THEN true " <>
      "WHEN jsonb_typeof(provider_api -> 'paths') <> 'array' THEN false " <>
      "ELSE jsonb_array_length(provider_api -> 'paths') BETWEEN 1 AND 32 " <>
      "AND NOT jsonb_path_exists(provider_api, " <>
      "'lax $.paths[*] ? (@.type() != \"string\" " <>
      "|| !(@ like_regex \"#{@path}\"))') END"
  end
end
