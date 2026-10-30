defmodule Apiary.Repo.Migrations.ValidateTheDiagnosticsChecks do
  use Ecto.Migration

  # Validates the checks `20261030200000_keep_the_instance_s_diagnostics_keys` added NOT
  # VALID: scans that take no lock that blocks writes to the table. Down leaves them as
  # they are; that migration drops them.
  @constraints ~w(nodes_kind_check nodes_public_id_check nodes_instance_limit_check
                  nodes_gateway_choice_check nodes_place_check)

  def up do
    for name <- @constraints do
      execute "ALTER TABLE nodes VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
