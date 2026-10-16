defmodule Apiary.Repo.Migrations.ValidateAnAdapterSChecks do
  use Ecto.Migration

  # Validates the checks and keys `20261015131000_make_an_adapter_a_kind_of_node` added NOT
  # VALID: scans that take no lock that blocks writes to the tables. Down leaves them as
  # they are; that migration drops them.
  @constraints [
    nodes: ~w(nodes_kind_check nodes_public_id_check nodes_instance_limit_check
              nodes_gateway_choice_check nodes_place_check nodes_adapter_name_check
              nodes_adapter_check nodes_connect_url_check nodes_sync_check),
    access_keys: ~w(access_keys_place_check access_keys_node_fkey
                    access_keys_enrolment_code_fkey),
    access_key_enrolment_codes: ~w(access_key_enrolment_codes_place_check
                                   access_key_enrolment_codes_node_fkey)
  ]

  def up do
    for {table, names} <- @constraints, name <- names do
      execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
