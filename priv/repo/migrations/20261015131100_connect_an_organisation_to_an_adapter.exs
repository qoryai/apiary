defmodule Apiary.Repo.Migrations.ConnectAnOrganisationToAnAdapter do
  use Ecto.Migration

  # An organisation's connections to the instance's adapters, `adapter_connections`
  # (`Apiary.Adapters.Connection`).
  #
  # A connection is made when an owner or an admin of an organisation starts connecting an
  # adapter (a node of kind `adapter`, which has no organisation). `public_id` is `ac_`
  # and sixteen lowercase Crockford base32 characters. Its states:
  #
  # - `pending`: made, not connected yet. `pass_nonce` is the nonce of the latest connect
  #   pass made for it, and `pass_nonce_used_at` when a return under that nonce came back;
  # - `connected`: since `connected_at`, when the person who started it (`created_by_id`)
  #   came back from the adapter with a return saying it is linked. It takes no new pass,
  #   so `pass_nonce`, `created_by_id` and `connected_at` stay as they were. `listed_at` is
  #   when the adapter's first listing that names it was accepted;
  # - `ended`: since `ended_at`, for `ended_reason`, from either state. Final. The
  #   reasons: `adapter_reported`, `organisation_deleted`, `integration_deleted`, and
  #   `replaced`, when a press of Install ended a connected connection no listing had
  #   named yet, and made a new one in its place.
  #
  # One connection that has not ended per organisation and adapter (the unique partial
  # index). The trigger `adapter_connections_adapter_check` refuses a connection to a row
  # that is not an adapter in use of the instance, and holds that row `FOR SHARE` for the
  # rest of the transaction, so an adapter's deletion, which ends its connections under
  # the adapter's row held `FOR NO KEY UPDATE`, either comes first and is seen, or waits
  # and finds the new connection. A connection never moves to another organisation or
  # adapter. It goes with its organisation.
  @public_id "^ac_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    create table(:adapter_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :nothing), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :state, :text, null: false
      add :pass_nonce, :binary, null: false
      add :pass_nonce_used_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec
      add :listed_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:adapter_connections, [:public_id])
    create unique_index(:adapter_connections, [:id, :organisation_id])

    create unique_index(:adapter_connections, [:organisation_id, :adapter_id],
             where: "ended_at IS NULL",
             name: :adapter_connections_live_index
           )

    create index(:adapter_connections, [:adapter_id])
    create index(:adapter_connections, [:created_by_id])

    create constraint(:adapter_connections, :adapter_connections_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    create constraint(:adapter_connections, :adapter_connections_pass_nonce_check,
             check: "octet_length(pass_nonce) = 16"
           )

    create constraint(:adapter_connections, :adapter_connections_state_check,
             check:
               "(state = 'pending' AND connected_at IS NULL AND ended_at IS NULL) OR " <>
                 "(state = 'connected' AND connected_at IS NOT NULL AND ended_at IS NULL) OR " <>
                 "(state = 'ended' AND ended_at IS NOT NULL)"
           )

    create constraint(:adapter_connections, :adapter_connections_listed_check,
             check:
               "listed_at IS NULL OR " <>
                 "(connected_at IS NOT NULL AND listed_at >= connected_at)"
           )

    create constraint(:adapter_connections, :adapter_connections_ended_reason_check,
             check:
               "(ended_at IS NULL) = (ended_reason IS NULL) AND (ended_reason IS NULL OR " <>
                 "ended_reason IN ('adapter_reported', 'organisation_deleted', " <>
                 "'integration_deleted', 'replaced'))"
           )

    execute """
    CREATE FUNCTION adapter_connections_adapter_check() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF NEW.organisation_id IS DISTINCT FROM OLD.organisation_id
           OR NEW.adapter_id IS DISTINCT FROM OLD.adapter_id THEN
          RAISE EXCEPTION 'a connection stays with its organisation and its adapter'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'adapter_connections_fixed';
        END IF;

        RETURN NEW;
      END IF;

      PERFORM 1 FROM nodes
        WHERE id = NEW.adapter_id AND kind = 'adapter' AND organisation_id IS NULL
          AND workspace_id IS NULL AND deleted_at IS NULL
        FOR SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'a connection is to an adapter in use of the instance'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'adapter_connections_adapter_check';
      END IF;

      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER adapter_connections_adapter_check
    BEFORE INSERT OR UPDATE OF organisation_id, adapter_id ON adapter_connections
    FOR EACH ROW EXECUTE FUNCTION adapter_connections_adapter_check()
    """
  end

  # Rolled back, no connection is kept: refused while a connection is there, which the
  # rollback would lose.
  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM adapter_connections) THEN
        RAISE EXCEPTION 'adapter_connections holds rows, which a rollback would lose';
      END IF;
    END
    $$
    """

    execute "DROP TRIGGER adapter_connections_adapter_check ON adapter_connections"
    execute "DROP FUNCTION adapter_connections_adapter_check()"

    drop table(:adapter_connections)
  end
end
