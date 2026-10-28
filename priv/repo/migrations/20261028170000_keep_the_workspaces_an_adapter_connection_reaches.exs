defmodule Apiary.Repo.Migrations.KeepTheWorkspacesAnAdapterConnectionReaches do
  use Ecto.Migration

  # The workspaces an organisation's connection to an adapter reaches
  # (`Apiary.Adapters.Connection`), as a runtime, an integration or a service has them
  # (`organisation_connections.applies_to`, `connection_workspaces`):
  #
  # - `adapter_connections.applies_to`: `all`, every workspace of the organisation, those
  #   made later included, or `selected`, the workspaces listed for it;
  # - `adapter_connection_workspaces`: a workspace of the connection's organisation that a
  #   `selected` connection reaches. A row goes with its connection, with its workspace,
  #   and with a workspace's purge (`Apiary.Deletion.Tables`).
  #
  # Every connection there already reaches every workspace (`all`). The column then has
  # no default: each insert says what the connection reaches.
  def up do
    alter table(:adapter_connections) do
      add :applies_to, :text, null: false, default: "all"
    end

    execute "ALTER TABLE adapter_connections ALTER COLUMN applies_to DROP DEFAULT"

    create constraint(:adapter_connections, :adapter_connections_applies_to_check,
             check: "applies_to IN ('all', 'selected')"
           )

    create table(:adapter_connection_workspaces, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :connection_id,
          references(:adapter_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:adapter_connection_workspaces, [:workspace_id])
  end

  def down do
    drop table(:adapter_connection_workspaces)

    alter table(:adapter_connections) do
      remove :applies_to
    end
  end
end
