defmodule Apiary.Repo.Migrations.ValidateAGatewaySHostCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `nodes`. A gateway recorded at an address whose host is
  # not a DNS name, an IPv4 address or an IPv6 address in brackets, or whose port is not 1
  # to 65535 without a leading zero, fails it: the error names those gateways, deleted ones
  # included, and each must be given such an address before this migration runs again.
  # Nothing is changed for them. Down leaves the check as it is; the migration before this
  # one restores the old one.
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

      RAISE EXCEPTION 'nodes_url_check: the gateways % have an address whose host is not a DNS name, an IPv4 address or an IPv6 address in brackets, or whose port is not 1 to 65535: give each an address https://, a host and an optional port, then run the migrations again', gateways
        USING ERRCODE = 'check_violation';
    END
    $$
    """
  end

  def down, do: :ok
end
