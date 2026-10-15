defmodule Apiary.Repo.Migrations.LetAPoolBeServedByAnAdapter do
  use Ecto.Migration

  # An organisation's connections to the instance's adapters, `adapter_connections`
  # (`Apiary.Adapters.Connection`), and the adapter that serves a node pool,
  # `served_by_id`.
  #
  # A connection is made when an owner or an admin of an organisation starts connecting an
  # adapter (a node of kind `adapter`, which has no organisation). `public_id` is `ac_`
  # and sixteen lowercase Crockford base32 characters. Its states:
  #
  # - `pending`: made, not connected yet. `pass_nonce` is the nonce of the latest connect
  #   pass made for it, `pass_nonce_used_at` when a return under that nonce came back, and
  #   `activated_at` when the person who started it (`created_by_id`) came back from the
  #   adapter with a return saying it is linked. Once activated it takes no new pass, so
  #   `pass_nonce`, `created_by_id` and `activated_at` stay as they were;
  # - `connected`: since `connected_at`, once activated;
  # - `ended`: since `ended_at`, for `ended_reason`, from either state. Final. The
  #   reasons: `adapter_reported`, `organisation_deleted`, `integration_deleted`, and
  #   `replaced`, when a press of Install ended a pending connection that was activated,
  #   and made a new one in its place.
  #
  # One connection that has not ended per organisation and adapter (the unique partial
  # index). The trigger `adapter_connections_adapter_check` refuses a connection to a row
  # that is not an adapter in use of the instance, and holds that row `FOR SHARE` for the
  # rest of the transaction, so an adapter's deletion, which ends its connections under
  # the adapter's row held `FOR NO KEY UPDATE`, either comes first and is seen, or waits
  # and finds the new connection. A connection never moves to another organisation or
  # adapter. It goes with its organisation.
  #
  # A node pool may name the adapter that serves it, `served_by_id`. Only a pool names one
  # (`nodes_served_by_check`); every row that is there when the column is added names
  # none. `served_by_id` is a plain reference to the adapter's row. The trigger
  # `nodes_served_by_is_an_adapter` refuses a reference, made or changed, unless the
  # pool's organisation holds a connection to that adapter in state `connected`, and
  # holds that connection's row `FOR SHARE` for the rest of the transaction, so a change
  # that ends the connection, which clears the pools that name its adapter after it
  # locked the connection, either comes first and is seen, or waits and finds the pool.
  #
  # The lock order of these rows is the adapter's row, then its connections, then the
  # pools (`Apiary.Adapters.Connections`). The reference `served_by_id` takes the
  # adapter's row `FOR KEY SHARE` after this trigger took the connection, so an adapter's
  # deletion holds its row `FOR NO KEY UPDATE`, which lets that check through.
  #
  # The check on `nodes` is added NOT VALID, so adding it scans no row under a lock that
  # blocks writes to `nodes`; a later migration validates it
  # (`20261015131200_validate_an_adapter_s_checks`).
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
      add :activated_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec
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

    create constraint(:adapter_connections, :adapter_connections_connected_check,
             check:
               "connected_at IS NULL OR " <>
                 "(activated_at IS NOT NULL AND connected_at >= activated_at)"
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

    alter table(:nodes) do
      add :served_by_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_served_by_check
      CHECK (served_by_id IS NULL OR kind = 'pool') NOT VALID
    """

    create index(:nodes, [:served_by_id], where: "served_by_id IS NOT NULL")

    execute """
    CREATE FUNCTION nodes_served_by_is_an_adapter() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.served_by_id IS NOT NULL
         AND (TG_OP = 'INSERT' OR NEW.served_by_id IS DISTINCT FROM OLD.served_by_id) THEN
        PERFORM 1 FROM adapter_connections
          WHERE adapter_id = NEW.served_by_id AND organisation_id = NEW.organisation_id
            AND state = 'connected'
          FOR SHARE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'a pool is served by an adapter its organisation is connected to'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'nodes_served_by_is_an_adapter';
        END IF;
      END IF;

      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER nodes_served_by_is_an_adapter
    BEFORE INSERT OR UPDATE OF served_by_id ON nodes
    FOR EACH ROW EXECUTE FUNCTION nodes_served_by_is_an_adapter()
    """
  end

  # Rolled back, no pool names an adapter, and no connection is kept: refused while a
  # connection is there, which the rollback would lose.
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

    execute "DROP TRIGGER nodes_served_by_is_an_adapter ON nodes"
    execute "DROP FUNCTION nodes_served_by_is_an_adapter()"

    drop index(:nodes, [:served_by_id], where: "served_by_id IS NOT NULL")
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_served_by_check"

    alter table(:nodes) do
      remove :served_by_id
    end

    execute "DROP TRIGGER adapter_connections_adapter_check ON adapter_connections"
    execute "DROP FUNCTION adapter_connections_adapter_check()"

    drop table(:adapter_connections)
  end
end
