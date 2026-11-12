defmodule ApiaryPro.MigrationVersionsTest do
  # The edition's migrations and the core's are one folder, `priv/repo/migrations`, which
  # Ecto runs as one sequence by version against one database, so no two of them may share a
  # version. The edition's migrations kept their file names when they moved into the folder,
  # so a database that recorded them runs none of them again. It reads the file names only.
  use ExUnit.Case, async: true

  @folder Path.expand("../../priv/repo/migrations", __DIR__)

  # The edition's 19 migrations, which the folder has under their names.
  @pro ~w(
    20260927100100_create_tenants.exs
    20260927100200_create_account_suspensions.exs
    20260927100300_create_workspace_access.exs
    20260927100400_create_operator_invitations.exs
    20260927100500_create_feature_grants.exs
    20260927100600_create_transfers.exs
    20260927100700_create_policy_requests.exs
    20260927100800_create_instance_branding.exs
    20261001191017_create_organisation_policies.exs
    20261004090000_remove_credentials_from_policy_requests.exs
    20261006090000_create_organisation_variables.exs
    20261009120000_narrow_the_features_a_grant_may_name.exs
    20261011090000_remove_workspace_feature_grants.exs
    20261011170000_create_people_locks.exs
    20261012170000_let_a_grant_name_a_part.exs
    20261012180000_let_a_grant_name_the_nodes.exs
    20261014170000_keep_the_sign_up_settings.exs
    20261024170000_add_model_chain_to_tenants.exs
    20261025170000_create_operator_harness_assignments.exs
  )

  test "no two migrations share a version" do
    clashes =
      migrations()
      |> Enum.group_by(fn {version, _file} -> version end, fn {_version, file} -> file end)
      |> Enum.filter(fn {_version, files} -> length(files) > 1 end)
      |> Enum.map(fn {version, files} -> "#{version}: #{Enum.join(files, ", ")}" end)

    assert clashes == [], Enum.join(clashes, "\n")
  end

  test "the edition's migrations are in the folder under their names" do
    files = Enum.map(migrations(), fn {_version, file} -> file end)
    assert Enum.reject(@pro, &(&1 in files)) == []
  end

  # The folder's migrations, as {version, file name}.
  defp migrations do
    migrations =
      for file <- Enum.sort(File.ls!(@folder)),
          [_, version] <- [Regex.run(~r/^(\d{14})_.*\.exs$/, file)] do
        {version, file}
      end

    assert migrations != [], "no migrations in #{@folder}"
    migrations
  end
end
