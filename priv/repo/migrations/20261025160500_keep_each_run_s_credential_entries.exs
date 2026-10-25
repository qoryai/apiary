defmodule Apiary.Repo.Migrations.KeepEachRunSCredentialEntries do
  use Ecto.Migration

  # The credential entries a run's claim records (`Apiary.Runs.RunCredential`): the most
  # a credential an adapter answers for the run may reach, written once and never
  # changed, deleted with the run. Each row is of the run's organisation and workspace.
  #
  #   * `name`: `work-<n>` or `harness-<n>`, n from 1 to 9, its prefix the row's `purpose`,
  #     once per run; `purpose`: `work`, at most one per run, or `harness`;
  #   * `access`: `read` or `write`, and `read` for `harness`;
  #   * `connection_id` and `adapter_id`: the connection of the organisation through which
  #     the target's collection came, and its adapter, of the run's organisation;
  #   * `resources`: a JSON array of 1 to 64 objects, each a collection with the path of
  #     the target filled in; `apply`: a JSON array of 1 to 16 objects, the apply items
  #     with their paths filled; `placeholders`: 1 to 16 names, or NULL.
  #
  # Rolled back, the table goes.
  def change do
    create table(:run_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :run_id,
          references(:runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :connection_id,
          references(:adapter_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full
          ),
          null: false

      add :adapter_id, references(:nodes, type: :binary_id), null: false
      add :name, :text, null: false
      add :purpose, :text, null: false
      add :access, :text, null: false
      add :resources, :jsonb, null: false
      add :apply, :jsonb, null: false
      add :placeholders, {:array, :text}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:run_credentials, [:run_id, :name])

    create unique_index(:run_credentials, [:run_id],
             where: "purpose = 'work'",
             name: :run_credentials_work_index
           )

    create index(:run_credentials, [:workspace_id])
    create index(:run_credentials, [:connection_id])
    create index(:run_credentials, [:adapter_id])

    create constraint(:run_credentials, :run_credentials_entry_check,
             check: """
             purpose IN ('work', 'harness')
             AND access IN ('read', 'write')
             AND (purpose = 'work' OR access = 'read')
             AND name ~ '^(work|harness)-[1-9]$'
             AND starts_with(name, purpose || '-')
             """
           )

    create constraint(:run_credentials, :run_credentials_values_check,
             check: """
             jsonb_typeof(resources) = 'array'
             AND jsonb_array_length(resources) BETWEEN 1 AND 64
             AND NOT jsonb_path_exists(resources, '$[*] ? (@.type() != "object")')
             AND jsonb_typeof(apply) = 'array'
             AND jsonb_array_length(apply) BETWEEN 1 AND 16
             AND NOT jsonb_path_exists(apply, '$[*] ? (@.type() != "object")')
             AND (placeholders IS NULL OR (cardinality(placeholders) BETWEEN 1 AND 16
                  AND array_position(placeholders, NULL) IS NULL))
             """
           )
  end
end
