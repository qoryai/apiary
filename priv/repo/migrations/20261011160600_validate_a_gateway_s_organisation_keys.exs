defmodule Apiary.Repo.Migrations.ValidateAGatewaySOrganisationKeys do
  use Ecto.Migration

  # Validates the checks and keys the migration before this one added NOT VALID: scans
  # that take no lock that blocks writes to the tables. Down leaves them as they are; the
  # migration before this one drops them.
  @constraints [
    nodes: ~w(nodes_workspace_id_fkey nodes_place_check),
    access_key_enrolment_codes: ~w(access_key_enrolment_codes_workspace_id_fkey
                                   access_key_enrolment_codes_node_id_fkey
                                   access_key_enrolment_codes_node_organisation_fkey),
    access_keys: ~w(access_keys_workspace_id_fkey access_keys_node_organisation_fkey
                    access_keys_enrolment_code_organisation_fkey),
    node_instances: ~w(node_instances_workspace_id_fkey node_instances_node_id_fkey
                       node_instances_node_organisation_fkey)
  ]

  def up do
    for {table, names} <- @constraints, name <- names do
      execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{name}"
    end
  end

  def down, do: :ok
end
