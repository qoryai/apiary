defmodule Apiary.Repo.Migrations.KeepEachLinkedPassOfAConnection do
  use Ecto.Migration

  # The connect passes of a connection whose return came back `linked`,
  # `adapter_linked_passes`: a grant report (`Apiary.Adapters.Grants.report/2`) is
  # accepted under the nonce of any of them, once, as the integration contract has it
  # (`grant.schema.json`), not only under the latest. One row per linked return:
  # `nonce`, the 16 bytes of the pass's nonce, `linked_at`, when Qory Apiary accepted
  # the return, and `reported_at`, when it accepted the grant report under that nonce,
  # null until then. The connection, its organisation and its adapter are held to the
  # connection's by the composite key, and go with it. These rows replace
  # `adapter_connections.linked_nonce`, which kept the latest alone.
  #
  # The adoption: a connection that was connected before grants were kept has one grant at
  # its adapter and none in Qory Apiary. Its row gets the nonce of the pass that connected
  # it, which is its latest pass (a connected connection took no new pass then), so the
  # adapter's report of that grant under that nonce is accepted once, and no person
  # installs again.
  def up do
    create table(:adapter_linked_passes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :nothing), null: false

      add :connection_id,
          references(:adapter_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id, adapter_id: :adapter_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :nonce, :binary, null: false
      add :linked_at, :utc_datetime_usec, null: false
      add :reported_at, :utc_datetime_usec
    end

    create unique_index(:adapter_linked_passes, [:connection_id, :nonce])
    create index(:adapter_linked_passes, [:organisation_id])

    create constraint(:adapter_linked_passes, :adapter_linked_passes_nonce_check,
             check: "octet_length(nonce) = 16"
           )

    execute """
    INSERT INTO adapter_linked_passes
      (id, organisation_id, adapter_id, connection_id, nonce, linked_at)
    SELECT gen_random_uuid(), organisation_id, adapter_id, id,
           COALESCE(linked_nonce, pass_nonce), COALESCE(connected_at, now())
    FROM adapter_connections
    WHERE state = 'connected'
    """

    drop constraint(:adapter_connections, :adapter_connections_linked_nonce_check)

    alter table(:adapter_connections) do
      remove :linked_nonce
    end
  end

  # Rolled back, each connection keeps the nonce of its latest linked pass again.
  def down do
    alter table(:adapter_connections) do
      add :linked_nonce, :binary
    end

    execute """
    UPDATE adapter_connections c SET linked_nonce = p.nonce
    FROM (SELECT DISTINCT ON (connection_id) connection_id, nonce
          FROM adapter_linked_passes ORDER BY connection_id, linked_at DESC) p
    WHERE p.connection_id = c.id
    """

    create constraint(:adapter_connections, :adapter_connections_linked_nonce_check,
             check: "linked_nonce IS NULL OR octet_length(linked_nonce) = 16"
           )

    drop table(:adapter_linked_passes)
  end
end
