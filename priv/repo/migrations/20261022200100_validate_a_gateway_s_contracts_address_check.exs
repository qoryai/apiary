defmodule Apiary.Repo.Migrations.ValidateAGatewaySContractsAddressCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `nodes`. A gateway recorded at an address with a
  # trailing dot, or longer than 300 characters, fails it: the error names those gateways,
  # deleted ones included, and each must be given an address the contracts take before
  # this migration runs again. Nothing is changed for them. Down leaves the check as it
  # is; the migration before this one restores the old one.
  def up do
    execute """
    DO $$
    DECLARE
      gateways text;
    BEGIN
      ALTER TABLE nodes VALIDATE CONSTRAINT nodes_url_check;
    EXCEPTION WHEN check_violation THEN
      EXECUTE format(
        'SELECT string_agg(public_id, '', '' ORDER BY public_id) FROM nodes WHERE NOT (%s)',
        (SELECT pg_get_expr(conbin, conrelid) FROM pg_constraint
         WHERE conrelid = 'nodes'::regclass AND conname = 'nodes_url_check')
      ) INTO gateways;

      RAISE EXCEPTION 'Give the gateways % an address of https://, a host and an optional port, at most 300 characters and with no trailing dot, then run the migrations again: nodes_url_check refuses their addresses', gateways
        USING ERRCODE = 'check_violation';
    END
    $$
    """
  end

  def down, do: :ok
end
