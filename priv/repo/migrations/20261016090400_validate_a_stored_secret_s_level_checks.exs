defmodule Apiary.Repo.Migrations.ValidateAStoredSecretSLevelChecks do
  use Ecto.Migration

  # Validates the checks and keys the migration before this one added NOT VALID: scans
  # that take no lock that blocks writes to the tables. Down leaves them as they are; the
  # migration before this one drops them.
  @constraints [
    secrets: ~w(secrets_workspace_id_fkey),
    secret_values: ~w(secret_values_workspace_id_fkey secret_values_secret_id_fkey
                      secret_values_secret_organisation_fkey
                      secret_values_organisation_data_key_id_fkey secret_values_one_key)
  ]

  def up do
    for {table, names} <- @constraints, name <- names do
      execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
