defmodule Apiary.Repo.Migrations.KeepAConnectionSLinkedPass do
  use Ecto.Migration

  # A connected connection takes new connect passes, one per external account a person
  # adds to it (`Apiary.Adapters.Connections.start/3`), so its latest pass is no longer
  # the pass that connected it. Two columns of `adapter_connections` keep what the return
  # and the grant report check:
  #
  # - `linked_nonce`: the 16 bytes of the nonce of the latest pass whose return came back
  #   `linked`, null while none did. A grant report under that nonce is accepted once.
  #   A newer pass leaves it as it is; only a newer `linked` return replaces it.
  # - `pass_started_by_id`: the person who started the latest pass, whom the return checks
  #   for. Once the connection is connected, `created_by_id` stays the person who started
  #   the pass that connected it. Null for a pass made before this migration, whose person
  #   is `created_by_id`.
  def change do
    alter table(:adapter_connections) do
      add :linked_nonce, :binary
      add :pass_started_by_id, references(:users, type: :binary_id, on_delete: :nothing)
    end

    create index(:adapter_connections, [:pass_started_by_id])

    create constraint(:adapter_connections, :adapter_connections_linked_nonce_check,
             check: "linked_nonce IS NULL OR octet_length(linked_nonce) = 16"
           )
  end
end
