defmodule Apiary.Repo.Migrations.ValidateAnAdapterSChecks do
  use Ecto.Migration

  # Validates the checks the two migrations before this one added NOT VALID: scans that
  # take no lock that blocks writes to `nodes`. Down leaves them as they are; the
  # migrations before this one drop them.
  @constraints ~w(nodes_kind_check nodes_public_id_check nodes_instance_limit_check
                  nodes_gateway_choice_check nodes_place_check nodes_adapter_name_check
                  nodes_adapter_check nodes_connect_url_check nodes_sync_check
                  nodes_served_by_check)

  def up do
    for name <- @constraints do
      execute "ALTER TABLE nodes VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
