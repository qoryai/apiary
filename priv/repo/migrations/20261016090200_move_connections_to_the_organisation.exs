defmodule Apiary.Repo.Migrations.MoveConnectionsToTheOrganisation do
  use Ecto.Migration

  # The runtimes, integrations and services (`Apiary.Connections`), the releases fetched
  # (`Apiary.Integrations`) and the service definitions belong to the organisation, not to
  # one of its workspaces. Each connection applies to every workspace of the organisation,
  # those made later included (`applies_to` `all`), or to the workspaces it lists
  # (`selected`); the list of repositories it applied to goes.
  #
  # The tables start empty: the migration of 20261016090000 refuses to run while any of
  # them holds a row, so nothing is moved and nothing of a workspace is kept.
  #
  #   * `workspace_connections` is renamed `organisation_connections`, with its indexes and
  #     constraints, and loses `workspace_id`; its release and its definition are of its
  #     organisation, by composite keys on `organisation_id`.
  #   * `integration_releases` and `service_definitions` lose `workspace_id`; a definition's
  #     key is unique in its organisation.
  #   * `connection_targets` goes. `connection_workspaces` lists the workspaces of a
  #     `selected` connection, each of the connection's organisation; a row goes with its
  #     connection and with its workspace.
  #
  # Every row of the three tables carries an integrity code over fields that named the
  # workspace; the code's new versions name none (`Apiary.Kinds.Coded`).
  def up do
    drop table(:connection_targets)

    drop constraint(:workspace_connections, :workspace_connections_release_id_fkey)
    drop constraint(:workspace_connections, :workspace_connections_service_definition_id_fkey)
    drop index(:workspace_connections, [:id, :workspace_id])
    drop index(:workspace_connections, [:organisation_id, :workspace_id, :kind])

    alter table(:workspace_connections) do
      remove :workspace_id
    end

    drop index(:integration_releases, [:id, :workspace_id])
    drop index(:integration_releases, [:organisation_id, :workspace_id, :source])

    alter table(:integration_releases) do
      remove :workspace_id
    end

    create unique_index(:integration_releases, [:id, :organisation_id])
    create index(:integration_releases, [:organisation_id, :source])

    drop index(:service_definitions, [:organisation_id, :workspace_id, :key],
           name: :service_definitions_key_index
         )

    drop index(:service_definitions, [:id, :workspace_id])

    alter table(:service_definitions) do
      remove :workspace_id
    end

    create unique_index(:service_definitions, [:organisation_id, :key],
             name: :service_definitions_key_index
           )

    create unique_index(:service_definitions, [:id, :organisation_id])

    rename table(:workspace_connections), to: table(:organisation_connections)
    rename_parts("workspace_connections", "organisation_connections")

    alter table(:organisation_connections) do
      modify :release_id,
             references(:integration_releases,
               type: :binary_id,
               with: [organisation_id: :organisation_id],
               match: :simple,
               on_delete: :nothing
             )

      modify :service_definition_id,
             references(:service_definitions,
               type: :binary_id,
               with: [organisation_id: :organisation_id],
               match: :simple,
               on_delete: :nothing
             )
    end

    create unique_index(:organisation_connections, [:id, :organisation_id])
    create index(:organisation_connections, [:organisation_id, :kind])

    create table(:connection_workspaces, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :connection_id,
          references(:organisation_connections,
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

    create index(:connection_workspaces, [:workspace_id])
  end

  # Rolling back gives each table its workspace again, and `connection_targets` back,
  # empty: a row made since names no workspace, so none can be kept.
  def down do
    drop table(:connection_workspaces)

    drop index(:organisation_connections, [:organisation_id, :kind])
    drop index(:organisation_connections, [:id, :organisation_id])
    drop constraint(:organisation_connections, :organisation_connections_release_id_fkey)

    drop constraint(
           :organisation_connections,
           :organisation_connections_service_definition_id_fkey
         )

    rename table(:organisation_connections), to: table(:workspace_connections)
    rename_parts("organisation_connections", "workspace_connections")

    drop index(:service_definitions, [:id, :organisation_id])

    drop index(:service_definitions, [:organisation_id, :key],
           name: :service_definitions_key_index
         )

    alter table(:service_definitions) do
      add :workspace_id, workspace_reference(), null: false
    end

    create unique_index(:service_definitions, [:organisation_id, :workspace_id, :key],
             name: :service_definitions_key_index
           )

    create unique_index(:service_definitions, [:id, :workspace_id])

    drop index(:integration_releases, [:organisation_id, :source])
    drop index(:integration_releases, [:id, :organisation_id])

    alter table(:integration_releases) do
      add :workspace_id, workspace_reference(), null: false
    end

    create unique_index(:integration_releases, [:id, :workspace_id])
    create index(:integration_releases, [:organisation_id, :workspace_id, :source])

    alter table(:workspace_connections) do
      add :workspace_id, workspace_reference(), null: false

      modify :release_id,
             references(:integration_releases,
               type: :binary_id,
               with: [workspace_id: :workspace_id],
               match: :simple,
               on_delete: :nothing
             )

      modify :service_definition_id,
             references(:service_definitions,
               type: :binary_id,
               with: [workspace_id: :workspace_id],
               match: :simple,
               on_delete: :nothing
             )
    end

    create unique_index(:workspace_connections, [:id, :workspace_id])
    create index(:workspace_connections, [:organisation_id, :workspace_id, :kind])

    create table(:connection_targets, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id, workspace_reference(), null: false

      add :connection_id,
          references(:workspace_connections,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:connection_targets, [:target_id])
    create index(:connection_targets, [:organisation_id, :workspace_id])
  end

  defp workspace_reference,
    do:
      references(:workspaces,
        type: :binary_id,
        with: [organisation_id: :organisation_id],
        match: :full,
        on_delete: :delete_all
      )

  # The indexes and constraints the connections' table keeps across a rename, named after
  # the table they are on.
  @indexes ~w(pkey created_by_id_index public_id_index release_id_index
              service_definition_id_index updated_by_id_index)
  @constraints ~w(applies_to_check argument_check forge_kind_check kind_check
                  public_id_format settings_check shape_check created_by_id_fkey
                  organisation_id_fkey updated_by_id_fkey)

  defp rename_parts(from, to) do
    for part <- @indexes do
      execute("ALTER INDEX #{from}_#{part} RENAME TO #{to}_#{part}")
    end

    for part <- @constraints do
      execute("ALTER TABLE #{to} RENAME CONSTRAINT #{from}_#{part} TO #{to}_#{part}")
    end
  end
end
